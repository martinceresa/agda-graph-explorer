{-# LANGUAGE OverloadedStrings #-}
-- | @agda-explore doctor@: a one-shot environment preflight. Runs every
-- readiness check the daemon depends on and prints one ✓ / ! / ✗ / – line
-- each, with a fix hint on every ✗, then exits 0 iff nothing failed.
--
-- Read-only by construction: it resolves and version-probes binaries and
-- decodes an existing graph, but never spawns an @agda-deps@ build. Reuses
-- the daemon's own 'Config', 'findBin', and 'loadExpandedGraph' so what it
-- reports is exactly what the server would see.
module AgdaMcp.Doctor
  ( runDoctor
  ) where

import           Control.Exception  (SomeException, try)
import           Data.Aeson         (Value, object, toJSON, (.=))
import qualified Data.Aeson         as A
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.Maybe         (isJust)
import qualified Data.Text          as T
import           System.Directory   (createDirectoryIfMissing, doesFileExist,
                                     removeFile)
import           System.Exit        (ExitCode (..))
import           System.FilePath    ((</>))
import           System.Process     (readProcessWithExitCode)

import           AgdaGraph.Schema   (Definition (..), ExpandedGraph (..),
                                     loadExpandedGraph)
import           AgdaGraph.Version  (versionLine)
import           AgdaMcp.State      (Config (..), binaryIdent,
                                     currentNodeKeyVersion, findBin)

-- | The outcome of one check. 'Skip' is a deliberate non-check (e.g. an
-- @agda@ probe when @--enable-interact@ is off), not a failure.
data Status = Ok | Warn | Bad | Skip
  deriving (Eq)

data Check = Check
  { ckLabel  :: !String
  , ckStatus :: !Status
  , ckDetail :: !String
  , ckHint   :: !(Maybe String)   -- ^ shown on a ✗ (or !).
  }

sym :: Status -> String
sym Ok   = "\10003"   -- ✓
sym Warn = "!"
sym Bad  = "\10007"   -- ✗
sym Skip = "\8211"    -- –

statusText :: Status -> T.Text
statusText Ok   = "ok"
statusText Warn = "warn"
statusText Bad  = "fail"
statusText Skip = "skip"

-- | Run the preflight and print it. @mConfigPath@ is the config file the CLI
-- resolved (for the config check); @asJson@ selects the machine-readable
-- envelope. Exit 0 iff no check failed (warnings and skips do not fail).
runDoctor :: Config -> Maybe FilePath -> Bool -> IO ExitCode
runDoctor cfg mConfigPath asJson = do
  checks <- gather cfg mConfigPath
  if asJson then emitJson checks else emitHuman checks
  pure $ if any ((== Bad) . ckStatus) checks then ExitFailure 1 else ExitSuccess

-- | Build the check list, in a fixed reporting order.
gather :: Config -> Maybe FilePath -> IO [Check]
gather cfg mConfigPath = do
  ident <- binaryIdent
  let live      = not (cfgPreloaded cfg)
      graphFile = cfgGraphPath cfg

  let identC = Check "binary" Ok (versionLine "agda-explore" ++ "  " ++ ident) Nothing

  let configC = case mConfigPath of
        Just p  -> Check "config" Ok ("using " ++ p) Nothing
        Nothing -> Check "config" Ok "none discovered (built-in defaults)" Nothing

  let modeC = Check "mode" Ok (modeDesc cfg) Nothing

  -- Graph: decode the file the daemon would read (preloaded, or a previous
  -- live build's published union). Absent-in-live is a Skip, not a failure —
  -- the daemon builds it on first run.
  graphExists <- doesFileExist graphFile
  (graphChecks) <-
    if not graphExists
      then pure [ if live
                    then Check "graph" Skip
                           ("no graph built yet at " ++ graphFile
                              ++ " (the daemon builds it on first run)") Nothing
                    else Check "graph" Bad ("not found: " ++ graphFile)
                           (Just "pass --graph FILE, or a --project/--entry to build one") ]
      else do
        e <- loadExpandedGraph graphFile
        case e of
          Left err -> pure [ Check "graph" Bad (graphFile ++ ": " ++ firstLine err)
                               (Just "regenerate with agda-deps --json-mode=expanded") ]
          Right g  -> pure (graphOk graphFile g)

  -- agda-deps: only needed in live mode.
  depsC <-
    if not live
      then pure (Check "agda-deps" Skip "preloaded graph — not needed" Nothing)
      else do
        m <- findBin "agda-deps" (cfgDepsBin cfg) "AGDA_DEPS_BIN"
        case m of
          Nothing -> pure (Check "agda-deps" Bad "not found on --agda-deps-bin / $AGDA_DEPS_BIN / $PATH"
                             (Just "install agda-deps (see README 'Getting agda-deps') or pass --agda-deps-bin"))
          Just p  -> do v <- probeVersion p
                        pure (Check "agda-deps" Ok (p ++ v) Nothing)

  -- agda: only probed under --enable-interact (it backs the write bridge,
  -- agda-goals, agda-auto).
  agdaC <-
    if not (cfgEnableInteract cfg)
      then pure (Check "agda" Skip "pass --enable-interact to check" Nothing)
      else do
        m <- findBin "agda" (cfgAgdaBin cfg) "AGDA_BIN"
        case m of
          Nothing -> pure (Check "agda" Bad "not found on --agda-bin / $AGDA_BIN / $PATH"
                             (Just "install Agda (https://agda.readthedocs.io/en/latest/getting-started/installation.html) or pass --agda-bin"))
          Just p  -> do v <- probeVersion p
                        pure (Check "agda" Ok (p ++ v) Nothing)

  -- Out-dir writability (live mode only): the daemon writes the generated
  -- graph + telemetry there.
  outC <-
    if not live
      then pure (Check "out-dir" Skip "preloaded — nothing written" Nothing)
      else do
        w <- probeWritable (cfgOutDir cfg)
        pure $ if w then Check "out-dir" Ok ("writable: " ++ cfgOutDir cfg) Nothing
                    else Check "out-dir" Bad ("not writable: " ++ cfgOutDir cfg)
                           (Just "pass --out-dir to a writable location")

  -- Overlays that decoded at startup (loadOverlays already warned on bad ones).
  let nOverlays = length (cfgOverlays cfg)
      overlayC
        | nOverlays == 0 = Check "overlays" Skip "none" Nothing
        | otherwise      = Check "overlays" Ok (show nOverlays ++ " overlay graph(s) loaded") Nothing

  pure $ [identC, configC, modeC] ++ graphChecks ++ [depsC, agdaC, outC, overlayC]

-- | Checks derived from a successfully-decoded graph: a top-level "graph" ok
-- line, a node-key-version comparison, and the three capability probes (each
-- naming the tools it gates).
graphOk :: FilePath -> ExpandedGraph -> [Check]
graphOk path g =
  [ Check "graph" Ok
      (path ++ " (" ++ show (length (egDefinitions g)) ++ " defs, "
         ++ show (length (egModules g)) ++ " modules)") Nothing
  , nodeKeyC
  , capC "signatures" (any (isJust . defSig) (egDefinitions g))
      "type_of / find_lemma report elaborated types"
      "rebuild with --with-signatures for type_of / find_lemma quality"
  , capC "edge provenance" (not (null (egEdgeProvenance g)))
      "premise-select / silhouette available"
      "rebuild with provenance so --premise-select and silhouette work"
  , capC "subterm hashes" (not (null (egSubtermHashes g)))
      "similar_bodies / term-cluster available"
      "rebuild with --with-term-hashes for similar_bodies / term-cluster"
  ]
  where
    nkv = egNodeKeyVersion g
    nodeKeyC
      | nkv == currentNodeKeyVersion =
          Check "node-key version" Ok ("v" ++ show nkv ++ " (current)") Nothing
      | nkv < currentNodeKeyVersion =
          Check "node-key version" Warn
            ("v" ++ show nkv ++ " < current v" ++ show currentNodeKeyVersion
               ++ " (stale naming; queries may key nodes by an old convention)")
            (Just "regenerate the graph to refresh node keys")
      | otherwise =
          Check "node-key version" Warn
            ("v" ++ show nkv ++ " > current v" ++ show currentNodeKeyVersion
               ++ " (graph newer than this binary)")
            (Just "rebuild agda-explore against the producer's schema")
    capC label present okDetail hint
      | present   = Check label Ok okDetail Nothing
      | otherwise = Check label Warn "absent in this graph" (Just hint)

-- | One-line mode description (mirrors "MainMcp".@modeDesc@, kept local so
-- 'Doctor' imports no CLI module).
modeDesc :: Config -> String
modeDesc c
  | cfgPreloaded c = "preloaded graph " ++ cfgGraphPath c
  | otherwise = "live (regenerates via agda-deps)"

-- | Best-effort @<bin> --version@, returned as @" — <first line>"@ or empty.
probeVersion :: FilePath -> IO String
probeVersion p = do
  r <- try (readProcessWithExitCode p ["--version"] "")
         :: IO (Either SomeException (ExitCode, String, String))
  pure $ case r of
    Right (ExitSuccess, out, _) | (l:_) <- lines out -> " — " ++ l
    _                                                 -> ""

-- | Can we create + write under this directory?
probeWritable :: FilePath -> IO Bool
probeWritable dir = do
  r <- try act :: IO (Either SomeException ())
  pure (either (const False) (const True) r)
  where
    act = do
      createDirectoryIfMissing True dir
      let probe = dir </> ".agda-explore-doctor-probe"
      writeFile probe ""
      removeFile probe

firstLine :: String -> String
firstLine s = case lines s of (l:_) -> l; [] -> s

-- | Human report: one line per check, a "→ hint" line under each ✗/!.
emitHuman :: [Check] -> IO ()
emitHuman checks = do
  putStrLn "agda-explore doctor"
  putStrLn ""
  mapM_ line checks
  putStrLn ""
  let bad  = length (filter ((== Bad)  . ckStatus) checks)
      warn = length (filter ((== Warn) . ckStatus) checks)
  putStrLn $ if bad == 0
    then "OK" ++ (if warn > 0 then " (" ++ show warn ++ " warning(s))" else "")
    else show bad ++ " problem(s) found — see the ✗ lines above."
  where
    line c = do
      putStrLn $ "  " ++ sym (ckStatus c) ++ " "
                   ++ pad 18 (ckLabel c) ++ ckDetail c
      case ckHint c of
        Just h | ckStatus c `elem` [Bad, Warn] ->
          putStrLn $ "      \8594 " ++ h   -- → hint
        _ -> pure ()
    pad n s = s ++ replicate (max 1 (n - length s)) ' '

-- | JSON envelope: @{"ok":Bool,"checks":[{check,status,detail,hint}]}@.
emitJson :: [Check] -> IO ()
emitJson checks = BLC.putStrLn (A.encode payload)
  where
    payload :: Value
    payload = object
      [ "ok"     .= not (any ((== Bad) . ckStatus) checks)
      , "checks" .= map one checks
      ]
    one c = object
      [ "check"  .= ckLabel c
      , "status" .= statusText (ckStatus c)
      , "detail" .= ckDetail c
      , "hint"   .= maybe A.Null (toJSON . T.pack) (ckHint c)
      ]
