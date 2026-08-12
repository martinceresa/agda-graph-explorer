{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
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
import           Data.List               ( find, stripPrefix )
import           Data.Maybe              ( fromMaybe, mapMaybe )
import           Data.Text               ( Text )
import qualified Data.Text               as T
import           System.Environment      ( getArgs )
import           System.Exit             ( exitFailure, exitSuccess )
import           System.IO               ( hPutStrLn, stderr )

import           AgdaGraph.Version       ( numericVersion, versionLine )
import           AgdaGraph.ConfigCore    ( extractValueFlag )
import           AgdaGraph.Completion    ( CompletionSpec(..), renderCompletion )
import           AgdaGraph.Schema        ( loadExpandedGraph )
import           AgdaGraph.Index         ( Index, buildIndex, idxSyntheticCount
                                         , idxNodeCount, idxRealCount )

import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , defaultGlobalOpts )
import           AgdaOptimization.Config ( Config(..), discoverConfigPath
                                         , loadConfig, subSectionFor
                                         , globalSection, applyGlobal
                                         , globalGraph, globalConfigKeys
                                         , checkConfigKeys )
import           AgdaOptimization.FlagSpec ( FlagSpec, flagName, flagHelp
                                           , flagConfigKey, renderFlagHelp )
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
import qualified AgdaOptimization.TermCluster  as TermCluster
import qualified AgdaOptimization.ConceptBundle as ConceptBundle
import qualified AgdaOptimization.HintBench     as HintBench

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
  , ("hint-bench",   "leave-one-out premise-selection recall of the lemma ranker")
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
  , "  --graph FILE        input graph (alias of the positional <graph.json>;"
  , "                      usable in any position, and wins over a positional."
  , "                      Config fallback: `graph:` under `global:`)."
  , "  --format human|json output format (default: human)."
  , "  --json              alias of --format=json."
  , "  --out FILE          write the report to FILE (default: stdout)."
  , "  --explain           append a 'How to read this' legend explaining the"
  , "                      report's tables and columns (human format, default on)."
  , "  --no-explain        suppress that legend."
  , "  --config FILE       load defaults from a YAML config file."
  , "  -h, --help          print this help and exit."
  , "  -V, --version       print the agda-optimization version and exit."
  , "  --numeric-version   print just the version number and exit."
  , "  --show-defaults     print a starter .agda-optimization.yml skeleton (global +"
  , "                      one section per subcommand) to stdout and exit."
  , ""
  , "YAML CONFIG:"
  , "  Defaults can also be loaded from a YAML file (CLI flags override)."
  , "  The 'global:' section also names the INPUT graph ('graph: FILE'), so"
  , "  a configured project needs no path on the command line."
  , "  Discovery order: --config=PATH, $AGDA_OPTIMIZATION_CONFIG,"
  , "  ./.agda-optimization.yml (or .yaml), then walking up to the"
  , "  nearest *.agda-lib directory. Top-level keys: 'global:' plus one"
  , "  per subcommand (e.g. 'load-bearing:'). Field names are the CLI"
  , "  flag names without the '--' prefix."
  , ""
  , "Run 'agda-optimization <subcommand> --help' for subcommand-specific options."
  , ""
  , "EXIT CODES:"
  , "  0  success."
  , "  1  error: bad flags/subcommand, unreadable or mismatched graph, config failure."
  , "  2  fiedler: helper script (scripts/fiedler_helper.py) not found."
  , "  3  fiedler: SciPy/NumPy not importable in the helper's Python."
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
  , "Plus the global flags --graph FILE, --json, --out FILE, --no-explain"
  , "and --config FILE (parsed before subcommand flags). The graph may also"
  , "come from 'graph:' under 'global:' in the config, in which case <graph.json>"
  , "can be omitted. YAML defaults under the '" ++ sub ++ ":' section"
  , "override defaults; CLI flags override config."
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
-- their specs in an order that differs from how their @--help@ lists the
-- flags, and 'term-cluster' carries one continuation line that is not itself
-- a flag; 'selectHelp' reorders / interleaves the spec-derived lines for
-- those three so the rendered help keeps its intended layout. Their @--help@
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
  "hint-bench"   -> renderFlagHelp HintBench.flagSpecs
  _ -> ["(no flags listed for this subcommand)"]

-- | Build a flag-help block from a spec list by selecting and
-- (re)ordering the spec-derived help lines by flag name (@Right@),
-- interleaving any verbatim non-flag lines such as a continuation
-- (@Left@). Used only by the three subcommands whose spec order or
-- extra lines differ from the layout their @--help@ presents, so their
-- rendered help keeps that fixed layout while each flag's text
-- still comes from its 'FlagSpec'. A @Right@ naming an absent flag
-- degrades to the bare name (it never fires for our call sites).
selectHelp :: [FlagSpec o] -> [Either String String] -> [String]
selectHelp specs = map sel
  where
    sel (Left lit)   = lit
    sel (Right name) = maybe name flagHelp (find ((== name) . flagName) specs)

-- | The @--show-defaults@ payload: a documented @.agda-optimization.yml@
-- skeleton — a @global:@ section plus one section per subcommand, listing every
-- key that section accepts (read from the subcommand's 'flagSpecs' via
-- 'subConfigPairs', so the list can never drift from the parser — and, since
-- the unknown-key check reads the same source, uncommenting any line the
-- skeleton prints is guaranteed to load). Per-flag defaults are conveyed by each key's
-- description — the 'FlagSpec' interpreters expose a flag's name and help but no
-- value getter, so unlike the single-command tools we can't fill a live value.
-- Section headers are active (an empty/null mapping is a no-op) so a section is
-- inert until a child key is uncommented and given a value.
defaultsYaml :: String
defaultsYaml = unlines $
  [ "# .agda-optimization.yml — configuration skeleton (one section per subcommand)."
  , "# Generated by `agda-optimization --show-defaults`. Keys are the CLI flag names"
  , "# without the leading `--`; each flag's default is noted in its description."
  , "# A `--no-x` flag reads the positive key `x` (set it to false for the same"
  , "# effect). An unknown key is an error, so every key below is one that loads."
  , "# Merge order is defaults < config < CLI. Uncomment a key and give it a value"
  , "# to override; the section headers below stay harmless no-ops until you do."
  , ""
  , "global:"
  , "  # input graph (the positional <graph.json>; --graph FILE and a"
  , "  # positional both win over this key)"
  , "  # graph: deps.json"
  , "  # output format: human | json (default: human). `json: true` is a"
  , "  # legacy alias still accepted."
  , "  # format: json"
  , "  # write the report to FILE (default: stdout)"
  , "  # out: report.txt"
  , "  # append a 'How to read this' legend to a human report (default: true)"
  , "  # explain: false"
  ]
  ++ concatMap section subcommands
  where
    section (name, desc) =
      [ ""
      , "# " ++ name ++ " — " ++ desc
      , name ++ ":"
      ] ++ concatMap flagLines (subConfigPairs name)
    flagLines (key, help) =
      [ "  # " ++ help
      , "  # " ++ T.unpack key ++ ":"
      ]

-- | @(yaml-key, help-line)@ pairs for a subcommand's config section: the
-- 'subFlagPairs' entries that actually take part in the YAML overlay, keyed
-- by the key 'AgdaOptimization.FlagSpec.applyFlagConfig' looks up rather than
-- by the flag name.
--
-- The two differ for toggle pairs (@--no-include-postulates@ reads
-- @include-postulates:@) and for a secondary switch spelling, which reads
-- nothing at all. Both the @--show-defaults@ skeleton and the unknown-key
-- check read the section vocabulary from here, so the skeleton can only
-- advertise keys the loader accepts — and 'subFlagPairs' stays flag-named
-- for the completion script.
subConfigPairs :: String -> [(Text, String)]
subConfigPairs sub =
  withSpecs sub (mapMaybe (\s -> (,) <$> flagConfigKey s <*> pure (flagHelp s))) []

-- | The YAML keys a subcommand's section accepts.
subConfigKeys :: String -> [Text]
subConfigKeys = map fst . subConfigPairs

-- | Every recognised config section paired with its accepted keys — the
-- vocabulary 'checkConfigKeys' validates a loaded file against. Covers all
-- subcommands, not just the one being run, so a typo anywhere in the file is
-- reported on the next invocation.
configSections :: [(String, [Text])]
configSections =
  ("global", globalConfigKeys) : [ (name, subConfigKeys name) | (name, _) <- subcommands ]

-- | @(flag-name, help-line)@ pairs for a subcommand, read from its exported
-- 'flagSpecs' (the same list that drives parsing / config / help). Flag
-- names, so the completion script offers what the parser accepts; see
-- 'subConfigPairs' for the YAML-key view.
subFlagPairs :: String -> [(String, String)]
subFlagPairs sub = withSpecs sub (map (\s -> (flagName s, flagHelp s))) []

-- | Apply a spec-list consumer to a subcommand's exported @flagSpecs@,
-- falling back to @nothing@ for an unknown name.
--
-- The consumer is rank-2 because each subcommand's specs are indexed by its
-- own @Options@ type: this is the one place that maps names to spec lists,
-- so the flag-name, YAML-key and completion views all read the same table.
withSpecs :: String -> (forall o. [FlagSpec o] -> r) -> r -> r
withSpecs sub k nothing = case sub of
  "motif"          -> k Motif.flagSpecs
  "load-bearing"   -> k LoadBearing.flagSpecs
  "polyglot"       -> k Polyglot.flagSpecs
  "fingerprint"    -> k Fingerprint.flagSpecs
  "debt"           -> k Debt.flagSpecs
  "basket"         -> k Basket.flagSpecs
  "ledger"         -> k Ledger.flagSpecs
  "echo"           -> k Echo.flagSpecs
  "gravity"        -> k Gravity.flagSpecs
  "pyre"           -> k Pyre.flagSpecs
  "chokepoint"     -> k Chokepoint.flagSpecs
  "silhouette"     -> k Silhouette.flagSpecs
  "entwine"        -> k Entwine.flagSpecs
  "fiedler"        -> k Fiedler.flagSpecs
  "horizon"        -> k Horizon.flagSpecs
  "strata"         -> k Strata.flagSpecs
  "term-cluster"   -> k TermCluster.flagSpecs
  "concept-bundle" -> k ConceptBundle.flagSpecs
  "hint-bench"     -> k HintBench.flagSpecs
  _                -> nothing

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
-- | Completion data for @agda-optimization@, derived from the subcommand list
-- and each subcommand's 'flagSpecs' (via 'subFlagPairs'), so the completion
-- script can't drift from the parser. Global flags are the ones 'scanGlobals'
-- / the pre-pass recognise, plus the meta flags.
completionSpec :: CompletionSpec
completionSpec = CompletionSpec
  { csProg    = "agda-optimization"
  , csGlobals =
      [ "--graph", "--format", "--json", "--out", "--config"
      , "--explain", "--no-explain"
      , "--help", "--version", "--numeric-version", "--show-defaults" ]
  , csSubcommands =
      [ (name, map (("--" ++) . fst) (subFlagPairs name)) | (name, _) <- subcommands ]
  }

run :: IO ()
run = do
  argv0 <- getArgs
  -- `--show-defaults` prints a config skeleton and exits before subcommand /
  -- graph handling, so it works from anywhere (no graph.json needed).
  when ("--show-defaults" `elem` argv0) (putStr defaultsYaml >> exitSuccess)
  -- `--completion-script[=bash|zsh]` (hidden): print a shell completion script
  -- generated from the flag table, then exit. Bare form defaults to bash.
  case [ s | a <- argv0, Just s <- [stripPrefix "--completion-script" a]
           , s == "" || take 1 s == "=" ] of
    (s:_) -> do
      let shell = case s of ('=':sh) -> sh; _ -> "bash"
      putStr (renderCompletion shell completionSpec)
      exitSuccess
    [] -> pure ()
  -- Lift the position-independent globals out of argv before the intricate
  -- positional scanner runs: `--graph` (input, an alias of the positional
  -- graph path), `--format` (output, an alias of `--json`) and `--config`.
  --
  -- `--config` is lifted rather than scanned because the scanner reserves the
  -- one token after the subcommand for the graph path and never peels it
  -- (see 'scanGlobals'), so a scanned `--config` was unusable in that slot —
  -- and `--graph`'s own lifting SHIFTS a later flag into it, which made
  -- `motif --graph g.json --config f.yml` fail with `unknown flag: --config`
  -- even though the flag was written last. Lifting removes the slot from the
  -- question entirely: every spelling and position now behaves the same.
  let (mGraph,  argv1) = extractValueFlag "--graph" argv0
      (mFmtRaw, argv2) = extractValueFlag "--format" argv1
      (mCfgPathArg, argv) = extractValueFlag "--config" argv2
  -- 'extractValueFlag' drops a trailing bare `--config` (no FILE); keep the
  -- scanner's diagnostic for it rather than silently running config-less.
  when (mCfgPathArg == Nothing && "--config" `elem` argv0) $ do
    hPutStrLn stderr "agda-optimization: --config: missing FILE argument"
    exitFailure
  fmtOverride <- case mFmtRaw of
    Nothing      -> pure Nothing
    Just "json"  -> pure (Just OutJson)
    Just "human" -> pure (Just OutHuman)
    Just other   -> do
      hPutStrLn stderr ("agda-optimization: unknown --format value: " ++ other
                          ++ " (want human|json)")
      exitFailure
  case argv of
    []                          -> do
      hPutStrLn stderr "agda-optimization: missing subcommand."
      hPutStrLn stderr "Try 'agda-optimization --help' for the list of subcommands."
      exitFailure
    ("-h":_)                    -> putStrLn usage >> exitSuccess
    ("--help":_)                -> putStrLn usage >> exitSuccess
    ("-V":_)                    -> printVersion False >> exitSuccess
    ("--version":_)             -> printVersion False >> exitSuccess
    ("--numeric-version":_)     -> printVersion True  >> exitSuccess
    _ -> case scanGlobals argv of
      -- A malformed global (bare @--out@/@--config@) before the
      -- subcommand reports without a subcommand prefix; after the path
      -- it carries the subcommand.
      Left e -> do
        hPutStrLn stderr (renderScanError e)
        exitFailure
      Right Scan{ scanSub = Nothing } -> do
        hPutStrLn stderr "agda-optimization: missing subcommand."
        hPutStrLn stderr "Try 'agda-optimization --help' for the list of subcommands."
        exitFailure
      Right s0@Scan{ scanSub = Just sub } ->
        -- Fold in the lifted-out globals: `--graph` sets 'scanGraph' (wins
        -- over any positional in 'dispatch'); `--format` overrides `--json`;
        -- `--config` is the explicit path handed to 'discoverConfigPath'.
        dispatch sub s0 { scanGraph     = mGraph
                        , scanConfig    = mCfgPathArg
                        , scanOutFormat = fmtOverride <|> scanOutFormat s0 }

-- | A malformed-global error from the scanner. 'seScope' is the
-- subcommand to mention in the message — @Nothing@ before the
-- subcommand is known (prefixed @agda-optimization:@), @Just sub@ once
-- the trailing scan is running (prefixed @agda-optimization \<sub\>:@).
data ScanError = ScanError
  { seScope :: !(Maybe String)
  , seMsg   :: !String
  }

-- | Render a 'ScanError' to its stderr line. A scoped error reads
-- @agda-optimization \<sub\>: …@; an unscoped one reads
-- @agda-optimization: …@.
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
-- heuristic.
--
-- 'scanRawTail' is the un-peeled list of args after the subcommand.
-- 'dispatch' makes the unknown-subcommand / @--help@ / missing-path
-- decisions against it (not against the peeled 'scanResidual'), so
-- trailing global peeling can never swallow a @--help@.
--
-- 'scanPending' holds a /deferred/ trailing-position malformed-global
-- error: a bad trailing @--out@ must not preempt subcommand validation
-- or @--help@, so 'dispatch' surfaces 'scanPending' last (see there).
data Scan = Scan
  { scanOutFormat :: !(Maybe OutFormat) -- ^ @Just OutJson@ once @--json@ seen.
  , scanOutPath   :: !(Maybe FilePath)  -- ^ last @--out@ / @--out=@ value.
  , scanConfig    :: !(Maybe FilePath)  -- ^ @--config@ / @--config=@ value (lifted
                                        --   out of argv before the scanner runs,
                                        --   like 'scanGraph').
  , scanGraph     :: !(Maybe FilePath)  -- ^ @--graph@ / @--graph=@ value (lifted
                                        --   out of argv before the scanner runs;
                                        --   wins over any positional graph path).
  , scanSub       :: !(Maybe String)    -- ^ the subcommand token, once found.
  , scanRawTail   :: ![String]          -- ^ raw args after the subcommand, un-peeled.
  , scanResidual  :: ![String]          -- ^ args for the subcommand parser (head = path).
  , scanExplain   :: !(Maybe Bool)     -- ^ @--explain@ / @--no-explain@, last wins.
  , scanPending   :: !(Maybe ScanError) -- ^ deferred trailing-global error.
  }

-- | Single pass over the full argv that extracts the global flags
-- (@--json@ / @--out FILE@ / @--out=FILE@) from any /peelable/ position,
-- tolerating the interleaved subcommand token, and returns the assembled
-- 'Scan'.
--
-- @--graph@, @--format@ and @--config@ never reach here: 'run' lifts them
-- out of argv first ('extractValueFlag'), which is what makes them work in
-- every position including the un-peelable slot below.
--
-- Positional contract:
--
--   * Before the subcommand, leading globals are peeled; the first
--     non-global token becomes the subcommand. A bare @--out@ here is an
--     immediate error (no subcommand scope).
--   * The token immediately after the subcommand is taken as-is (the
--     graph path) and is NOT peeled — so e.g. @motif --json g.json@
--     leaves @--json@ in residual position rather than honouring it.
--   * After that first post-subcommand token, globals are peeled again
--     and the rest accumulates into the residual args. A bare @--out@
--     here is recorded as a /deferred/ error in 'scanPending' (scope =
--     the subcommand) so that 'dispatch' can still run
--     subcommand-validation and @--help@ first.
--
-- A later @--out@ wins over an earlier one (right-biased), across the
-- subcommand boundary.
scanGlobals :: [String] -> Either ScanError Scan
scanGlobals = goLead Scan
  { scanOutFormat = Nothing
  , scanOutPath   = Nothing
  , scanConfig    = Nothing
  , scanGraph     = Nothing
  , scanSub       = Nothing
  , scanRawTail   = []
  , scanResidual  = []
  , scanExplain   = Nothing
  , scanPending   = Nothing
  }
  where
    -- Phase 1: before the subcommand — peel leading globals. A bare
    -- value-flag is an immediate, unscoped error.
    goLead !s []                  = Right s
    goLead !s ("--json":rest)     = goLead s { scanOutFormat = Just OutJson } rest
    goLead !s ("--explain":rest)    = goLead s { scanExplain = Just True } rest
    goLead !s ("--no-explain":rest) = goLead s { scanExplain = Just False } rest
    goLead _  ("--out":[])        = Left (ScanError Nothing "--out: missing FILE argument")
    goLead !s ("--out":v:rest)    = goLead s { scanOutPath = Just v } rest
    goLead !s (a:rest)
      | take 6 a == "--out="      = goLead s { scanOutPath = Just (drop 6 a) } rest
      -- First non-global token is the subcommand. We snapshot the raw
      -- tail here (for dispatch's guards) and the token right after it
      -- (the path) is taken verbatim; trailing globals resume after.
      | otherwise                 = goPath s { scanSub = Just a, scanRawTail = rest } rest

    -- Phase 2: the single post-subcommand token (the path) is residual,
    -- never peeled.
    goPath !s []           = Right s
    goPath !s (path:rest)  = goTail s { scanResidual = [path] } rest

    -- Phase 3: after the path — peel trailing globals (last wins). A bare
    -- value-flag stops the scan and records a deferred, subcommand-scoped
    -- error.
    goTail !s []                  = done s
    goTail !s ("--json":rest)     = goTail s { scanOutFormat = Just OutJson } rest
    goTail !s ("--explain":rest)    = goTail s { scanExplain = Just True } rest
    goTail !s ("--no-explain":rest) = goTail s { scanExplain = Just False } rest
    goTail !s ("--out":[])        = done s { scanPending = pend s "--out: missing FILE argument" }
    goTail !s ("--out":v:rest)    = goTail s { scanOutPath = Just v } rest
    goTail !s (a:rest)
      | take 6 a == "--out="      = goTail s { scanOutPath = Just (drop 6 a) } rest
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
  | numericOnly = putStrLn numericVersion
  | otherwise   = putStrLn (versionLine "agda-optimization")

-- | Dispatch a resolved 'Scan' to the chosen subcommand. The guards
-- below decide unknown-subcommand / @--help@ / missing-path against the
-- /raw/ post-subcommand tail ('scanRawTail') — so a trailing global the
-- single-pass scanner already peeled cannot reorder these. Only once
-- those pass do we surface any deferred trailing-global error and run
-- the analysis with the scanned 'GlobalOpts' / config path / residual.
dispatch :: String -> Scan -> IO ()
dispatch sub s
  | sub `elem` ["-h", "--help"] = putStrLn usage >> exitSuccess
  | not (sub `elem` map fst subcommands) = do
      hPutStrLn stderr ("agda-optimization: unknown subcommand: " ++ sub)
      hPutStrLn stderr "Try 'agda-optimization --help' for the list of subcommands."
      exitFailure
  | "--help" `elem` rawTail || "-h" `elem` rawTail = do
      putStrLn (subUsage sub)
      exitSuccess
  | otherwise = do
      -- Surface a deferred trailing malformed-global error now — after
      -- the subcommand-validation + @--help@ guards.
      case scanPending s of
        Just e  -> hPutStrLn stderr (renderScanError e) >> exitFailure
        Nothing -> return ()
      -- Discover + load the YAML config according to the documented
      -- priority order, then merge: global section before CLI's
      -- global flags (so CLI wins). This runs BEFORE the input graph is
      -- resolved, because `global: graph:` is one of the three ways to name
      -- it — a missing positional is only an error once the config has had
      -- its say.
      mCfgPath <- discoverConfigPath (scanConfig s)
      eCfg <- loadConfig mCfgPath
      cfg <- case eCfg of
        Left err -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        Right c -> pure c
      -- Reject unknown sections / keys before any of them is read. A key no
      -- reader looks up is a typo or a stale name; either way the value has
      -- no effect, so failing here matches the argv parser's treatment of an
      -- unknown flag rather than leaving the user to wonder why the setting
      -- did nothing.
      case cfg of
        Just c | Left err <- checkConfigKeys c configSections -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        _ -> return ()
      let gSection = cfg >>= globalSection
      -- Merge order for the global block:
      --   1. start from defaults
      --   2. overlay YAML's global: section
      --   3. overlay CLI flags via 'overlayCli' (only the fields the
      --      scanner actually saw — tracked as 'Maybe', no sentinel
      --      value-equality guesswork)
      gOpts <- case applyGlobal gSection defaultGlobal of
        Left err -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        Right g -> pure (overlayCli s g)
      mCfgGraph <- case globalGraph gSection of
        Left err -> do
          hPutStrLn stderr ("agda-optimization: " ++ err)
          exitFailure
        Right g -> pure g
      -- Input-graph precedence: `--graph` > positional > config's
      -- `global: graph:`. 'takePositional' only claims the residual head as
      -- the path when it is not itself a flag, so a subcommand flag can never
      -- be mistaken for the graph (nor silently dropped from 'subArgs').
      let (mPositional, subArgs) = takePositional (scanResidual s)
      path <- case (scanGraph s, mPositional, mCfgGraph) of
        (Just g, Just _, _) -> do
          hPutStrLn stderr
            "agda-optimization: both --graph and a positional graph.json given; using --graph."
          pure g
        (Just g,  Nothing, _)      -> pure g
        (Nothing, Just p,  _)      -> pure p
        (Nothing, Nothing, Just g) -> pure g
        (Nothing, Nothing, Nothing) -> do
          hPutStrLn stderr ("agda-optimization " ++ sub
                              ++ ": missing <graph.json> (positional, --graph FILE,"
                              ++ " or `graph:` under `global:` in the config).")
          hPutStrLn stderr (subUsage sub)
          exitFailure
      -- Stderr breadcrumb. Suppressed under --json so JSON-consuming
      -- pipelines stay quiet. Mirrors agda-deps / agda-unused.
      case (mCfgPath, gOutFormat gOpts) of
        (Just p, OutHuman) ->
          hPutStrLn stderr $ "agda-optimization: applied config from " ++ p
        _ -> return ()
      runSubcommand sub path cfg gOpts subArgs
  where
    rawTail = scanRawTail s

-- | Split the residual into @(positional graph path, subcommand args)@. The
-- head is the path only when it does not look like a flag: with @--graph@ (or
-- a config @graph:@) supplying the path, the residual head is a subcommand
-- flag and must stay in the args.
takePositional :: [String] -> (Maybe FilePath, [String])
takePositional (p : rest) | take 1 p /= "-" = (Just p, rest)
takePositional args                         = (Nothing, args)

-- | Overlay the CLI's global choices (as captured in the 'Scan') onto a
-- config-derived base 'GlobalOpts'. Each field is set iff the scanner
-- recorded the corresponding flag; otherwise the base value survives.
-- No value-equality-against-default heuristic — the @Maybe@ tracking is
-- the explicit "was it set?".
overlayCli :: Scan -> GlobalOpts -> GlobalOpts
overlayCli !s !base = GlobalOpts
  { gOutFormat = fromMaybe (gOutFormat base) (scanOutFormat s)
  , gOutPath   = scanOutPath s <|> gOutPath base
  , gExplain   = fromMaybe (gExplain base) (scanExplain s)
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
  "hint-bench"   -> withOpts HintBench.defaultOptions
                             HintBench.applyConfig
                             HintBench.parseOptions   HintBench.run
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
