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
  , sessionFile
  , sessionAlive
  , sessionTryReserve
  , closeSession
  , burstReplies
  ) where

import           Control.Concurrent       (ThreadId, forkIO, killThread)
import           Control.Concurrent.Chan  (Chan, newChan, readChan, writeChan)
import           Control.Concurrent.MVar  (MVar, newMVar, tryTakeMVar, withMVar)
import           Control.Exception        (SomeException, try)
import           Control.Monad            (unless, when)
import           Data.Maybe               (isJust)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BSC
import qualified Data.ByteString.Lazy     as BL
import           Data.IORef
import           Data.Text                (Text)
import qualified Data.Text                as T
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
  , scTimeoutMicros :: !Int        -- ^ per-command wall-clock budget.
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
  , sTimeout   :: !Int        -- ^ per-command wall-clock budget (µs).
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
      ready <- collectBurst s
      case ready of
        SendDied _ err -> do
          _ <- closeSession s
          pure (Left ("agda exited before becoming ready: " <> err))
        _ -> pure (Right s)
    Right _ -> pure (Left "agda process pipes were not created")

-- | Send one IOTCM command and collect its prompt-terminated reply burst.
-- Serialised per session via 'sLock'. A dead session short-circuits.
sendIotcm :: Session -> String -> IO SendOutcome
sendIotcm s cmd = withMVar (sLock s) $ \_ -> do
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
        Right () -> collectBurst s
  where
    hPutStrLn' h str = BS.hPut h (BSC.pack str) >> BS.hPut h (BSC.singleton '\n')

-- | Read events accumulating replies until the next 'REPrompt', a timeout,
-- or EOF. On timeout/EOF the session is marked dead.
collectBurst :: Session -> IO SendOutcome
collectBurst s = go []
  where
    go !acc = do
      mev <- timeout (sTimeout s) (readChan (sEvents s))
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
readerLoop h chan = loop BS.empty
  where
    loop !pending = do
      chunk <- readChunk
      if BS.null chunk
        then do
          unless (BS.null pending) (emitLine pending)
          writeChan chan REEof
        else do
          let buf            = pending <> chunk
              parts          = BSC.split '\n' buf
              complete       = init parts
              leftover       = last parts
          mapM_ emitLine complete
          if isBarePrompt leftover
            then writeChan chan REPrompt >> loop BS.empty
            else loop leftover

    readChunk = either (const BS.empty) id
                  <$> (try (BS.hGetSome h 8192) :: IO (Either SomeException BS.ByteString))

    -- A line: strip a leading @JSON> @ prompt (emitting REPrompt for it),
    -- then parse whatever remains (blank → nothing).
    emitLine raw =
      let l            = BS.dropWhileEnd (== 13) raw     -- drop trailing CR
          (hadP, body) = stripPrompt l
      in do
        when hadP (writeChan chan REPrompt)
        if BS.null (BSC.dropWhile (`elem` (" \t" :: String)) body)
          then pure ()
          else case parseReply (BL.fromStrict body) of
                 Right (Just r) -> writeChan chan (REReply r)
                 Right Nothing  -> pure ()
                 Left e         -> writeChan chan (REDecodeError e)

    stripPrompt l =
      let l' = BSC.dropWhile (`elem` (" \t" :: String)) l
      in case BS.stripPrefix promptBS l' of
           Just rest -> (True, rest)
           Nothing   -> (False, l)

    -- Leftover (post-final-newline) bytes that are exactly the readiness
    -- prompt @JSON> @ (note the trailing space). A partial prompt prefix
    -- (e.g. "JSON") or a partial reply ("JSON> {…") is not yet a boundary —
    -- keep reading. Reuses 'stripPrompt' so the trailing-space handling
    -- matches exactly.
    isBarePrompt bs = case stripPrompt bs of
      (True, rest) -> BS.null (BSC.dropWhile (`elem` (" \t\r" :: String)) rest)
      (False, _)   -> False

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
              let ls = map (T.pack . BSC.unpack) (BSC.lines chunk)
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
