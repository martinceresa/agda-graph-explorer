{-# LANGUAGE OverloadedStrings #-}
-- | Pure command-line surface for @agda-auto@: the 'AutoOpts' record, the
-- argv parser, the @--key=value@ splitter, and the usage text. Kept free of
-- IO and of any executable-only module (it is compiled into the offline test
-- suite), so the flag table can be exercised without a build.
--
-- Merge order (assembled by "MainAuto"): defaults → @.agda-auto.yml@ → CLI.
-- 'parseArgs' threads a seed 'AutoOpts' so the config layer can supply the
-- base the CLI then overrides; see "AgdaAuto.Config".
module AgdaAuto.CLI
  ( AutoOpts(..)
  , defaultOpts
  , parseArgs
  , preprocess
  , usage
  , defaultsYaml
  ) where

import           AgdaGraph.ConfigCore ( splitEqFlags )

-- | Everything the CLI (and the config file, via "AgdaAuto.Config") can set.
-- Repeatable flags (@-i@, @--overlay-graph@, @--agda-arg@) append, so a config
-- base and CLI additions accumulate.
data AutoOpts = AutoOpts
  { aoWrite         :: !Bool             -- ^ @--write@: apply the diff instead of printing it.
  , aoAnnotate      :: !Bool             -- ^ @--annotate@/@--no-annotate@: marker comments in unsolved holes (default on).
  , aoTimeout       :: !Int              -- ^ @--timeout@: per-goal Mimer budget, seconds.
  , aoHints         :: !Int              -- ^ @--hints@: graph hints fetched per goal (@0@ = plain Mimer).
  , aoGraph         :: !(Maybe FilePath) -- ^ @--graph@: prebuilt expanded graph.json for hint ranking (else discovered, else none).
  , aoOverlays      :: ![FilePath]       -- ^ @--overlay-graph@ (repeatable): federated external graphs.
  , aoJson          :: !Bool             -- ^ @--json@: structured JSON report instead of the human table.
  , aoIncludes      :: ![FilePath]       -- ^ @-i@/@--include@ (repeatable): Agda include dirs.
  , aoAgdaBin       :: !(Maybe FilePath) -- ^ @--agda-bin@: agda binary (else @$AGDA_BIN@/@$PATH@).
  , aoAgdaArgs      :: ![String]         -- ^ @--agda-arg@ (repeatable): extra @agda --interaction-json@ flags.
  , aoPremiseSelect :: !Bool             -- ^ @--premise-select@: mirror the daemon's k-NN ranking gate.
  , aoRankIdf       :: !Bool             -- ^ @--rank-idf@: mirror the daemon's IDF ranking gate.
  , aoNoHintBatch   :: !Bool             -- ^ @--no-hint-batch@: mirror the daemon's Phase-3a A/B toggle.
  , aoNoAutoLadder  :: !Bool             -- ^ @--no-auto-ladder@: mirror the daemon's Phase-3b A/B toggle.
  , aoProject       :: !(Maybe FilePath) -- ^ @--project@: project root / session cwd (default cwd).
  , aoWallBudget    :: !Int              -- ^ @--wall-budget@: overall wall cap, seconds (@0@ = unbounded).
  , aoRepair        :: !Bool             -- ^ @--repair@: on a scope-error load failure, add missing imports first (import-only), then re-probe.
  , aoFixpoint      :: !Bool             -- ^ @--fixpoint@: with @--write@, re-sweep until a pass fills no new hole (a fill can unblock a dependent).
  , aoLedger        :: !(Maybe FilePath) -- ^ @--ledger@: append one JSON line per goal to this file (attempt log; off by default).
  , aoFiles         :: ![FilePath]       -- ^ positional Agda files / directories.
  , aoHelp          :: !Bool
  , aoVer           :: !Bool
  } deriving (Eq, Show)

-- | The baseline every config / CLI layer overlays onto.
defaultOpts :: AutoOpts
defaultOpts = AutoOpts
  { aoWrite = False, aoAnnotate = True, aoTimeout = 5, aoHints = 6
  , aoGraph = Nothing, aoOverlays = [], aoJson = False
  , aoIncludes = [], aoAgdaBin = Nothing, aoAgdaArgs = []
  , aoPremiseSelect = False, aoRankIdf = False
  , aoNoHintBatch = False, aoNoAutoLadder = False
  , aoProject = Nothing, aoWallBudget = 0
  , aoRepair = False, aoFixpoint = False, aoLedger = Nothing
  , aoFiles = [], aoHelp = False, aoVer = False
  }

-- | Split @--key=value@ into two tokens (the shared @agda-explore@ splitter in
-- "AgdaGraph.ConfigCore") so 'parseArgs' only handles the space-separated form.
preprocess :: [String] -> [String]
preprocess = splitEqFlags

-- | Fold argv onto a seed 'AutoOpts'. A leading non-dash token is a positional
-- (an Agda file or a directory); an unrecognised @-@/@--@ flag
-- is a hard error so a typo never silently no-ops. @--config@ is lifted out
-- upstream ("AgdaGraph.ConfigCore".@extractConfigFlag@) and never reaches here.
parseArgs :: [String] -> AutoOpts -> Either String AutoOpts
parseArgs [] o = Right o
parseArgs (x : xs) o = case x of
  "--help"           -> parseArgs xs o { aoHelp = True }
  "-h"               -> parseArgs xs o { aoHelp = True }
  "--version"        -> parseArgs xs o { aoVer = True }
  "-V"               -> parseArgs xs o { aoVer = True }
  "--write"          -> parseArgs xs o { aoWrite = True }
  "--annotate"       -> parseArgs xs o { aoAnnotate = True }
  "--no-annotate"    -> parseArgs xs o { aoAnnotate = False }
  "--json"           -> parseArgs xs o { aoJson = True }
  "--premise-select" -> parseArgs xs o { aoPremiseSelect = True }
  "--rank-idf"       -> parseArgs xs o { aoRankIdf = True }
  "--no-hint-batch"  -> parseArgs xs o { aoNoHintBatch = True }
  "--no-auto-ladder" -> parseArgs xs o { aoNoAutoLadder = True }
  "--repair"         -> parseArgs xs o { aoRepair = True }
  "--fixpoint"       -> parseArgs xs o { aoFixpoint = True }
  "--ledger"         -> need $ \v -> o { aoLedger = Just v }
  "--timeout"        -> need $ \v -> o { aoTimeout = readInt v (aoTimeout o) }
  "--hints"          -> need $ \v -> o { aoHints = readInt v (aoHints o) }
  "--wall-budget"    -> need $ \v -> o { aoWallBudget = readInt v (aoWallBudget o) }
  "--graph"          -> need $ \v -> o { aoGraph = Just v }
  "--overlay-graph"  -> need $ \v -> o { aoOverlays = aoOverlays o ++ [v] }
  "-i"               -> need $ \v -> o { aoIncludes = aoIncludes o ++ [v] }
  "--include"        -> need $ \v -> o { aoIncludes = aoIncludes o ++ [v] }
  "--agda-bin"       -> need $ \v -> o { aoAgdaBin = Just v }
  "--agda-arg"       -> need $ \v -> o { aoAgdaArgs = aoAgdaArgs o ++ [v] }
  "--project"        -> need $ \v -> o { aoProject = Just v }
  _ | isFlag x       -> Left ("unknown argument: " ++ x)
    | otherwise      -> parseArgs xs o { aoFiles = aoFiles o ++ [x] }
  where
    need f = case xs of
      (v : rest) -> parseArgs rest (f v)
      []         -> Left (x ++ " requires a value")
    isFlag ('-' : _) = True
    isFlag _         = False
    readInt s d = case reads s of [(n, "")] -> n; _ -> d

usage :: String
usage = unlines
  [ "agda-auto — batch hole-filling for Agda (a delivery vehicle for"
  , "agda-explore's Mimer/lemma-search ladder; links no Agda, drives `agda`)."
  , ""
  , "Usage:"
  , "  agda-auto [options] FILE.agda [FILE.agda ...]"
  , ""
  , "Runs the same auto ladder the agda-explore daemon uses over every open"
  , "hole in each file: plain Mimer, then graph-ranked in-scope lemma hints."
  , "Prints a unified diff by default; --write applies it (Agda-validated,"
  , "under the zero-axiom guard). Needs `agda` on $PATH (or --agda-bin)."
  , ""
  , "Options:"
  , "  --write               Apply the solutions (write + reload) instead of"
  , "                        printing a diff."
  , "  --annotate            Leave a marker comment in each unsolved hole"
  , "                        (default on): its goal type + lemmas to try."
  , "  --no-annotate         Do not annotate unsolved holes."
  , "  --timeout N           Per-goal Mimer budget in seconds (default 5)."
  , "  --hints K             Graph lemma hints fetched per goal (default 6;"
  , "                        0 = plain Mimer, no graph ranking)."
  , "  --graph FILE          Prebuilt expanded graph.json for hint ranking."
  , "                        Default: ./deps.json or ./.agda-explore/deps.json"
  , "                        if present, else plain Mimer (no hints)."
  , "  --overlay-graph FILE  Federate an external graph (e.g. agda-stdlib) into"
  , "                        the hint corpus. Repeatable."
  , "  --json                Emit a structured JSON report."
  , "  -i, --include DIR     Agda include directory for loading (repeatable)."
  , "  --agda-bin P          Path to agda (else $AGDA_BIN, $PATH)."
  , "  --agda-arg ARG        Extra flag for `agda --interaction-json`"
  , "                        (repeatable; e.g. --agda-arg --safe)."
  , "  --premise-select      Blend k-NN premise selection into hint ranking"
  , "                        (needs edge provenance + signatures in the graph)."
  , "  --rank-idf            IDF-weight the lemma ranker."
  , "  --no-hint-batch       Disable the batched-hint probe tier (A/B toggle)."
  , "  --no-auto-ladder      Disable the two-pass budget ladder (A/B toggle)."
  , "  --project DIR         Project root / agda cwd (default: current dir)."
  , "  --wall-budget N       Overall wall cap in seconds (0 = none)."
  , "  --repair              If a file fails to load with a scope error, add the"
  , "                        missing imports first (import-only), then re-probe."
  , "  --fixpoint            With --write, re-sweep a project until a pass fills no"
  , "                        new hole (a filled import can unblock a dependent)."
  , "  --ledger FILE         Append one JSON line per goal (an attempt log) to FILE."
  , "  --config FILE         Load this .agda-auto.yml (else discovered)."
  , "  --show-defaults       Print a starter .agda-auto.yml (all defaults) to"
  , "                        stdout, then exit. Redirect it to create a config:"
  , "                        agda-auto --show-defaults > .agda-auto.yml"
  , "  -h, --help            This help."
  , "  -V, --version         Version."
  , ""
  , "Config: a .agda-auto.yml / .yaml is discovered from --config,"
  , "$AGDA_AUTO_CONFIG, ./.agda-auto.yml, or the nearest *.agda-lib ancestor."
  , "Keys are kebab-case mirrors of the flags; merge order defaults < config < CLI."
  , ""
  , "Exit codes: 0 = no holes remain, 1 = holes remain, 2 = error."
  ]

-- | The @--show-defaults@ payload: a documented @.agda-auto.yml@ with every
-- option at its built-in default. Values are read from 'defaultOpts' so they
-- can't drift from the real defaults. Scalar keys are emitted active (so saving
-- the file verbatim is a no-op overlay); optional path/list keys are emitted
-- as commented examples. See "AgdaAuto.Config" for the key ↔ flag mapping.
defaultsYaml :: String
defaultsYaml = unlines
  [ "# .agda-auto.yml — configuration for agda-auto (all keys at their defaults)."
  , "# Generated by `agda-auto --show-defaults`. Keys are kebab-case mirrors of the"
  , "# CLI flags; merge order is defaults < config < CLI. Uncomment/edit to override."
  , ""
  , "# Apply the solutions (write + reload) instead of printing a diff."
  , "write: " ++ yn (aoWrite defaultOpts)
  , "# Leave a marker comment in each unsolved hole."
  , "annotate: " ++ yn (aoAnnotate defaultOpts)
  , "# Per-goal Mimer budget in seconds."
  , "timeout: " ++ show (aoTimeout defaultOpts)
  , "# Graph lemma hints fetched per goal (0 = plain Mimer, no graph ranking)."
  , "hints: " ++ show (aoHints defaultOpts)
  , "# Emit a structured JSON report instead of a human diff/table."
  , "json: " ++ yn (aoJson defaultOpts)
  , "# Blend k-NN premise selection into hint ranking (needs provenance + sigs)."
  , "premise-select: " ++ yn (aoPremiseSelect defaultOpts)
  , "# IDF-weight the lemma ranker."
  , "rank-idf: " ++ yn (aoRankIdf defaultOpts)
  , "# Disable the batched-hint probe tier (A/B toggle)."
  , "no-hint-batch: " ++ yn (aoNoHintBatch defaultOpts)
  , "# Disable the two-pass budget ladder (A/B toggle)."
  , "no-auto-ladder: " ++ yn (aoNoAutoLadder defaultOpts)
  , "# Overall wall cap in seconds (0 = unbounded)."
  , "wall-budget: " ++ show (aoWallBudget defaultOpts)
  , "# On a scope-error load failure, add missing imports first, then re-probe."
  , "repair: " ++ yn (aoRepair defaultOpts)
  , "# With write, re-sweep a project until a pass fills no new hole."
  , "fixpoint: " ++ yn (aoFixpoint defaultOpts)
  , ""
  , "# --- Optional keys (commented; uncomment and set a value to use) ---"
  , "# Prebuilt expanded graph.json for hint ranking (else ./deps.json / discovered)."
  , "# graph: deps.json"
  , "# Federated external graphs, e.g. a prebuilt agda-stdlib graph (list)."
  , "# overlay-graphs: [stdlib.json]"
  , "# Agda include directories for loading (list)."
  , "# include-paths: [src]"
  , "# Path to the agda binary (else $AGDA_BIN, $PATH)."
  , "# agda-bin: agda"
  , "# Extra flags for `agda --interaction-json` (list)."
  , "# agda-args: [--safe]"
  , "# Project root / agda cwd (default: current dir)."
  , "# project: ."
  , "# Append one JSON line per goal (an attempt log) to this file."
  , "# ledger: agda-auto.jsonl"
  ]
  where
    yn b = if b then "true" else "false"
