{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A long-lived @agda --interaction-json@ session.
--
-- Unlike @agda-goals@' one-shot driver (which sends a single @Cmd_load@
-- then closes stdin so Agda exits), this keeps one Agda process alive and
-- streams many commands to it over its lifetime — the substrate the
-- write-side interaction bridge sits on.
--
-- == The burst protocol
--
-- @--interaction-json@ has no per-command reply id. Agda prints a
-- @JSON> @ readiness prompt (no trailing newline) whenever it is ready
-- for the next command, then the next command's replies, then the prompt
-- again. So the prompt is a reliable, version-stable burst delimiter: one
-- prompt == one command settled. A dedicated reader thread parses the
-- stream into 'ReplyEvent's; 'sendIotcm' writes one command and collects
-- replies up to the next 'REPrompt'. See @test/interaction/README.md@.
--
-- == Lifecycle
--
-- 'startSession' spawns Agda and consumes its startup readiness prompt,
-- so the returned session is "at a prompt" (Agda waiting). Each
-- 'sendIotcm' restores that invariant. A command that never yields a
-- prompt within the timeout /poisons/ the session (Agda is stuck
-- mid-elaboration and unrecoverable): it is marked dead and the next use
-- must respawn.
module AgdaInteract.Session
  ( Session
  , SessionConfig(..)
  , ReplyEvent(..)
  , SendOutcome(..)
  , startSession
  , sendIotcm
  , sendIotcmBudget
  , sessionFile
  , sessionAlive
  , sessionTryReserve
  , closeSession
  , burstReplies
  , clampRemainingMicros
  ) where

import           Control.Concurrent       (ThreadId, forkIO, killThread)
import           Control.Concurrent.Chan  (Chan, newChan, readChan, writeChan)
import           Control.Concurrent.MVar  (MVar, newMVar, tryTakeMVar, withMVar)
import           Control.Exception        (SomeException, try)
import           Control.Monad            (unless, when)
import           Data.Maybe               (isJust)
import           Data.Word                (Word64)
import           GHC.Clock                (getMonotonicTimeNSec)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BSC
import qualified Data.ByteString.Lazy     as BL
import           Data.IORef
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8Lenient)
import           System.IO                (BufferMode (..), Handle, hClose,
                                           hFlush, hSetBuffering, hSetEncoding,
                                           utf8)
import           System.Process           (CreateProcess (..), ProcessHandle,
                                           StdStream (..), createProcess, proc,
                                           terminateProcess, waitForProcess)
import           System.Timeout           (timeout)

import           AgdaGraph.Interaction.Protocol (Reply, parseReply)

-- | How to spawn an Agda interaction session.
data SessionConfig = SessionConfig
  { scAgdaBin       :: !FilePath
  , scRtsArgs       :: ![String]   -- ^ RTS flags placed /before/ the agda flags
                                    -- (e.g. @["+RTS","-M4096m","-RTS"]@ to cap the
                                    -- child's heap). Empty = inherit agda's defaults.
  , scExtraArgs     :: ![String]   -- ^ extra flags after @--interaction-json@.
  , scTimeoutMicros :: !Int        -- ^ per-command __inactivity__ budget: the
                                    -- max gap between reply events before the
                                    -- session is declared wedged. A chatty
                                    -- burst (e.g. a big @Cmd_load@) may run
                                    -- much longer in total. Use 'sendIotcmBudget'
                                    -- for a hard wall-clock ceiling (Mimer probes).
  } deriving (Show)

-- | A live session: the process, its stdin, the reader's event channel,
-- a recent-stderr ring buffer for diagnostics, and a liveness flag. The
-- 'sLock' serialises @sendIotcm@ (belt-and-suspenders against the watcher
-- thread; the RPC loop is already single-threaded).
data Session = Session
  { sStdin     :: !Handle
  , sProc      :: !ProcessHandle
  , sEvents    :: !(Chan ReplyEvent)
  , sReaderTid :: !ThreadId
  , sErrTid    :: !ThreadId
  , sErrBuf    :: !(IORef [Text])
  , sLock      :: !(MVar ())
  , sAlive     :: !(IORef Bool)
  , sFile      :: !FilePath
  , sTimeout   :: !Int        -- ^ per-command __inactivity__ budget (µs) —
                              -- max gap between reply events (see 'scTimeoutMicros').
  }

-- | One event off the reader thread.
data ReplyEvent
  = REReply !Reply        -- ^ one parsed reply line
  | REPrompt              -- ^ a @JSON> @ readiness prompt: burst boundary
  | REDecodeError !String -- ^ a line that failed to parse (kept for diagnostics)
  | REEof                 -- ^ Agda's stdout closed (process ended)

-- | Outcome of one 'sendIotcm'.
data SendOutcome
  = SendOk      ![Reply]          -- ^ the prompt-terminated burst
  | SendTimeout ![Reply]          -- ^ timed out waiting for the prompt (session poisoned)
  | SendDied    ![Reply] !Text    -- ^ EOF before the prompt; recent stderr attached
  deriving (Show)

-- | The replies of an outcome, whatever the terminal condition.
burstReplies :: SendOutcome -> [Reply]
burstReplies (SendOk rs)       = rs
burstReplies (SendTimeout rs)  = rs
burstReplies (SendDied rs _)   = rs

sessionFile :: Session -> FilePath
sessionFile = sFile

sessionAlive :: Session -> IO Bool
sessionAlive = readIORef . sAlive

-- | Try to acquire the session's command lock /without releasing it/.
-- 'True' means no 'sendIotcm' is in flight and the caller now owns the
-- lock — used by the idle reaper to take a session out of service only
-- when it is genuinely idle (never mid-command). The lock is intentionally
-- left held: the only caller goes on to 'closeSession', after which the
-- session is dead and the lock irrelevant. 'False' means a command holds
-- the lock right now, so the caller must leave the session alone.
sessionTryReserve :: Session -> IO Bool
sessionTryReserve s = isJust <$> tryTakeMVar (sLock s)

recentStderr :: Session -> IO Text
recentStderr s = T.unlines . reverse <$> readIORef (sErrBuf s)

promptBS :: BS.ByteString
promptBS = BSC.pack "JSON> "

-- | Spawn Agda and wait out its startup readiness prompt. Returns a
-- session ready to receive commands, or a diagnostic if Agda could not be
-- started / never reached a prompt.
startSession :: SessionConfig -> FilePath -> IO (Either Text Session)
startSession cfg file = do
  let args = scRtsArgs cfg ++ ("--interaction-json" : scExtraArgs cfg)
      cp   = (proc (scAgdaBin cfg) args)
               { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  r <- try (createProcess cp)
         :: IO (Either SomeException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case r of
    Left e -> pure (Left ("could not start agda (" <> T.pack (scAgdaBin cfg)
                            <> "): " <> T.pack (show e)))
    Right (Just hin, Just hout, Just herr, ph) -> do
      hSetBuffering hin LineBuffering
      hSetEncoding  hin utf8
      events <- newChan
      errBuf <- newIORef []
      rtid   <- forkIO (readerLoop hout events)
      etid   <- forkIO (stderrLoop herr errBuf)
      lock   <- newMVar ()
      alive  <- newIORef True
      let s = Session
                { sStdin = hin, sProc = ph, sEvents = events
                , sReaderTid = rtid, sErrTid = etid, sErrBuf = errBuf
                , sLock = lock, sAlive = alive, sFile = file
                , sTimeout = scTimeoutMicros cfg }
      -- Consume the startup readiness prompt so the session is at a prompt.
      ready <- collectBurstWith s (pure (sTimeout s))
      case ready of
        SendDied _ err -> do
          _ <- closeSession s
          pure (Left ("agda exited before becoming ready: " <> err))
        _ -> pure (Right s)
    Right _ -> pure (Left "agda process pipes were not created")

-- | Send one IOTCM command and collect its prompt-terminated reply burst,
-- bounded by the session's per-event __inactivity__ timeout ('sTimeout').
-- Serialised per session via 'sLock'. A dead session short-circuits.
sendIotcm :: Session -> String -> IO SendOutcome
sendIotcm = sendGeneric (\s -> pure (pure (sTimeout s)))

-- | 'sendIotcm' with a hard __wall-clock__ budget (µs) for the whole burst,
-- for callers that must stay responsive no matter how the child behaves —
-- notably Mimer probes, whose goal-type normalization is not bounded by
-- Mimer's own @-t@. Expiry poisons the session exactly like the inactivity
-- timeout (returns 'SendTimeout', marks it dead); the next use respawns.
sendIotcmBudget :: Int -> Session -> String -> IO SendOutcome
sendIotcmBudget budgetMicros = sendGeneric $ \_ -> do
  start <- getMonotonicTimeNSec
  let deadlineNs = start + fromIntegral (max 0 budgetMicros) * 1000
  pure (remainingMicros deadlineNs)

-- | Write the command, then collect the burst using a caller-supplied
-- per-read timeout supplier (constant for the inactivity path; a shrinking
-- remainder for the wall-budget path). The @IO (IO Int)@ is run once /after/
-- the write, so a wall budget starts at the burst, not at lock acquisition.
sendGeneric :: (Session -> IO (IO Int)) -> Session -> String -> IO SendOutcome
sendGeneric mkNext s cmd = withMVar (sLock s) $ \_ -> do
  alive <- readIORef (sAlive s)
  if not alive
    then SendDied [] <$> recentStderr s
    else do
      w <- try (hPutStrLn' (sStdin s) cmd >> hFlush (sStdin s))
             :: IO (Either SomeException ())
      case w of
        Left e  -> do
          writeIORef (sAlive s) False
          pure (SendDied [] ("write to agda failed: " <> T.pack (show e)))
        Right () -> do
          next <- mkNext s
          collectBurstWith s next
  where
    hPutStrLn' h str = BS.hPut h (BSC.pack str) >> BS.hPut h (BSC.singleton '\n')

-- | Microseconds left until a monotonic-clock deadline (0 once past it —
-- never negative, so 'timeout' is never handed a "wait forever" argument).
remainingMicros :: Word64 -> IO Int
remainingMicros deadlineNs = clampRemainingMicros deadlineNs <$> getMonotonicTimeNSec

-- | Pure core of 'remainingMicros': µs from @now@ to @deadline@ (both ns),
-- clamped to 0 once the deadline has passed. Guards the 'Word64' subtraction
-- against underflow (which would otherwise become a huge positive timeout).
clampRemainingMicros :: Word64 -> Word64 -> Int
clampRemainingMicros deadlineNs nowNs
  | nowNs >= deadlineNs = 0
  | otherwise           = fromIntegral ((deadlineNs - nowNs) `div` 1000)

-- | Read events accumulating replies until the next 'REPrompt', a timeout,
-- or EOF. The @IO Int@ yields the timeout for the next 'readChan': a constant
-- for the inactivity path, or a shrinking remainder for a wall budget. A
-- non-positive value means the deadline has passed → poison immediately
-- (never call 'timeout' with @<= 0@, which would block forever). On
-- timeout/EOF the session is marked dead.
collectBurstWith :: Session -> IO Int -> IO SendOutcome
collectBurstWith s nextTimeout = go []
  where
    go !acc = do
      t <- nextTimeout
      mev <- if t <= 0 then pure Nothing else timeout t (readChan (sEvents s))
      case mev of
        Nothing -> do
          writeIORef (sAlive s) False
          pure (SendTimeout (reverse acc))
        Just ev -> case ev of
          REReply r       -> go (r : acc)
          REPrompt        -> pure (SendOk (reverse acc))
          REDecodeError _ -> go acc
          REEof           -> do
            writeIORef (sAlive s) False
            err <- recentStderr s
            pure (SendDied (reverse acc) err)

-- | The reader thread: turn Agda's byte stream into 'ReplyEvent's. Handles
-- both a @JSON> @ prompt glued to the next reply (a complete line whose
-- prefix is the prompt) and the trailing bare @JSON> @ (no newline — a
-- line reader would block on it, so we work at the byte level).
readerLoop :: Handle -> Chan ReplyEvent -> IO ()
readerLoop h chan = loop 0 []
  where
    -- @pending@ is the current unfinished line — the bytes since the last
    -- newline, held as a REVERSED list of chunk fragments (never containing
    -- a '\n'), with @plen@ its total byte length. Each new chunk is scanned
    -- for newlines on its own; the fragments are concatenated exactly once,
    -- when a newline finally completes the line. This keeps a reply larger
    -- than one 8 KB read (a big AllGoalsWarnings / normalize burst) O(L)
    -- instead of the O(L²/chunk) that re-@<>@-ing + re-splitting a growing
    -- buffer every chunk would cost.
    loop !plen pending = do
      chunk <- readChunk
      if BS.null chunk
        then do
          unless (null pending) (emitLine (BS.concat (reverse pending)))
          writeChan chan REEof
        else case BSC.split '\n' chunk of
          -- No newline in this chunk: extend the pending line. Probe for the
          -- trailing bare @JSON> @ prompt (which carries no newline) only
          -- while the line is short enough to BE one — a longer accumulated
          -- line cannot be the prompt, so we skip the concat and stay O(L).
          [only] ->
            let !plen'   = plen + BS.length only
                pending' = only : pending
            in if plen' <= promptProbeMax
                 && isBarePrompt (BS.concat (reverse pending'))
                 then writeChan chan REPrompt >> loop 0 []
                 else loop plen' pending'
          -- ≥1 newline: the first part completes the pending line; interior
          -- parts are whole lines; the final part is the new leftover.
          (p0 : rest) -> do
            emitLine (BS.concat (reverse (p0 : pending)))
            mapM_ emitLine (init rest)
            let leftover = last rest
            if isBarePrompt leftover
              then writeChan chan REPrompt >> loop 0 []
              else if BS.null leftover
                     then loop 0 []
                     else loop (BS.length leftover) [leftover]
          [] -> loop plen pending  -- BSC.split never returns [], defensive

    -- Upper bound on the bare-prompt probe: the prompt itself plus generous
    -- slack for surrounding whitespace. Anything longer cannot be the prompt,
    -- so the probe is skipped. Derived from 'promptBS' so it tracks the
    -- prompt string.
    promptProbeMax :: Int
    promptProbeMax = BS.length promptBS + 32

    readChunk = either (const BS.empty) id
                  <$> (try (BS.hGetSome h 8192) :: IO (Either SomeException BS.ByteString))

    -- A line: strip a leading @JSON> @ prompt (emitting REPrompt for it),
    -- then parse whatever remains (blank → nothing).
    emitLine raw =
      let l            = BS.dropWhileEnd (== 13) raw     -- drop trailing CR
          (hadP, body) = stripPrompt l
      in do
        when hadP (writeChan chan REPrompt)
        if BS.null (BS.dropWhile isSpTab body)
          then pure ()
          else case parseReply (BL.fromStrict body) of
                 Right (Just r) -> writeChan chan (REReply r)
                 Right Nothing  -> pure ()
                 Left e         -> writeChan chan (REDecodeError e)

    stripPrompt l =
      let l' = BS.dropWhile isSpTab l
      in case BS.stripPrefix promptBS l' of
           Just rest -> (True, rest)
           Nothing   -> (False, l)

    -- Leftover (post-final-newline) bytes that are exactly the readiness
    -- prompt @JSON> @ (note the trailing space). A partial prompt prefix
    -- (e.g. "JSON") or a partial reply ("JSON> {…") is not yet a boundary —
    -- keep reading. Reuses 'stripPrompt' so the trailing-space handling
    -- matches exactly.
    isBarePrompt bs = case stripPrompt bs of
      (True, rest) -> BS.null (BS.dropWhile isSpTabCr rest)
      (False, _)   -> False

    -- Word8 whitespace predicates (space=32, tab=9, CR=13) — no per-char
    -- 'elem' over a String list.
    isSpTab w   = w == 32 || w == 9
    isSpTabCr w = w == 32 || w == 9 || w == 13

-- | Drain stderr into a bounded ring buffer (most-recent first), so a
-- 'SendDied' can attach context. Critical for deadlock-avoidance: an
-- undrained stderr pipe can fill and block Agda.
stderrLoop :: Handle -> IORef [Text] -> IO ()
stderrLoop h buf = loop
  where
    loop = do
      r <- try (BS.hGetSome h 8192) :: IO (Either SomeException BS.ByteString)
      case r of
        Left _      -> pure ()
        Right chunk
          | BS.null chunk -> pure ()
          | otherwise     -> do
              let ls = map decodeUtf8Lenient (BSC.lines chunk)
              modifyIORef' buf (\old -> take 50 (reverse ls ++ old))
              loop

-- | Tear a session down: stop accepting commands, close stdin so Agda
-- exits, reap it (bounded), and kill the reader\/stderr threads.
closeSession :: Session -> IO ()
closeSession s = do
  writeIORef (sAlive s) False
  _ <- (try (hClose (sStdin s)) :: IO (Either SomeException ()))
  _ <- timeout (2 * 1000000) (waitForProcess (sProc s))
  _ <- (try (terminateProcess (sProc s)) :: IO (Either SomeException ()))
  killThread (sReaderTid s)
  killThread (sErrTid s)
