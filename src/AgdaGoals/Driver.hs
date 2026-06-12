{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Drive @agda --interaction-json@ as a subprocess for one source
-- module, capture the @AllGoalsWarnings@ reply, and surface every
-- goal-type string it carried. Agda is opened once per module.
--
-- Failure handling:
--
--   * Clean diagnostics on missing binary, non-zero exit, unparseable
--     output.
--   * Distinct exit codes per failure family — 'DriverResult' carries
--     the structured error and 'MainGoals' maps it to an @exitWith@.
--   * Never crashes with an aeson decode error — bad output becomes
--     'BadOutput' with the offending lines attached.
--
-- == --interaction-json wire glue
--
-- The protocol consumes @IOTCM@ commands on stdin, one per line, and
-- emits a stream of JSON objects on stdout terminated by a @JSON>@
-- prompt. For a one-shot load we send a single @Cmd_load@ and then
-- close stdin so Agda exits naturally; the resulting stdout is read
-- to EOF and parsed line-by-line.
module AgdaGoals.Driver
  ( DriverConfig(..)
  , DriverResult(..)
  , DriverError(..)
  , driverErrorTag
  , runDriver
  , runDriverBatch
  ) where

import           Control.Applicative    ( (<|>) )
import           Control.Monad          ( forM, when )
import           Data.IORef             ( newIORef, readIORef, writeIORef )
import           Data.Text              ( Text )
import qualified Data.Text              as T
import           System.FilePath        ( takeBaseName )
import           System.IO              ( hPutStrLn, stderr )

import           AgdaGoals.Protocol     ( Reply(..), DisplayInfo(..), Goal(..) )
import           AgdaGraph.Interaction.Iotcm ( iotcmLoad )
import           AgdaInteract.Session   ( Session, SessionConfig(..), SendOutcome(..)
                                        , startSession, sendIotcm, sessionAlive
                                        , closeSession, burstReplies )

----------------------------------------------------------------------
-- Configuration & result shapes.

data DriverConfig = DriverConfig
  { dcAgdaBin     :: !FilePath
    -- ^ Path / name of the @agda@ binary. Defaults to @"agda"@.
  , dcModuleFile  :: !FilePath
    -- ^ The @.agda@ / @.lagda*@ source file to load.
  , dcIncludePaths :: ![FilePath]
    -- ^ @-i@ directories passed to @agda@ via the protocol's
    -- @Cmd_load@ payload.
  , dcExtraArgs   :: ![String]
    -- ^ Extra arguments handed to @agda --interaction-json@ on the
    -- command line (in addition to @--interaction-json@). E.g.
    -- @["--allow-unsolved-metas"]@.
  , dcVerbose     :: !Bool
    -- ^ Echo the @IOTCM@ command and Agda's stderr to our stderr for
    -- debugging.
  } deriving (Show)

-- | Outcome of one driver invocation. Successful runs come back as
-- 'DriverOk' carrying every goal extracted from the
-- @AllGoalsWarnings@ reply. Every other path is a structured error
-- with a stable tag (see 'driverErrorTag') so the @main@ wrapper can
-- choose a distinct exit code per failure mode.
data DriverResult
  = DriverOk
      { drModuleName :: !Text
      , drGoals      :: ![Goal]
      }
  | DriverError !DriverError
  deriving (Show)

data DriverError
  = MissingBinary !FilePath !String
    -- ^ The agda binary couldn't be executed at all. Most common
    -- cause: typo in @--agda-bin@ or agda not on @$PATH@.
  | AgdaNonZero  !Int !String
    -- ^ Agda exited non-zero. We capture @stderr@ alongside the exit
    -- code for the human diagnostic but don't try to parse it.
  | BadOutput    ![String]
    -- ^ Agda exited zero but at least one line of stdout couldn't be
    -- parsed against our 'Reply' schema. List is the per-line error
    -- messages.
  | AgdaReportedError !Text
    -- ^ Agda's protocol emitted a structured @{"kind":"Error"}@
    -- DisplayInfo reply — e.g. a parse error, an ambiguous import,
    -- or a missing library — before reaching the goal pass. The text
    -- is the rendered error message lifted off the @info.error@
    -- field. Distinct from 'AgdaNonZero' because the @agda@
    -- subprocess often still exits zero in this case (the error is
    -- reported via the JSON channel rather than via exit code).
  | NoGoalsReply
    -- ^ Agda emitted at least one reply but none of them was an
    -- @AllGoalsWarnings@ AND no @Error@ reply either. This shouldn't
    -- happen on a successful @Cmd_load@; treat it as a protocol-skew
    -- signal.
  deriving (Show)

-- | Stable string tag for 'DriverError'. Useful for JSON output and
-- the exit-code switch in 'MainGoals'.
driverErrorTag :: DriverError -> String
driverErrorTag = \case
  MissingBinary{}     -> "missing-binary"
  AgdaNonZero{}       -> "agda-nonzero"
  BadOutput{}         -> "bad-output"
  AgdaReportedError{} -> "agda-reported-error"
  NoGoalsReply        -> "no-goals-reply"

----------------------------------------------------------------------
-- Entry point.

-- | Per-module command timeout. The historical one-shot driver waited
-- indefinitely; a generous bound here just stops a wedged @agda@ from
-- hanging the whole batch (a timeout poisons the session, which the batch
-- loop then respawns for the next file).
goalsTimeoutMicros :: Int
goalsTimeoutMicros = 600 * 1000000   -- 10 min per module

-- | Drive @agda --interaction-json@ for a list of modules over a SINGLE
-- persistent agda process — reusing one process (and its on-disk @.agdai@
-- cache) across files instead of spawning one per file.
--
-- Goal extraction per file is byte-identical to the historical one-shot
-- path: the same @Cmd_load@ yields the same @AllGoalsWarnings@ whether the
-- process is fresh or reused (a load resets the active module), and
-- 'scanReplies' is unchanged.
--
-- Resilience: if the session dies mid-batch (e.g. a module times out and
-- poisons it) the next file respawns a fresh process; the poisoning file
-- reports a 'DriverError'. If @agda@ can't be started at all, every file
-- reports 'MissingBinary' (matching the per-file one-shot behaviour).
runDriverBatch :: DriverConfig -> [FilePath] -> IO [DriverResult]
runDriverBatch _    []              = pure []
runDriverBatch tmpl files@(first:_) = do
  let scfg = SessionConfig
               { scAgdaBin       = dcAgdaBin tmpl
               , scExtraArgs     = dcExtraArgs tmpl
               , scTimeoutMicros = goalsTimeoutMicros
               }
  est <- startSession scfg first
  case est of
    Left err ->
      pure [ DriverError (MissingBinary (dcAgdaBin tmpl) (T.unpack err)) | _ <- files ]
    Right sess0 -> do
      ref     <- newIORef sess0
      results <- forM files $ \f -> do
        sess  <- readIORef ref
        alive <- sessionAlive sess
        sess' <- if alive
                   then pure sess
                   else do                       -- prior file poisoned it: respawn
                     closeSession sess
                     r <- startSession scfg f
                     case r of
                       Right s -> writeIORef ref s >> pure s
                       Left _  -> pure sess       -- respawn failed; load will SendDied
        loadInSession sess' (tmpl { dcModuleFile = f })
      readIORef ref >>= closeSession
      pure results

-- | Drive a single module: one process, loaded once, then closed. A thin
-- wrapper over 'runDriverBatch' so the one-shot and batch paths share the
-- same session machinery.
runDriver :: DriverConfig -> IO DriverResult
runDriver cfg = headOr (DriverError NoGoalsReply) <$> runDriverBatch cfg [dcModuleFile cfg]
  where headOr d xs = case xs of (x:_) -> x; [] -> d

-- | Send one @Cmd_load@ over an existing session and interpret the reply
-- burst into a 'DriverResult'.
loadInSession :: Session -> DriverConfig -> IO DriverResult
loadInSession sess DriverConfig{..} = do
  let modName = T.pack (takeBaseName dcModuleFile)
      iotcm   = iotcmLoad dcModuleFile dcIncludePaths
  when dcVerbose $ hPutStrLn stderr ("agda-goals: > " ++ iotcm)
  out <- sendIotcm sess iotcm
  when dcVerbose $
    hPutStrLn stderr ("agda-goals: < " ++ show (length (burstReplies out)) ++ " reply object(s)")
  pure (resultFromOutcome modName out)

-- | Map a session reply burst onto the 'DriverResult' the bucketer
-- consumes. A session that timed out or died maps to a structured error;
-- otherwise the unchanged 'scanReplies' decides goals-vs-error.
resultFromOutcome :: Text -> SendOutcome -> DriverResult
resultFromOutcome modName out = case out of
  SendTimeout _   -> DriverError (AgdaNonZero (-1) "agda timed out (session reset)")
  SendDied _ err  -> DriverError (AgdaNonZero (-1) ("agda session ended: " ++ T.unpack err))
  SendOk rs       -> case scanReplies rs of
    ScanGoals goals   -> DriverOk { drModuleName = modName, drGoals = goals }
    ScanAgdaError msg -> DriverError (AgdaReportedError msg)
    ScanNoGoalsReply  -> DriverError NoGoalsReply

-- | Result of scanning the reply stream. An 'Error' DisplayInfo
-- takes precedence over 'AllGoalsWarnings': agda may emit an empty
-- AllGoalsWarnings *and* an Error in the same load when typechecking
-- aborts midway, and surfacing the error message is strictly more
-- useful than reporting zero goals in that case.
data ScanResult
  = ScanGoals      ![Goal]
  | ScanAgdaError  !Text
  | ScanNoGoalsReply

-- | Walk the reply stream once, recording an Error message if one
-- appears and the goal list otherwise. Error wins on collision.
scanReplies :: [Reply] -> ScanResult
scanReplies = go Nothing Nothing
  where
    go mErr mGs []     = case (mErr, mGs) of
      (Just msg, _)   -> ScanAgdaError msg
      (Nothing, Just gs) -> ScanGoals gs
      (Nothing, Nothing) -> ScanNoGoalsReply
    go mErr mGs (r:rs) = case r of
      ReplyDisplayInfo (ErrorReply msg)
        -> go (mErr <|> Just msg) mGs rs
      ReplyDisplayInfo (AllGoalsWarnings gs _ _)
        -> go mErr (mGs <|> Just gs) rs
      _ -> go mErr mGs rs

