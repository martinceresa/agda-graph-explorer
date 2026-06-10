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

import           Control.Monad           ( when )
import qualified Data.Aeson              as A
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

-- | Per-subcommand flag listing, kept in lock-step with each
-- analysis's @parseOptions@. When you add a flag to a subcommand,
-- mirror it here so @agda-optimization <sub> --help@ shows it.
-- See README.md for the authoritative semantic description of
-- each flag.
subFlags :: String -> [String]
subFlags sub = case sub of
  "motif" ->
    [ "--min-support=N         minimum embedding count (default 3)"
    , "--min-size=N            minimum motif size in nodes (default 2)"
    , "--max-size=N            maximum motif size in nodes (default 3)"
    , "--per-module            mine per-module (currently warns + falls back to global)"
    , "--top-n=N               rows to keep (default 50)"
    , "--exclude-hub-pct=F     drop top-pct% hub nodes by fan-in"
    , "--max-fan-out=N         skip seeds whose fan-out exceeds N"
    , "--budget=F              wall-clock seconds; 0 = unlimited (default)"
    , "--min-label-distinct=N  require >= N distinct (kind, state) labels (default 2)"
    ]
  "load-bearing" ->
    [ "--results=tagged|exported|terminals  result-set selector (default exported)"
    , "--weight=unit|loc                    span weighting (default unit)"
    , "--top-n=N                            rows to keep (default 50)"
    , "--exclude-name-regex=PATTERN         POSIX-ERE on unqualified name (default ^[_─═]+$)"
    ]
  "polyglot" ->
    [ "--min-uses=N    minimum consumer count to consider (default 2)"
    , "--threshold=F   entropy threshold (default 1.5)"
    , "--top-n=N       rows to keep (default 50)"
    ]
  "fingerprint" ->
    [ "--jaccard=F                          weighted-Jaccard threshold (default 0.8)"
    , "--min-size=N                         min candidate subtree size (default 3)"
    , "--wl-k=N                             WL refinement depth (default 2)"
    , "--wl-depth=N                         per-candidate subtree hop bound; 0 = unbounded (default)"
    , "--direction=outgoing|incoming|both   which graph drives WL (default incoming)"
    , "--top-n=N                            clusters to keep (default 20)"
    ]
  "debt" ->
    [ "--top-n=N                       schedule rows (default 50)"
    , "--include-foundational          treat Agda.Builtin.* / Agda.Primitive postulates as debt"
    , "--no-include-postulates         exclude stub postulates from debt"
    , "--no-foundational-inventory     suppress trusted-base table on clean projects"
    ]
  "basket" ->
    [ "--min-support=F             min support (default 0.05)"
    , "--min-confidence=F          min confidence (default 0.5)"
    , "--min-lift=F                min lift (default 1.5)"
    , "--exclude-top-frequency=F   drop rules with top-pct% items; 0 = disabled (default 5.0)"
    , "--top-n=N                   rules to keep after sort (default 100)"
    , "--budget=F                  wall-clock seconds; 0 = unlimited (default)"
    , "--no-forced-suppress        disable the per-case-unfold-family suppressor"
    , "--forced-suppress           re-enable the suppressor (default on)"
    , "--forced-fraction=F         bundle-fraction gate for the suppressor (default 0.5)"
    ]
  "ledger" ->
    [ "--top-n=N                          theorem rows (default 50)"
    , "--min-axioms=N                     only show theorems with >= N axioms (default 0)"
    , "--cohort-min-size=N                only show cohorts with >= N members (default 2)"
    , "--no-foundational                  suppress foundational tail section"
    , "--axiom-source=postulate|record-field|both  what counts as an axiom (default postulate)"
    , "--axiom-module-prefix=PREFIX       repeatable; record-field-axiom module scope"
    , "--theorem-prefix=PREFIX            repeatable; theorem-set scope (else project-only via externals_summary)"
    ]
  "echo" ->
    [ "--wl-k=N                  WL refinement depth (default 2)"
    , "--jaccard=F               weighted-Jaccard threshold (default 0.8)"
    , "--min-size=N              min candidate subtree size (default 3)"
    , "--wl-depth=N              per-candidate subtree hop bound; 0 = unbounded (default)"
    , "--delta-only              show only reverse clusters with forward-spread > 1"
    , "--max-cluster-spread=F    reject clusters with spread/size below this (default 0.3, 0 disables)"
    , "--top-n=N                 rows to keep (default 50)"
    ]
  "gravity" ->
    [ "--damping=F                          PageRank damping (default 0.85)"
    , "--iters=N                            max power-iteration steps (default 50)"
    , "--tolerance=F                        L1-delta convergence (default 1e-6)"
    , "--top-n=N                            rows to keep (default 50)"
    , "--results=public|tagged|terminals    theorem-set source (default public)"
    , "--top-theorems=N                     PPR over top-N heaviest theorems (default 64)"
    ]
  "pyre" ->
    [ "--top-n=N                      rows to keep (default 50)"
    , "--w1=F                         |reach+| coefficient (default 1.0)"
    , "--w2=F                         Σ fanIn·fanOut coefficient (default 0.5)"
    , "--w3=F                         Σ wKind coefficient (default 2.0)"
    , "--w4=F                         depthRank coefficient (default 10.0)"
    , "--exclude-name-regex=PATTERN   POSIX-ERE on unqualified name"
    , "--profile=PATH                 JSON profile {qname: cost}; emit calibration report"
    , "--calibrate                    apply ridge-fitted weights to the ranking (needs --profile)"
    , "--ridge-lambda=F               L2 regularisation for the fit (default 1.0)"
    , "--levers                       emit the lever table (aggregate downstream cost)"
    ]
  "chokepoint" ->
    [ "--top-n=N                                    rows to keep (default 50)"
    , "--sources=exported|public|terminals          source-set selector (default exported)"
    , "--sinks=postulates-axioms|terminal-leaves    sink-set selector (default postulates-axioms)"
    , "--exclude-name-regex=PATTERN                 POSIX-ERE on unqualified name"
    ]
  "silhouette" ->
    [ "--wl-k=N              WL refinement depth (default 2)"
    , "--min-size=N          min candidate subtree size (default 3)"
    , "--min-cluster-size=N  min twin-cluster size (default 2)"
    , "--high-overlap=F      combinator-candidate threshold (default 0.5)"
    , "--low-overlap=F       copy-paste-reproof threshold (default 0.2)"
    , "--top-n=N             clusters to keep (default 50)"
    ]
  "entwine" ->
    [ "--min-co-callers=N             pair must co-occur in >= N callers (default 3)"
    , "--min-iqr=F                    min IQR (default 0.5)"
    , "--min-g-stat=F                 min G-statistic; 6.635 ≈ p<0.01 (default)"
    , "--top-n=N                      rows to keep (default 100)"
    , "--transitive                   use ancestors as basket instead of direct callers"
    , "--exclude-name-regex=PATTERN   POSIX-ERE on unqualified name"
    ]
  "fiedler" ->
    [ "--top-n=N      rows to keep per section (default 50)"
    , "--eig-k=N      number of eigenpairs above lambda_1 (default 5)"
    , "--helper=PATH  path to fiedler_helper.py (default scripts/fiedler_helper.py)"
    , "--python=PATH  python interpreter (default python3); needs scipy + numpy"
    ]
  "horizon" ->
    [ "--leaves=postulates-axioms|terminal-leaves    forward-leaf set (default postulates-axioms)"
    , "--roots=public-theorems|terminals             backward-root set (default public-theorems)"
    , "--no-module-hist                              suppress per-module epsilon+ histogram"
    , "--top-n=N                                     rows to keep (default 50)"
    , "--exclude-name-regex=PATTERN                  POSIX-ERE on unqualified name"
    ]
  "strata" ->
    [ "--top-n=N                        rows to keep (default 50)"
    , "--min-size=N                     skip modules with fewer than N defs (default 3)"
    , "--exclude-module-regex=PATTERN   POSIX-ERE on the full module name"
    ]
  "term-cluster" ->
    [ "--min-cluster=N                 minimum occurrences for a cluster to be reported (default 2)"
    , "--span-modules=N                minimum distinct modules a cluster's defs must span (default 1)"
    , "--min-diversity=F               minimum module-distribution Shannon entropy (default 0.0; try 0.7)"
    , "--min-mean-depth=N              minimum mean AST subterm depth for a cluster (default 0)"
    , "--sort=score|log-score|size     ranking criterion (default score = size*meanDepth*(1+diversity);"
    , "                                log-score replaces size with log(size) to dampen size dominance)"
    , "--exclude-module-regex=PATTERN  POSIX-ERE on declared module; drop matching defs before counting"
    , "--top-n=N                       rows to keep (default 50)"
    , "--max-defs=N                    top-defs shown per cluster row (default 3)"
    ]
  "concept-bundle" ->
    [ "--min-support=N                 absolute support count (default 3)"
    , "--min-lift=F                    lift threshold (default 2.0)"
    , "--min-span=N                    min distinct modules a bundle must span (default 3)"
    , "--k-max=N                       max itemset size; 2-4 (default 4)"
    , "--top-n=N                       rows to keep (default 50)"
    , "--exclude-top-frequency=F       drop bundles with top-pct% items; 0 = disabled (default 5.0)"
    , "--no-forced-suppress            disable the per-case-unfold-family suppressor"
    , "--forced-suppress               re-enable the suppressor (default on)"
    , "--forced-fraction=F             bundle-fraction gate for the suppressor (default 0.5)"
    ]
  _ -> ["(no flags listed for this subcommand)"]

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
    _ -> case peelLeadingGlobals argv of
      Left err -> do
        hPutStrLn stderr ("agda-optimization: " ++ err)
        exitFailure
      Right (_, _, []) -> do
        hPutStrLn stderr "agda-optimization: missing subcommand."
        hPutStrLn stderr usage
        exitFailure
      Right (preG, preCfg, sub:rest) -> dispatch preG preCfg sub rest

-- | Greedily peel @--json@ / @--out FILE@ / @--config FILE@ off the
-- front of the argv, stopping at the first non-recognised token (which
-- is then taken as the subcommand). Globals AFTER the subcommand still
-- get a second chance via 'splitGlobal' in 'dispatch'.
peelLeadingGlobals :: [String]
                   -> Either String (GlobalOpts, Maybe FilePath, [String])
peelLeadingGlobals = go defaultGlobal Nothing
  where
    go !g !mc []                  = Right (g, mc, [])
    go !g !mc ("--json":rest)     = go g { gOutFormat = OutJson } mc rest
    go _  _   ("--out":[])        = Left "--out: missing FILE argument"
    go !g !mc ("--out":v:rest)    = go g { gOutPath = Just v } mc rest
    go _  _   ("--config":[])     = Left "--config: missing FILE argument"
    go !g !_  ("--config":v:rest) = go g (Just v) rest
    go !g !mc (a:rest)
      | take 6 a == "--out="      = go g { gOutPath = Just (drop 6 a) } mc rest
      | take 9 a == "--config="   = go g (Just (drop 9 a)) rest
      | otherwise                 = Right (g, mc, a:rest)

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

dispatch :: GlobalOpts -> Maybe FilePath -> String -> [String] -> IO ()
dispatch preG preCfg sub args
  | sub `elem` ["-h", "--help"] = putStrLn usage >> exitSuccess
  | not (sub `elem` map fst subcommands) = do
      hPutStrLn stderr ("agda-optimization: unknown subcommand: " ++ sub)
      hPutStrLn stderr usage
      exitFailure
  | "--help" `elem` args || "-h" `elem` args = do
      putStrLn (subUsage sub)
      exitSuccess
  | otherwise = case args of
      []          -> do
        hPutStrLn stderr ("agda-optimization " ++ sub ++ ": missing <graph.json>.")
        hPutStrLn stderr (subUsage sub)
        exitFailure
      (path:rest) -> do
        -- Parse flags BEFORE touching the filesystem so bad flags fail
        -- with a clean per-subcommand error instead of a confusing
        -- file-not-found. Trailing-position globals get merged on top
        -- of the leading-position ones (last write wins).
        (gOptsCli, mCliCfg, subArgs) <-
          case splitGlobal preG preCfg [] rest of
            Left err -> do
              hPutStrLn stderr ("agda-optimization " ++ sub ++ ": " ++ err)
              exitFailure
            Right r -> pure r
        -- Discover + load the YAML config according to the documented
        -- priority order, then merge: global section before CLI's
        -- global flags (so CLI wins).
        mCfgPath <- discoverConfigPath mCliCfg
        eCfg <- loadConfig mCfgPath
        cfg <- case eCfg of
          Left err -> do
            hPutStrLn stderr ("agda-optimization: " ++ err)
            exitFailure
          Right c -> pure c
        -- Merge order for the global block:
        --   1. start from defaults
        --   2. overlay YAML's global: section
        --   3. overlay CLI flags (only the ones the user actually
        --      passed — defaultGlobal's fields are sentinel)
        gOpts <- case applyGlobal (cfg >>= globalSection) defaultGlobal of
          Left err -> do
            hPutStrLn stderr ("agda-optimization: " ++ err)
            exitFailure
          Right g -> pure (mergeCliOver g gOptsCli)
        -- Stderr breadcrumb. Suppressed under --json so JSON-consuming
        -- pipelines stay quiet. Mirrors agda-deps / agda-unused.
        case (mCfgPath, gOutFormat gOpts) of
          (Just p, OutHuman) ->
            hPutStrLn stderr $ "agda-optimization: applied config from " ++ p
          _ -> return ()
        runSubcommand sub path cfg gOpts subArgs

-- | Apply the CLI's @--json@ / @--out FILE@ choices over a config-
-- derived base 'GlobalOpts'. A CLI value is treated as "explicit" iff
-- it differs from 'defaultGlobalOpts' (both 'OutHuman' and 'Nothing'
-- are silent defaults — the user can't write @--json=false@ on the
-- command line, so the only way 'gOutFormat' is 'OutJson' is via
-- @--json@; similarly for @--out FILE@).
mergeCliOver :: GlobalOpts -> GlobalOpts -> GlobalOpts
mergeCliOver !base !cli = GlobalOpts
  { gOutFormat = if gOutFormat cli == gOutFormat defaultGlobal
                   then gOutFormat base
                   else gOutFormat cli
  , gOutPath   = case gOutPath cli of
                   Just _  -> gOutPath cli
                   Nothing -> gOutPath base
  }

-- | Peel the global flags off the argv, leaving everything else for
-- the subcommand parser. Strict fold; residual order preserved.
--
-- Recognised globals:
--   * @--json@                  — set 'gOutFormat' to 'OutJson'.
--   * @--out FILE@ / @--out=FILE@ — set 'gOutPath'.
--   * @--config FILE@ / @--config=FILE@ — explicit YAML config path
--     (returned separately so the discovery layer can honour the
--     priority order from 'AgdaOptimization.Config.discoverConfigPath').
--
-- A bare @--out@/@--config@ with no following value is a hard error
-- here so we can report the canonical "missing FILE argument" message
-- — letting it fall through to the subcommand parser would lose
-- context.
splitGlobal :: GlobalOpts -> Maybe FilePath -> [String] -> [String]
            -> Either String (GlobalOpts, Maybe FilePath, [String])
splitGlobal !g !mc !subAcc []                  = Right (g, mc, reverse subAcc)
splitGlobal !g !mc !subAcc ("--json":rest)     = splitGlobal g { gOutFormat = OutJson } mc subAcc rest
splitGlobal _  _   _      ("--out":[])         = Left "--out: missing FILE argument"
splitGlobal !g !mc !subAcc ("--out":v:rest)    = splitGlobal g { gOutPath = Just v } mc subAcc rest
splitGlobal _  _   _      ("--config":[])      = Left "--config: missing FILE argument"
splitGlobal !g !mc !subAcc ("--config":v:rest) = splitGlobal g (mc <|+|> Just v) subAcc rest
splitGlobal !g !mc !subAcc (a:rest)
  | take 6 a == "--out="                       = splitGlobal g { gOutPath = Just (drop 6 a) } mc subAcc rest
  | take 9 a == "--config="                    = splitGlobal g (mc <|+|> Just (drop 9 a)) subAcc rest
  | otherwise                                  = splitGlobal g mc (a : subAcc) rest

-- | Tiny right-biased combinator: a later @--config@ wins, matching
-- the convention for @--out@ / @--json@.
(<|+|>) :: Maybe a -> Maybe a -> Maybe a
_ <|+|> Just b  = Just b
a <|+|> Nothing = a
infixl 4 <|+|>

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
