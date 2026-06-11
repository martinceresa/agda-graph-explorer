{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Command-line driver for @agda-optimization@.
--
-- Invocation shape:
--
-- > agda-optimization <subcmd> <graph.json> [opts...]
--
-- Subcommands: @motif@, @load-bearing@, @polyglot@, @fingerprint@,
-- @debt@, @basket@. Each subcommand:
--   1. Loads the expanded graph with 'AgdaGraph.Schema.loadExpandedGraph'.
--   2. Builds the in-memory 'Index'.
--   3. Dispatches to the corresponding analysis module's 'run'.
--
-- Global flags (recognised in any subcommand position):
--   @--json@         => set 'gOutFormat' to 'OutJson'.
--   @--out FILE@     => set 'gOutPath'.
--   @-h@/@--help@    => print usage, exit 0.
--
-- This module deliberately uses hand-rolled arg parsing (no
-- 'optparse-applicative' dependency) to keep the build closure small.
module AgdaOptimization.CLI
  ( run
  , GlobalOpts(..)
  , OutFormat(..)
  ) where

import           Control.Applicative     ( (<|>) )
import           Control.Monad           ( when )
import qualified Data.Aeson              as A
import           Data.List               ( find )
import           Data.Maybe              ( fromMaybe )
import           Data.Version            ( showVersion )
import           System.Environment      ( getArgs )
import           System.Exit             ( exitFailure, exitSuccess )
import           System.IO               ( hPutStrLn, stderr )

import qualified Paths_agda_graph_explorer as Paths

import           AgdaGraph.Schema        ( loadExpandedGraph )
import           AgdaGraph.Index         ( Index, buildIndex, idxSyntheticCount
                                         , idxNodeCount, idxRealCount )

import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , defaultGlobalOpts )
import           AgdaOptimization.Config ( Config(..), discoverConfigPath
                                         , loadConfig, subSectionFor
                                         , globalSection, applyGlobal )
import           AgdaOptimization.FlagSpec ( FlagSpec, flagName, flagHelp
                                           , renderFlagHelp )
import qualified AgdaOptimization.Motif       as Motif
import qualified AgdaOptimization.LoadBearing as LoadBearing
import qualified AgdaOptimization.Polyglot    as Polyglot
import qualified AgdaOptimization.Fingerprint as Fingerprint
import qualified AgdaOptimization.Debt        as Debt
import qualified AgdaOptimization.Basket      as Basket
import qualified AgdaOptimization.Ledger      as Ledger
import qualified AgdaOptimization.Echo        as Echo
import qualified AgdaOptimization.Gravity     as Gravity
import qualified AgdaOptimization.Pyre        as Pyre
import qualified AgdaOptimization.Chokepoint  as Chokepoint
import qualified AgdaOptimization.Silhouette  as Silhouette
import qualified AgdaOptimization.Entwine     as Entwine
import qualified AgdaOptimization.Fiedler     as Fiedler
import qualified AgdaOptimization.Horizon     as Horizon
import qualified AgdaOptimization.Strata      as Strata
-- AST-level subterm fingerprinting.
import qualified AgdaOptimization.TermCluster  as TermCluster
-- Signature-provenance frequent-itemset mining.
import qualified AgdaOptimization.ConceptBundle as ConceptBundle

defaultGlobal :: GlobalOpts
defaultGlobal = defaultGlobalOpts

-- | Names of all subcommands, paired with a one-line description.
subcommands :: [(String, String)]
subcommands =
  [ ("motif",        "frequent subgraph motifs across the project")
  , ("load-bearing", "definitions that support the most valuable results")
  , ("polyglot",     "definitions used widely across disparate contexts")
  , ("fingerprint",  "near-duplicate subgraphs via Weisfeiler-Lehman labels")
  , ("debt",         "postulates / holes / foundational shims propagating downstream")
  , ("basket",       "association rules over co-used definitions")
  , ("ledger",       "per-theorem trust budget: axiom footprint + cohorts")
  , ("echo",         "reverse-direction fingerprint: who ANSWERS the same callers")
  , ("gravity",      "PageRank / PPR / HITS centrality + blast radius")
  , ("pyre",         "graph-only typecheck-cost prediction (elaborator hotspots)")
  , ("chokepoint",   "node-capacitated min-cut + articulation points from theorems to axioms")
  , ("silhouette",   "signature-vs-body topology twins (signature-tagged edges)")
  , ("entwine",      "pairwise mutual information over caller baskets")
  , ("fiedler",      "spectral bisection: bridge edges + low-lambda2 modules (SciPy)")
  , ("horizon",      "eccentricity / proof geometry: diameter, radius, periphery, center")
  , ("strata",       "declared-hierarchy module cohesion: LCOM' / instability / abstractness")
  , ("term-cluster", "AST-level subterm fingerprint clusters (needs --with-term-hashes)")
  , ("concept-bundle", "frequent itemsets over signature-provenance edges")
  ]

usage :: String
usage = unlines $
  [ "agda-optimization — graph-level analyses for an agda-deps expanded JSON."
  , ""
  , "USAGE:"
  , "  agda-optimization <subcommand> <graph.json> [options...]"
  , ""
  , "SUBCOMMANDS:"
  ]
  ++ [ "  " ++ pad 16 name ++ desc | (name, desc) <- subcommands ]
  ++
  [ ""
  , "GLOBAL OPTIONS:"
  , "  --json              emit a JSON report instead of human-readable text."
  , "  --out FILE          write the report to FILE (default: stdout)."
  , "  --config FILE       load defaults from a YAML config file."
  , "  -h, --help          print this help and exit."
  , "  -V, --version       print the agda-optimization version and exit."
  , "  --numeric-version   print just the version number and exit."
  , ""
  , "YAML CONFIG:"
  , "  Defaults can also be loaded from a YAML file (CLI flags override)."
  , "  Discovery order: --config=PATH, $AGDA_OPTIMIZATION_CONFIG,"
  , "  ./.agda-optimization.yml (or .yaml), then walking up to the"
  , "  nearest *.agda-lib directory. Top-level keys: 'global:' plus one"
  , "  per subcommand (e.g. 'load-bearing:'). Field names are the CLI"
  , "  flag names without the '--' prefix."
  , ""
  , "Run 'agda-optimization <subcommand> --help' for subcommand-specific options."
  ]
  where
    pad n s = s ++ replicate (max 0 (n - length s)) ' '

subUsage :: String -> String
subUsage sub = unlines $
  [ "agda-optimization " ++ sub ++ " — " ++ desc
  , ""
  , "USAGE:"
  , "  agda-optimization " ++ sub ++ " <graph.json> [options...]"
  , ""
  , "OPTIONS:"
  ] ++ map ("  " ++) (subFlags sub) ++
  [ ""
  , "Plus the global flags --json, --out FILE, and --config FILE"
  , "(parsed before subcommand flags). YAML defaults under the"
  , "'" ++ sub ++ ":' section override defaults; CLI flags override config."
  , "See README.md for per-flag semantics."
  ]
  where
    desc = case lookup sub subcommands of
      Just d  -> d
      Nothing -> "(unknown subcommand)"

-- | Per-subcommand flag listing, DERIVED from each analysis's exported
-- @flagSpecs@ (the same list that drives its @parseOptions@ /
-- @applyConfig@) via 'renderFlagHelp'. When you add a flag to a
-- subcommand its help line appears here automatically — no separate
-- table to keep in lock-step. See README.md for the authoritative
-- semantic description of each flag.
--
-- Three subcommands ('motif', 'term-cluster', 'concept-bundle') declare
-- their specs in an order that differs from the historical help listing,
-- and 'term-cluster' carries one continuation line that is not itself a
-- flag; 'selectHelp' reorders / interleaves the spec-derived lines for
-- those three so the rendered help stays byte-identical. Their @--help@
-- text still comes from the specs, not a re-typed copy.
subFlags :: String -> [String]
subFlags sub = case sub of
  "motif"        -> selectHelp Motif.flagSpecs
    [ Right "min-support", Right "min-size", Right "max-size"
    , Right "per-module", Right "top-n", Right "exclude-hub-pct"
    , Right "max-fan-out", Right "budget", Right "min-label-distinct" ]
  "load-bearing" -> renderFlagHelp LoadBearing.flagSpecs
  "polyglot"     -> renderFlagHelp Polyglot.flagSpecs
  "fingerprint"  -> renderFlagHelp Fingerprint.flagSpecs
  "debt"         -> renderFlagHelp Debt.flagSpecs
  "basket"       -> renderFlagHelp Basket.flagSpecs
  "ledger"       -> renderFlagHelp Ledger.flagSpecs
  "echo"         -> renderFlagHelp Echo.flagSpecs
  "gravity"      -> renderFlagHelp Gravity.flagSpecs
  "pyre"         -> renderFlagHelp Pyre.flagSpecs
  "chokepoint"   -> renderFlagHelp Chokepoint.flagSpecs
  "silhouette"   -> renderFlagHelp Silhouette.flagSpecs
  "entwine"      -> renderFlagHelp Entwine.flagSpecs
  "fiedler"      -> renderFlagHelp Fiedler.flagSpecs
  "horizon"      -> renderFlagHelp Horizon.flagSpecs
  "strata"       -> renderFlagHelp Strata.flagSpecs
  "term-cluster" -> selectHelp TermCluster.flagSpecs
    [ Right "min-cluster", Right "span-modules", Right "min-diversity"
    , Right "min-mean-depth", Right "sort"
    , Left "                                log-score replaces size with log(size) to dampen size dominance)"
    , Right "exclude-module-regex", Right "top-n", Right "max-defs" ]
  "concept-bundle" -> selectHelp ConceptBundle.flagSpecs
    [ Right "min-support", Right "min-lift", Right "min-span"
    , Right "k-max", Right "top-n", Right "exclude-top-frequency"
    , Right "no-forced-suppress", Right "forced-suppress"
    , Right "forced-fraction" ]
  _ -> ["(no flags listed for this subcommand)"]

-- | Build a flag-help block from a spec list by selecting and
-- (re)ordering the spec-derived help lines by flag name (@Right@),
-- interleaving any verbatim non-flag lines such as a continuation
-- (@Left@). Used only by the three subcommands whose spec order or
-- extra lines differ from the historical 'subFlags' listing, so their
-- rendered help reproduces it byte-for-byte while each flag's text
-- still comes from its 'FlagSpec'. A @Right@ naming an absent flag
-- degrades to the bare name (it never fires for our call sites).
selectHelp :: [FlagSpec o] -> [Either String String] -> [String]
selectHelp specs = map sel
  where
    sel (Left lit)   = lit
    sel (Right name) = maybe name flagHelp (find ((== name) . flagName) specs)

-- | Entry point — called from @MainOptimization.main@.
--
-- Dispatch order:
--
--   1. @--help@ / @-h@ → print usage, exit 0.
--   2. @--version@ / @-V@ / @--numeric-version@ → print version, exit 0.
--      These are intercepted before the subcommand check so e.g.
--      @agda-optimization --version@ doesn't error as "unknown
--      subcommand: --version".
--   3. Subcommand dispatch.
run :: IO ()
run = do
  argv <- getArgs
  case argv of
    []                          -> do
      hPutStrLn stderr "agda-optimization: missing subcommand."
      hPutStrLn stderr usage
      exitFailure
    ("-h":_)                    -> putStrLn usage >> exitSuccess
    ("--help":_)                -> putStrLn usage >> exitSuccess
    ("-V":_)                    -> printVersion False >> exitSuccess
    ("--version":_)             -> printVersion False >> exitSuccess
    ("--numeric-version":_)     -> printVersion True  >> exitSuccess
    _ -> case scanGlobals argv of
      -- A malformed global (bare @--out@/@--config@) before the
      -- subcommand reports without a subcommand prefix; after the path
      -- it carries the subcommand, mirroring the two former error sites
      -- ('peelLeadingGlobals' vs 'splitGlobal').
      Left e -> do
        hPutStrLn stderr (renderScanError e)
        exitFailure
      Right Scan{ scanSub = Nothing } -> do
        hPutStrLn stderr "agda-optimization: missing subcommand."
        hPutStrLn stderr usage
        exitFailure
      Right s@Scan{ scanSub = Just sub } -> dispatch sub s

-- | A malformed-global error from the scanner. 'seScope' is the
-- subcommand to mention in the message — @Nothing@ before the
-- subcommand is known (matching the old 'peelLeadingGlobals' site,
-- prefixed @agda-optimization:@), @Just sub@ once the trailing scan is
-- running (matching the old 'splitGlobal' site, prefixed
-- @agda-optimization \<sub\>:@).
data ScanError = ScanError
  { seScope :: !(Maybe String)
  , seMsg   :: !String
  }

-- | Render a 'ScanError' to its stderr line. A scoped error reads
-- @agda-optimization \<sub\>: …@ (the old 'splitGlobal' shape); an
-- unscoped one reads @agda-optimization: …@ (the old
-- 'peelLeadingGlobals' shape).
renderScanError :: ScanError -> String
renderScanError e = case seScope e of
  Just sub -> "agda-optimization " ++ sub ++ ": " ++ seMsg e
  Nothing  -> "agda-optimization: " ++ seMsg e

-- | Accumulator for the single-pass global-flag scanner. Each global
-- field records whether the corresponding flag was seen on the CLI
-- (@Nothing@ = not set, so the default applies); 'scanSub' is the first
-- non-global, non-flag token; everything else becomes residual args
-- handed to the subcommand's own @parseOptions@.
--
-- Tracking "was it set?" explicitly lets the final 'GlobalOpts' be
-- @scanned '<|>' defaults@ with no value-equality-against-default
-- heuristic (the bug the old two-fold 'mergeCliOver' worked around).
--
-- 'scanRawTail' is the un-peeled list of args after the subcommand —
-- exactly the old @dispatch@'s @args@. 'dispatch' makes the
-- unknown-subcommand / @--help@ / missing-path decisions against it (not
-- against the peeled 'scanResidual'), so trailing global peeling can
-- never swallow a @--help@ that the old code would have honoured first.
--
-- 'scanPending' holds a /deferred/ trailing-position malformed-global
-- error. The old 'splitGlobal' ran only after 'dispatch' had validated
-- the subcommand and honoured @--help@, so a bad trailing @--out@ must
-- not preempt those; 'dispatch' surfaces 'scanPending' last (see there).
data Scan = Scan
  { scanOutFormat :: !(Maybe OutFormat) -- ^ @Just OutJson@ once @--json@ seen.
  , scanOutPath   :: !(Maybe FilePath)  -- ^ last @--out@ / @--out=@ value.
  , scanConfig    :: !(Maybe FilePath)  -- ^ last @--config@ / @--config=@ value.
  , scanSub       :: !(Maybe String)    -- ^ the subcommand token, once found.
  , scanRawTail   :: ![String]          -- ^ raw args after the subcommand, un-peeled.
  , scanResidual  :: ![String]          -- ^ args for the subcommand parser (head = path).
  , scanPending   :: !(Maybe ScanError) -- ^ deferred trailing-global error.
  }

-- | Single pass over the full argv that extracts the global flags
-- (@--json@ / @--out FILE@ / @--out=FILE@ / @--config FILE@ /
-- @--config=FILE@) from any /peelable/ position, tolerating the
-- interleaved subcommand token, and returns the assembled 'Scan'.
--
-- Positional contract (preserved verbatim from the former two-fold
-- 'peelLeadingGlobals' + 'splitGlobal' pair):
--
--   * Before the subcommand, leading globals are peeled; the first
--     non-global token becomes the subcommand. A bare @--out@/@--config@
--     here is an immediate error (no subcommand scope).
--   * The token immediately after the subcommand is taken as-is (the
--     graph path) and is NOT peeled — so e.g. @motif --json g.json@
--     leaves @--json@ in residual position rather than honouring it,
--     exactly as before.
--   * After that first post-subcommand token, globals are peeled again
--     and the rest accumulates into the residual args. A bare
--     @--out@/@--config@ here is recorded as a /deferred/ error in
--     'scanPending' (scope = the subcommand) so that 'dispatch' can
--     still run subcommand-validation and @--help@ first.
--
-- A later @--config@ / @--out@ wins over an earlier one (right-biased),
-- across the subcommand boundary.
scanGlobals :: [String] -> Either ScanError Scan
scanGlobals = goLead Scan
  { scanOutFormat = Nothing
  , scanOutPath   = Nothing
  , scanConfig    = Nothing
  , scanSub       = Nothing
  , scanRawTail   = []
  , scanResidual  = []
  , scanPending   = Nothing
  }
  where
    -- Phase 1: before the subcommand — peel leading globals. A bare
    -- value-flag is an immediate, unscoped error (old 'peelLeadingGlobals').
    goLead !s []                  = Right s
    goLead !s ("--json":rest)     = goLead s { scanOutFormat = Just OutJson } rest
    goLead _  ("--out":[])        = Left (ScanError Nothing "--out: missing FILE argument")
    goLead !s ("--out":v:rest)    = goLead s { scanOutPath = Just v } rest
    goLead _  ("--config":[])     = Left (ScanError Nothing "--config: missing FILE argument")
    goLead !s ("--config":v:rest) = goLead s { scanConfig = Just v } rest
    goLead !s (a:rest)
      | take 6 a == "--out="      = goLead s { scanOutPath = Just (drop 6 a) } rest
      | take 9 a == "--config="   = goLead s { scanConfig = Just (drop 9 a) } rest
      -- First non-global token is the subcommand. We snapshot the raw
      -- tail here (for dispatch's guards) and the token right after it
      -- (the path) is taken verbatim; trailing globals resume after.
      | otherwise                 = goPath s { scanSub = Just a, scanRawTail = rest } rest

    -- Phase 2: the single post-subcommand token (the path) is residual,
    -- never peeled — matching the old dispatch's @case args of (path:rest)@.
    goPath !s []           = Right s
    goPath !s (path:rest)  = goTail s { scanResidual = [path] } rest

    -- Phase 3: after the path — peel trailing globals (last wins). A bare
    -- value-flag stops the scan and records a deferred, subcommand-scoped
    -- error (old 'splitGlobal', whose Left short-circuited the fold).
    goTail !s []                  = done s
    goTail !s ("--json":rest)     = goTail s { scanOutFormat = Just OutJson } rest
    goTail !s ("--out":[])        = done s { scanPending = pend s "--out: missing FILE argument" }
    goTail !s ("--out":v:rest)    = goTail s { scanOutPath = Just v } rest
    goTail !s ("--config":[])     = done s { scanPending = pend s "--config: missing FILE argument" }
    goTail !s ("--config":v:rest) = goTail s { scanConfig = Just v } rest
    goTail !s (a:rest)
      | take 6 a == "--out="      = goTail s { scanOutPath = Just (drop 6 a) } rest
      | take 9 a == "--config="   = goTail s { scanConfig = Just (drop 9 a) } rest
      | otherwise                 = goTail s { scanResidual = a : scanResidual s } rest

    -- Finalise: residuals were accumulated reversed.
    done !s = Right s { scanResidual = reverse (scanResidual s) }
    pend !s = Just . ScanError (scanSub s)

-- | Print the version. With @numericOnly = True@, just the bare
-- semver (@X.Y.Z@); otherwise @agda-optimization X.Y.Z@. Format and
-- source mirror 'AgdaDeps.Help.printVersion' so both binaries always
-- agree on a release.
printVersion :: Bool -> IO ()
printVersion numericOnly
  | numericOnly = putStrLn ver
  | otherwise   = putStrLn $ "agda-optimization " ++ ver
  where
    ver = showVersion Paths.version

-- | Dispatch a resolved 'Scan' to the chosen subcommand. The guards
-- below mirror the former 'dispatch' precedence exactly, deciding
-- unknown-subcommand / @--help@ / missing-path against the /raw/
-- post-subcommand tail ('scanRawTail') — so a trailing global the
-- single-pass scanner already peeled cannot reorder these. Only once
-- those pass do we surface any deferred trailing-global error and run
-- the analysis with the scanned 'GlobalOpts' / config path / residual.
dispatch :: String -> Scan -> IO ()
dispatch sub s
  | sub `elem` ["-h", "--help"] = putStrLn usage >> exitSuccess
  | not (sub `elem` map fst subcommands) = do
      hPutStrLn stderr ("agda-optimization: unknown subcommand: " ++ sub)
      hPutStrLn stderr usage
      exitFailure
  | "--help" `elem` rawTail || "-h" `elem` rawTail = do
      putStrLn (subUsage sub)
      exitSuccess
  | null rawTail = do
      hPutStrLn stderr ("agda-optimization " ++ sub ++ ": missing <graph.json>.")
      hPutStrLn stderr (subUsage sub)
      exitFailure
  | otherwise = do
      -- Surface a deferred trailing malformed-global error now — after
      -- the subcommand-validation + @--help@ + missing-path guards, just
      -- as the former 'splitGlobal' only ran at this point.
      case scanPending s of
        Just e  -> hPutStrLn stderr (renderScanError e) >> exitFailure
        Nothing -> return ()
      -- 'scanResidual' is non-empty here: 'null rawTail' was ruled out
      -- above, and a non-empty raw tail always yields a path head.
      let (path, subArgs) = case scanResidual s of
                              (p:r) -> (p, r)
                              []    -> error "dispatch: empty residual"
      -- Discover + load the YAML config according to the documented
      -- priority order, then merge: global section before CLI's
      -- global flags (so CLI wins).
      mCfgPath <- discoverConfigPath (scanConfig s)
      eCfg <- loadConfig mCfgPath
      cfg <- case eCfg of
        Left err -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        Right c -> pure c
      -- Merge order for the global block:
      --   1. start from defaults
      --   2. overlay YAML's global: section
      --   3. overlay CLI flags via 'overlayCli' (only the fields the
      --      scanner actually saw — tracked as 'Maybe', no sentinel
      --      value-equality guesswork)
      gOpts <- case applyGlobal (cfg >>= globalSection) defaultGlobal of
        Left err -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        Right g -> pure (overlayCli s g)
      -- Stderr breadcrumb. Suppressed under --json so JSON-consuming
      -- pipelines stay quiet. Mirrors agda-deps / agda-unused.
      case (mCfgPath, gOutFormat gOpts) of
        (Just p, OutHuman) ->
          hPutStrLn stderr $ "agda-optimization: applied config from " ++ p
        _ -> return ()
      runSubcommand sub path cfg gOpts subArgs
  where
    rawTail = scanRawTail s

-- | Overlay the CLI's global choices (as captured in the 'Scan') onto a
-- config-derived base 'GlobalOpts'. Each field is set iff the scanner
-- recorded the corresponding flag; otherwise the base value survives.
-- No value-equality-against-default heuristic (the @Maybe@ tracking is
-- the explicit "was it set?" the old 'mergeCliOver' had to infer).
overlayCli :: Scan -> GlobalOpts -> GlobalOpts
overlayCli !s !base = GlobalOpts
  { gOutFormat = fromMaybe (gOutFormat base) (scanOutFormat s)
  , gOutPath   = scanOutPath s <|> gOutPath base
  }

-- | Load the expanded graph and build the index. Emits a single
-- 'syntheticCount > 0' notice to stderr so users notice when many
-- QNames reference external libraries they didn't import.
loadIndex :: FilePath -> IO Index
loadIndex path = do
  e <- loadExpandedGraph path
  case e of
    Left err -> do
      hPutStrLn stderr ("agda-optimization: failed to read " ++ path ++ ": " ++ err)
      exitFailure
    Right g  -> do
      let !ix = buildIndex g
          synth = idxSyntheticCount ix
      when (synth > 0) $
        hPutStrLn stderr $
          "agda-optimization: note: " ++ show synth ++ " synthetic node(s) "
          ++ "(edge-only QNames not in 'definitions'); "
          ++ "real=" ++ show (idxRealCount ix)
          ++ ", total=" ++ show (idxNodeCount ix) ++ "."
      pure ix

-- | Dispatch to the per-analysis 'run', after letting each analysis
-- parse its own slice of the argv. We parse the subcommand's flags
-- /before/ loading the graph so a typo doesn't produce a confusing
-- "file not found" first.
--
-- 'Maybe Config' carries the loaded YAML config (if any). For each
-- subcommand we build the seed 'Options' by:
--
--   1. starting from the analysis's 'defaultOptions';
--   2. applying its YAML section through 'applyConfig' if present;
--   3. letting CLI argv override on top via 'parseOptions seed argv'.
--
-- The 'GlobalOpts' record is threaded into each analysis — the
-- analysis branches on 'gOutFormat' internally to choose human-text
-- vs. JSON output, and on 'gOutPath' to choose stdout vs. file.
runSubcommand :: String -> FilePath -> Maybe Config -> GlobalOpts -> [String] -> IO ()
runSubcommand sub path mCfg g subArgs = case sub of
  "motif"        -> withOpts Motif.defaultOptions
                             Motif.applyConfig
                             Motif.parseOptions       Motif.run
  "load-bearing" -> withOpts LoadBearing.defaultOptions
                             LoadBearing.applyConfig
                             LoadBearing.parseOptions LoadBearing.run
  "polyglot"     -> withOpts Polyglot.defaultOptions
                             Polyglot.applyConfig
                             Polyglot.parseOptions    Polyglot.run
  "fingerprint"  -> withOpts Fingerprint.defaultOptions
                             Fingerprint.applyConfig
                             Fingerprint.parseOptions Fingerprint.run
  "debt"         -> withOpts Debt.defaultOptions
                             Debt.applyConfig
                             Debt.parseOptions        Debt.run
  "basket"       -> withOpts Basket.defaultOptions
                             Basket.applyConfig
                             Basket.parseOptions      Basket.run
  "ledger"       -> withOpts Ledger.defaultOptions
                             Ledger.applyConfig
                             Ledger.parseOptions      Ledger.run
  "echo"         -> withOpts Echo.defaultOptions
                             Echo.applyConfig
                             Echo.parseOptions        Echo.run
  "gravity"      -> withOpts Gravity.defaultOptions
                             Gravity.applyConfig
                             Gravity.parseOptions     Gravity.run
  "pyre"         -> withOpts Pyre.defaultOptions
                             Pyre.applyConfig
                             Pyre.parseOptions        Pyre.run
  "chokepoint"   -> withOpts Chokepoint.defaultOptions
                             Chokepoint.applyConfig
                             Chokepoint.parseOptions  Chokepoint.run
  "silhouette"   -> withOpts Silhouette.defaultOptions
                             Silhouette.applyConfig
                             Silhouette.parseOptions  Silhouette.run
  "entwine"      -> withOpts Entwine.defaultOptions
                             Entwine.applyConfig
                             Entwine.parseOptions     Entwine.run
  "fiedler"      -> withOpts Fiedler.defaultOptions
                             Fiedler.applyConfig
                             Fiedler.parseOptions     Fiedler.run
  "horizon"      -> withOpts Horizon.defaultOptions
                             Horizon.applyConfig
                             Horizon.parseOptions     Horizon.run
  "strata"       -> withOpts Strata.defaultOptions
                             Strata.applyConfig
                             Strata.parseOptions      Strata.run
  "term-cluster" -> withOpts TermCluster.defaultOptions
                             TermCluster.applyConfig
                             TermCluster.parseOptions TermCluster.run
  "concept-bundle" -> withOpts ConceptBundle.defaultOptions
                               ConceptBundle.applyConfig
                               ConceptBundle.parseOptions ConceptBundle.run
  _              -> hPutStrLn stderr ("agda-optimization: unreachable subcommand: " ++ sub)
                 >> exitFailure
  where
    -- Build the seed Options for this subcommand by applying the YAML
    -- section (if any), then hand the seed + argv to parseOptions.
    withOpts :: o
             -> (A.Object -> o -> Either String o)
             -> (o -> [String] -> Either String o)
             -> (Index -> GlobalOpts -> o -> IO ())
             -> IO ()
    withOpts defaults apply parser kont = do
      let !mSection = mCfg >>= flip subSectionFor sub
      seeded <- case mSection of
        Nothing  -> pure defaults
        Just obj -> case apply obj defaults of
          Right o' -> pure o'
          Left err -> do
            hPutStrLn stderr ("agda-optimization " ++ sub ++ ": config: " ++ err)
            exitFailure
      case parser seeded subArgs of
        Left err -> hPutStrLn stderr ("agda-optimization " ++ err) >> exitFailure
        Right o  -> do
          ix <- loadIndex path
          kont ix g o
