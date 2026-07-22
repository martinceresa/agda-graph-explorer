{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @agda-auto@ orchestration: build a minimal, batch-shaped 'ServerState',
-- then fill every open hole in each input file via 'autoAllCore' — the same
-- two-pass Mimer + graph-hint ladder the @agda-explore@ daemon runs (one
-- implementation, invoked transport-free).
--
-- A single explicit file produces a bare report (or bare JSON). Passing a
-- directory, or more than one file, is __project mode__: the files are swept
-- serially in dependency order (imports first, from the graph — so a filled
-- import is visible to its dependents in the same @--write@ run), each with a
-- per-file section plus an aggregate totals footer (or a @{files, summary}@
-- JSON envelope), an optional overall @--wall-budget@, and the worst per-file
-- exit code.
module AgdaAuto.Run
  ( runAuto
  ) where

import           Control.Exception  ( SomeException, finally, try )
import           Control.Monad      ( forM, when )
import           Data.Aeson         ( Value, encode, object, toJSON, (.=) )
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.List          ( sort, sortOn )
import qualified Data.Map.Strict    as M
import           Data.Maybe         ( fromMaybe, isJust, listToMaybe )
import           Data.Text          ( Text )
import qualified Data.Text          as T
import qualified Data.Text.IO       as TIO
import           Data.Time.Clock    ( diffUTCTime, getCurrentTime )
import           System.Directory   ( doesDirectoryExist, doesFileExist,
                                      getCurrentDirectory, listDirectory,
                                      makeAbsolute )
import           System.Exit        ( ExitCode(..) )
import           System.FilePath    ( (</>) )
import           System.IO          ( hPutStrLn, stderr )

import           AgdaAuto.CLI       ( AutoOpts(..) )
import           AgdaAuto.Report    ( ledgerLines, outcomeExit, outcomeJson,
                                      renderHumanReport, summarize, summaryJson,
                                      summaryLine, worstExit )
import           AgdaGraph.ConfigCore ( firstExisting, isAgdaSourceFile )
import           AgdaGraph.Index    ( moduleDependencyOrder )
import           AgdaGraph.Schema   ( ExpandedGraph )
import           AgdaInteract.AutoReport ( AutoAllOutcome(..), annotationEdits )
import           AgdaInteract.Edit  ( unifiedDiff )
import           AgdaInteract.Tools ( applyOrDiff, autoAllCore, closeAllSessions,
                                      runRepair )
import           AgdaMcp.Config     ( orderNub )
import           AgdaMcp.State

-- ---------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------

runAuto :: AutoOpts -> IO ExitCode
runAuto o = do
  cwd  <- getCurrentDirectory
  proj <- makeAbsolute (fromMaybe cwd (aoProject o))
  case aoFiles o of
    [] -> do
      hPutStrLn stderr "agda-auto: no input. Pass FILE.agda (or a directory; see --help)."
      pure (ExitFailure 2)
    args -> do
      (files, sawDir) <- expandInputs args
      if null files
        then do
          hPutStrLn stderr ("agda-auto: no Agda source files under " ++ unwords args ++ ".")
          pure (ExitFailure 2)
        else do
          mGraph   <- resolveGraph proj (aoGraph o)
          overlays <- loadOverlays =<< mapM makeAbsolute (aoOverlays o)
          incl     <- mapM makeAbsolute
                        (if null (aoIncludes o) then [proj] else aoIncludes o)
          let cfg = buildCfg o proj mGraph overlays incl
          case mGraph of
            Just g  -> hPutStrLn stderr ("agda-auto: hint graph " ++ g)
            Nothing -> hPutStrLn stderr
              "agda-auto: no graph found; running plain Mimer (no lemma hints)."
          ss <- newServerState cfg
          let projectMode = sawDir || length files > 1
          runSweep ss o projectMode files `finally` closeAllSessions ss

-- ---------------------------------------------------------------------
-- Input expansion + ordering
-- ---------------------------------------------------------------------

-- | Expand the positional args into a deduped file list; a directory is walked
-- for Agda sources, an explicit file kept verbatim. Returns whether any arg was
-- a directory (which forces project mode even for a single resulting file).
expandInputs :: [FilePath] -> IO ([FilePath], Bool)
expandInputs args = do
  parts <- forM args $ \a -> do
    isDir <- doesDirectoryExist a
    if isDir then (\fs -> (fs, True)) <$> collectAgda 20 a
             else pure ([a], False)
  abss <- mapM makeAbsolute (concatMap fst parts)
  pure (orderNub abss, any snd parts)

-- | Agda sources under a root, bounded depth, skipping VCS / build dirs;
-- sorted for determinism.
collectAgda :: Int -> FilePath -> IO [FilePath]
collectAgda depth root
  | depth < 0 = pure []
  | otherwise = do
      isDir <- doesDirectoryExist root
      if not isDir
        then do isF <- doesFileExist root; pure [root | isF && isAgdaSourceFile root]
        else do
          es <- either (const []) id
                  <$> (try (listDirectory root) :: IO (Either SomeException [FilePath]))
          fmap (sort . concat) $ forM es $ \e ->
            if e `elem` skipDirs then pure []
            else collectAgda (depth - 1) (root </> e)
  where
    skipDirs = [".git", "dist-newstyle", ".agda-explore", "_build", "node_modules"]

-- | Order the files for processing. With a graph, by their module's
-- dependency rank (imports first; 'moduleDependencyOrder'), lexicographic on
-- ties / unknown modules; graph-less, purely lexicographic. Deterministic.
orderFiles :: ServerState -> [FilePath] -> IO [FilePath]
orderFiles ss files = do
  mLd <- either (const Nothing) (Just . fst) <$> ensureFresh ss
  case mLd of
    Nothing -> pure (sort files)
    Just ld -> do
      let rankMap = M.fromList (zip (moduleDependencyOrder (ldIndex ld)) [0 :: Int ..])
      keyed <- forM files $ \f -> do
        mMod <- moduleOfFile f
        pure (fromMaybe maxBound (mMod >>= (`M.lookup` rankMap)), f)
      pure (map snd (sortOn (\(r, f) -> (r, f)) keyed))

-- | The declared module name of a file (first @module NAME where@ line),
-- lenient — 'Nothing' on an unreadable / module-less file.
moduleOfFile :: FilePath -> IO (Maybe Text)
moduleOfFile f = do
  r <- try (TIO.readFile f) :: IO (Either SomeException Text)
  pure $ case r of
    Left _  -> Nothing
    Right t -> listToMaybe [ n | l <- T.lines t, "module" : n : _ <- [T.words l] ]

-- ---------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------

resolveGraph :: FilePath -> Maybe FilePath -> IO (Maybe FilePath)
resolveGraph _    (Just g) = do
  ga <- makeAbsolute g
  ok <- doesFileExist ga
  if ok
    then pure (Just ga)
    else do
      hPutStrLn stderr ("agda-auto: --graph " ++ ga ++ " not found; running plain Mimer.")
      pure Nothing
resolveGraph proj Nothing =
  firstExisting [ proj </> "deps.json", proj </> ".agda-explore" </> "deps.json" ]

-- | The batch-shaped 'Config': preloaded (never rebuild), no watcher /
-- inspector / control / query-log, one session, interaction on (this tool /is/
-- the write bridge). A graph-less run leaves 'cfgGraphPath' empty — the first
-- 'ensureFresh' returns @Left@, which the ladder treats as "no snapshot" ⇒
-- plain Mimer.
buildCfg :: AutoOpts -> FilePath -> Maybe FilePath -> [ExpandedGraph]
         -> [FilePath] -> Config
buildCfg o proj mGraph overlays incl = defaultConfig
  { cfgProjectRoot    = proj
  , cfgIncludes       = incl
  , cfgPreloaded      = True
  , cfgGraphPath      = fromMaybe "" mGraph
  , cfgAutoRebuild    = False
  , cfgWatch          = False
  , cfgIncremental    = False
  , cfgQueryLog       = False
  , cfgInspect        = False
  , cfgControlPort    = 0
  , cfgEnableInteract = True
  , cfgMaxSessions    = 1
  , cfgAgdaBin        = aoAgdaBin o
  , cfgInteractArgs   = aoAgdaArgs o
  , cfgRankIdf        = aoRankIdf o
  , cfgPremiseSelect  = aoPremiseSelect o
  , cfgNoHintBatch    = aoNoHintBatch o
  , cfgNoAutoLadder   = aoNoAutoLadder o
  , cfgOverlays       = overlays
  }

-- ---------------------------------------------------------------------
-- Sweep
-- ---------------------------------------------------------------------

-- | One file's result: exit code, an operational error (if any), the human
-- section text, the JSON object, and the @(goals, filled, annotated,
-- unsolved)@ counts for the aggregate.
data FileRun = FileRun
  { frFile   :: !FilePath
  , frCode   :: !ExitCode
  , frError  :: !(Maybe Text)
  , frReport :: !Text
  , frJson   :: !Value
  , frCounts :: !(Int, Int, Int, Int)
  }

runSweep :: ServerState -> AutoOpts -> Bool -> [FilePath] -> IO ExitCode
runSweep ss o projectMode files = case (projectMode, files) of
  -- Single explicit file: bare report / bare JSON.
  (False, f : _) -> do
      fr <- processFile ss o f
      case frError fr of
        Just e  -> TIO.hPutStrLn stderr ("agda-auto: " <> e)
        Nothing -> if aoJson o then BLC.putStrLn (encode (frJson fr))
                               else TIO.putStr (frReport fr)
      pure (frCode fr)
  -- Project mode: sweep in dependency order, per-file sections + totals.
  -- With --fixpoint + --write, re-sweep until a pass fills no new hole
  -- (a filled import can unblock a dependent).
  _ -> do
      ordered <- orderFiles ss files
      if aoFixpoint o && aoWrite o then fixpoint ordered 1 else onePass ordered
  where
    budget = aoWallBudget o
    onePass ordered = do
      start <- getCurrentTime
      runs  <- sweep start ordered
      emitProject o runs
      pure (worstExit (map frCode runs))
    fixpoint ordered k = do
      when (k > 1 && not (aoJson o)) $
        TIO.putStrLn ("══ fixpoint pass " <> T.pack (show k) <> " ══")
      start <- getCurrentTime
      runs  <- sweep start ordered
      let filled = sum [ fi | (_, fi, _, _) <- map frCounts runs ]
      if filled > 0 && k < maxFixpointPasses
        then fixpoint ordered (k + 1)
        else emitProject o runs >> pure (worstExit (map frCode runs))
    -- Stream one file's human section as we go (progress on a long sweep);
    -- JSON is collected and emitted once as an envelope, so streams nothing.
    streamSection fr = when (not (aoJson o)) $ do
      TIO.putStrLn ("── " <> T.pack (frFile fr) <> " ──")
      case frError fr of
        Just e  -> TIO.hPutStrLn stderr ("agda-auto: " <> e)
        Nothing -> TIO.putStr (frReport fr)
    -- Process in order; between files, honour the overall wall budget (finish
    -- the current file, then report the current + rest as budget-skipped).
    sweep _     []       = pure []
    sweep start (f : fs) = do
      over <- if budget <= 0 then pure False else do
                now <- getCurrentTime
                pure (realToFrac (diffUTCTime now start) >= (fromIntegral budget :: Double))
      if over
        then do
          let skipped = map budgetSkip (f : fs)
          mapM_ streamSection skipped
          pure skipped
        else do
          fr <- processFile ss o f
          streamSection fr
          (fr :) <$> sweep start fs

-- | A file the wall budget stopped us reaching.
budgetSkip :: FilePath -> FileRun
budgetSkip f = FileRun
  { frFile = f, frCode = ExitFailure 1
  , frError = Nothing
  , frReport = T.pack f <> ": skipped (wall budget exceeded)\n"
  , frJson = object [ "file" .= f, "status" .= ("skipped-budget" :: Text) ]
  , frCounts = (0, 0, 0, 0)
  }

-- | Emit a project sweep: a totals footer (human) or a @{files, summary}@
-- envelope (JSON). The per-file human sections were already streamed.
emitProject :: AutoOpts -> [FileRun] -> IO ()
emitProject o runs
  | aoJson o  = BLC.putStrLn (encode (object [ "files" .= map frJson runs, "summary" .= summaryJson s ]))
  | otherwise = TIO.putStrLn (summaryLine s)
  where s = summarize (map frCounts runs)

-- ---------------------------------------------------------------------
-- One file
-- ---------------------------------------------------------------------

-- | Max @--fixpoint@ passes (a safety bound; fills are monotone, so it
-- converges well under this on any real project).
maxFixpointPasses :: Int
maxFixpointPasses = 5

-- | Run the ladder on one file (annotation of unsolved holes happens in
-- 'autoAllCore', gated by the @annotate@ arg), apply / diff the result, and
-- package the human section, JSON object, and counts. Pure of any printing.
--
-- @--repair@: if the file fails to load, run the import-only,
-- spec-preserving @repair@ first (respecting @--write@), then re-probe once —
-- so a missing-import scope error stops being a dead exit-2. @--ledger@ appends
-- one JSON line per goal (best-effort; a ledger write never fails the run).
processFile :: ServerState -> AutoOpts -> FilePath -> IO FileRun
processFile ss o file = do
  eo0 <- autoAllCore ss (autoAllArgs o file)
  (eo, repairHint) <- case eo0 of
    Left _ | aoRepair o -> do
      rr  <- runRepairTool ss (aoWrite o) file
      eo1 <- autoAllCore ss (autoAllArgs o file)
      pure (eo1, case (eo1, rr) of
                   (Left _, Right t) | not (T.null t) -> "\n\n--repair suggested:\n" <> t
                   _                                  -> "")
    _ -> pure (eo0, "")
  case eo of
    Left err   -> pure (errRun (err <> repairHint))
    Right outcome -> do
      logLedger o file outcome
      bodyE <- case aoNew outcome of
        Nothing  -> pure (Right "")
        Just new -> applyOrDiff ss (aoWrite o) file (aoOrig outcome) new
      case bodyE of
        Left err   -> pure (errRun err)
        Right body -> do
          let wrote    = aoWrite o && isJust (aoNew outcome)
              pureDiff = maybe "" (\new -> T.pack (unifiedDiff file (aoOrig outcome) new)) (aoNew outcome)
              reportTxt = renderHumanReport outcome
                            <> "\n" <> (if T.null body then "" else body <> "\n")
          pure FileRun
            { frFile   = file
            , frCode   = outcomeExit outcome
            , frError  = Nothing
            , frReport = reportTxt
            , frJson   = outcomeJson wrote pureDiff outcome
            , frCounts = countsOf o outcome
            }
  where
    errRun e = FileRun
      { frFile = file, frCode = ExitFailure 2, frError = Just e
      , frReport = "", frJson = object [ "file" .= file, "error" .= e ]
      , frCounts = (0, 0, 0, 0) }

-- | Invoke the graph-backed @repair@ runner (import-only, spec-preserving) on a
-- file, honouring @--write@ (dry ⇒ it returns a suggested-imports diff). Calls
-- the exported 'runRepair' directly rather than looking it up by name in
-- 'interactTools'.
runRepairTool :: ServerState -> Bool -> FilePath -> IO (Either Text Text)
runRepairTool ss write file =
  runRepair ss (object [ "file" .= T.pack file, "write" .= write ])

-- | Append one JSON line per goal to the @--ledger@ file (best-effort; a write
-- failure is reported to stderr but never fails the run).
logLedger :: AutoOpts -> FilePath -> AutoAllOutcome -> IO ()
logLedger o file outcome = case aoLedger o of
  Nothing -> pure ()
  Just p  -> do
    r <- try (BLC.appendFile p (BLC.unlines (map encode (ledgerLines file outcome))))
           :: IO (Either SomeException ())
    either (\e -> hPutStrLn stderr ("agda-auto: ledger write failed: " ++ show e))
           (const (pure ())) r

-- | Per-file @(goals, filled, annotated, unsolved)@ for the aggregate. The
-- annotated count re-derives the marker edits (pure, cheap) from the outcome.
countsOf :: AutoOpts -> AutoAllOutcome -> (Int, Int, Int, Int)
countsOf o outcome =
  ( aoGoalCount outcome
  , length (aoSolved outcome)
  , length (annotationEdits (aoAnnotate o) (aoTimeout o) (aoOrig outcome) (aoGoals outcome))
  , aoGoalCount outcome - length (aoSolved outcome)
  )

-- | The args 'autoAllCore' reads (file / timeout / hints / write / annotate).
autoAllArgs :: AutoOpts -> FilePath -> Value
autoAllArgs o file = object
  [ "file"     .= T.pack file
  , "timeout"  .= toJSON (aoTimeout o)
  , "hints"    .= toJSON (aoHints o)
  , "write"    .= aoWrite o
  , "annotate" .= aoAnnotate o
  ]
