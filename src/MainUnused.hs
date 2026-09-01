{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @agda-unused@ — surface unused imports and other graph-derivable
-- simplification opportunities in an Agda project.
--
-- Workflow:
--
-- 1. Run @agda-deps --format=json --json-mode=expanded@ over the
--    project to produce @deps.json@.
-- 2. Invoke this tool: @agda-unused --json=<deps.json> <root-dir>@.
--    The tool source-scans every @.agda@ / @.lagda*@ file under
--    @<root-dir>@, cross-references with the expanded JSON, and prints
--    one finding per line.
module Main where

import           Control.Concurrent      ( getNumCapabilities )
import           Control.Concurrent.Async ( mapConcurrently )
import           Control.Exception ( IOException, catch )
import           Control.Monad     ( foldM, when )
import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.List         ( intercalate, isPrefixOf, isSuffixOf, partition
                                   , sortBy, sortOn, stripPrefix )
import           Data.Ord          ( Down(..), comparing )
import qualified Data.Map.Strict   as M
import qualified Data.Set          as S
import           Data.Text         ( Text )
import qualified Data.Text         as T
import qualified Data.Text.IO      as TIO

import           System.Directory ( doesDirectoryExist, doesFileExist, listDirectory
                                   , makeAbsolute )
import           System.Environment ( getArgs )
import           System.Exit ( exitFailure, exitSuccess )
import           System.FilePath ( (</>), normalise, takeDirectory )
import           System.IO ( hPutStrLn, stderr )

import           AgdaGraph.ConfigCore ( extractConfigFlag, isAgdaSourceFile )
import           AgdaGraph.Glob      ( globMatch )
import           AgdaGraph.Version   ( numericVersion, versionLine )
import           AgdaUnused.Analysis
import           AgdaUnused.Config   ( ConfigTarget(..)
                                     , applyConfig, discoverConfigPath, loadConfig
                                     , parseKindsToken
                                     )
import           AgdaUnused.Json     ( ExpandedGraph(..), loadExpandedGraph )

-- ** CLI options

data Options = Options
  { optJsonPath  :: !FilePath
  , optRoots     :: ![FilePath]
  , optKinds     :: ![FindingKind]
  , optRelTo     :: !(Maybe FilePath)
  , optFormat    :: !OutFormat
  , optExclude   :: ![String]
  , optGroupBy   :: !(Maybe GroupBy)
  , optCountOnly :: !Bool
  }

data OutFormat = OutPlain | OutJson

defaultOptions :: Options
defaultOptions = Options
  { optJsonPath  = ""
  , optRoots     = []
  , optKinds     = [UnusedInUsing, DuplicateUsingForModule]
  , optRelTo     = Nothing
  , optFormat    = OutPlain
  , optExclude   = []
  , optGroupBy   = Nothing
  , optCountOnly = False
  }

usage :: String
usage = unlines
  [ "agda-unused — flag unused imports in an Agda project."
  , ""
  , "USAGE:"
  , "  agda-unused --graph=DEPS.JSON [--kinds=...] [--rel-to=DIR] [--format=json] ROOT…"
  , ""
  , "OPTIONS:"
  , "  --graph=FILE      agda-deps expanded JSON (produced by"
  , "                      `agda-deps --format=json --json-mode=expanded`)."
  , "  --json=FILE       alias of --graph=FILE (kept for compatibility)."
  , "  --config=PATH     load options from YAML config (otherwise auto-discovered:"
  , "                      $AGDA_UNUSED_CONFIG, ./.agda-unused.yml, then walk-up to"
  , "                      the first dir containing a *.agda-lib)."
  , "  --show-defaults   print a starter .agda-unused.yml (all defaults) to stdout"
  , "                      and exit (redirect it: --show-defaults > .agda-unused.yml)."
  , "  -h, --help        print this help and exit."
  , "  -V, --version     print the agda-unused version and exit."
  , "  --numeric-version print just the version number and exit."
  , "  --rel-to=DIR      print file paths relative to DIR (default: absolute)."
  , "  --exclude=GLOB    drop findings whose file path or module name matches GLOB"
  , "                      (repeatable). `**` spans directories, `*` stops at `/`,"
  , "                      `?` one char — e.g. `--exclude='**/Init.agda'` or"
  , "                      `--exclude='Prelude.*'`."
  , "  --format=FMT      output format: 'human' (default) or 'json'."
  , "  --json-out        alias of --format=json (kept for compatibility)."
  , "  --group-by=G      aggregate findings into per-group counts instead of"
  , "                      one line per finding. G is one of:"
  , "                      dir   — bucket by directory of the (relativised) path"
  , "                      file  — bucket by the (relativised) file path"
  , "                      kind  — bucket by finding kind"
  , "                      Output is sorted by descending count, ties broken by"
  , "                      group key ascending."
  , "  --count-only      print only the grand total (`# total: N finding(s)`)."
  , "                      Wins over --group-by if both are given."
  , "  --kinds=K[,K…]    which checks to run (default: 'using,duplicate')."
  , "                      using          — symbols in `using (…)` not referenced in body"
  , "                      duplicate      — same module opened twice from same file"
  , "                      blanket        — blanket `open import M` with no observed use"
  , "                      defined        — alias for `dead,internal-only`"
  , "                      dead           — no callers anywhere (deletion candidate;"
  , "                                       includes `field`)"
  , "                      field          — record field whose projection is never"
  , "                                       applied (remove the field; low confidence)"
  , "                      internal-only  — intra-module callers only (private candidate)"
  , "                      public         — `open … public` re-exports with no consumer"
  , "                      arg-removable  — arguments the definition never uses; the"
  , "                                       binder and every call-site argument can go"
  , "                      arg-erasable   — arguments used only in types (mark them @0)."
  , "                                       Far more common than arg-removable, so it"
  , "                                       has its own token"
  , "                      args           — alias for `arg-removable,arg-erasable`"
  , "                      all            — every check above"
  , ""
  , "  Argument indices are 0-based telescope positions, IMPLICITS INCLUDED,"
  , "  counted on the definition's own signature line. They need a graph built"
  , "  by a producer that emits `argUsage`; older graphs yield no such findings."
  , "  A `removable` verdict means the binder is deletable from the type as"
  , "  WRITTEN: the producer filters positions still occurring in the codomain"
  , "  or a surviving later domain, whether that occurrence is relevant or not."
  , ""
  , "ROOT…  one or more directories to source-scan for `.agda` / `.lagda*` files."
  , ""
  , "EXIT CODES:"
  , "  0  success (findings printed; a zero count is still success)."
  , "  1  error: bad flags, unreadable/mismatched graph, config parse failure,"
  , "     or a mis-scoped run (scanned files, none matched the graph)."
  ]

-- | The @--show-defaults@ payload: a documented @.agda-unused.yml@ with the
-- scalar checks at their defaults and the path/list keys shown as commented
-- examples. Values bind to 'defaultOptions' so they track the real defaults;
-- keys are the kebab-case mirrors "AgdaUnused.Config" decodes.
defaultsYaml :: String
defaultsYaml = unlines
  [ "# .agda-unused.yml — configuration for agda-unused (defaults shown)."
  , "# Generated by `agda-unused --show-defaults`. Keys mirror the CLI flags;"
  , "# merge order is defaults < config < CLI. Uncomment/edit to override."
  , ""
  , "# Which checks to run. Tokens: using, duplicate, blanket, dead,"
  , "# field, internal-only, public, defined (= dead + internal-only),"
  , "# arg-removable, arg-erasable, args (= both), all."
  , "# `dead` includes `field` (a never-projected record field is a dead"
  , "# definition); `field` selects those alone. The arg-* checks need a"
  , "# graph whose producer emits `argUsage`."
  , "kinds: [" ++ intercalate ", " (map kindToken (optKinds defaultOptions)) ++ "]"
  , "# Output format: 'human' (plain text) or 'json' (a JSON array)."
  , "format: " ++ (case optFormat defaultOptions of OutJson -> "json"; OutPlain -> "human")
  , "# Print only the grand total (wins over group-by)."
  , "count-only: " ++ yn (optCountOnly defaultOptions)
  , ""
  , "# --- Required / optional keys (uncomment and set a value to use) ---"
  , "# agda-deps expanded JSON (also settable via --graph=FILE on the CLI;"
  , "# the legacy key `json:` is still accepted)."
  , "# graph: deps.json"
  , "# Directories to source-scan for .agda / .lagda* files (the ROOT args)."
  , "# roots: [src]"
  , "# Print file paths relative to this directory (default: absolute)."
  , "# rel-to: src"
  , "# Drop findings whose file/module matches a glob (list; ** spans dirs)."
  , "# exclude: ['**/Init.agda', 'Prelude.*']"
  , "# Aggregate into per-group counts instead of one line each: dir | file | kind."
  , "# group-by: dir"
  ]
  where
    yn b = if b then "true" else "false"
    kindToken k = case k of
      UnusedInUsing           -> "using"
      UnusedBlanketOpen       -> "blanket"
      DefinedDead             -> "dead"
      DefinedInternalOnly     -> "internal-only"
      PublicWithoutDownstream -> "public"
      DuplicateUsingForModule -> "duplicate"

-- | Track whether the user gave roots on the CLI. If they did, CLI
-- wins (positionals replace the seed); if not, we keep config roots.
data ParseState = ParseState
  { psOpts     :: !Options
  , psCliRoots :: ![FilePath]
  , psHadRoots :: !Bool
  }

parseArgs :: Options -> [String] -> Either String Options
parseArgs seed = go ParseState { psOpts = seed, psCliRoots = [], psHadRoots = False }
  where
    finish (ParseState o cliRoots hadRoots)
      | null (optJsonPath o) = Left "missing input graph (--graph=FILE; the --json=FILE alias also works)"
      | hadRoots && null cliRoots && null (optRoots o)
          = Left "missing ROOT directory"
      | not hadRoots && null (optRoots o)
          = Left "missing ROOT directory"
      | otherwise = Right $ if hadRoots
          then o { optRoots = reverse cliRoots }
          else o
    go !st []      = finish st
    go !st (a:rest)
      | Just v <- stripPrefix "--graph="   a = go st { psOpts = (psOpts st) { optJsonPath = v } } rest
      | Just v <- stripPrefix "--json="    a = go st { psOpts = (psOpts st) { optJsonPath = v } } rest
      | Just v <- stripPrefix "--format="  a = case v of
          "json"  -> go st { psOpts = (psOpts st) { optFormat = OutJson } } rest
          "human" -> go st { psOpts = (psOpts st) { optFormat = OutPlain } } rest
          _       -> Left ("unknown --format value: " ++ v ++ " (want human|json)")
      | Just v <- stripPrefix "--rel-to="  a = go st { psOpts = (psOpts st) { optRelTo    = Just v } } rest
      | Just v <- stripPrefix "--exclude=" a = go st { psOpts = (psOpts st) { optExclude  = optExclude (psOpts st) ++ [v] } } rest
      | Just v <- stripPrefix "--kinds="   a = case parseKinds v of
          Left e   -> Left e
          Right ks -> go st { psOpts = (psOpts st) { optKinds = ks } } rest
      | Just v <- stripPrefix "--group-by=" a = case parseGroupBy v of
          Left e  -> Left e
          Right g -> go st { psOpts = (psOpts st) { optGroupBy = Just g } } rest
      | a == "--count-only" = go st { psOpts = (psOpts st) { optCountOnly = True } } rest
      | a == "--json-out" = go st { psOpts = (psOpts st) { optFormat = OutJson } } rest
      | a == "-h" || a == "--help" = Left ""
      | "--" `isPrefixOf` a = Left $ "unrecognised flag: " ++ a
      | otherwise = go st
          { psCliRoots = a : psCliRoots st
          , psHadRoots = True
          } rest

parseKinds :: String -> Either String [FindingKind]
parseKinds = fmap concat . mapM (parseKindsToken . trim) . splitComma
  where
    -- Trim surrounding whitespace per token so the CLI accepts
    -- @--kinds=defined, public@ — matching the YAML path
    -- ('AgdaUnused.Config.parseKindsCSV'), which already trims.
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
    splitComma s = case break (== ',') s of
      (a, "")     -> [a]
      (a, _:rest) -> a : splitComma rest

-- ** Source-file discovery

-- | Every Agda source file under @root@ — or @root@ itself when it names one.
--
-- The single-file case is not a convenience: @ROOT@ is documented as a path,
-- @agda-explore@'s @unused@ tool resolves @scope@ to one (validating it
-- against the graph first), and its post-edit hook scopes to the file just
-- edited. Walking directories only meant every one of those reported
-- @# total: 0 finding(s)@ for every kind — a silent zero, since a scan that
-- reads no file also trips no "none of these matched the graph" guard.
--
-- Narrowing the scan narrows the /source/ evidence with it: the cross-file
-- token index behind @dead@ and @blanket@ can only see the files scanned, so
-- a name mentioned solely in an unscanned file reads as unmentioned. That is
-- true of any sub-root scope, and it does not reach the graph-derived checks
-- ('unusedArguments' consults no token at all).
discoverAgdaFiles :: FilePath -> IO [FilePath]
discoverAgdaFiles root = do
  isDir <- doesDirectoryExist root
  if isDir
    then go [] root
    else do
      isFile <- doesFileExist root
      return [ root | isFile, isAgdaSourceFile root ]
  where
    go acc d = do
      entries <- listDirectory d `catch` \(_ :: IOException) -> return []
      foldM step acc [ d </> e | e <- entries, not (isHidden e) ]

    step acc p = do
      isDir <- doesDirectoryExist p
      if isDir
        then go acc p
        else return (if isAgdaSourceFile p then p : acc else acc)

    isHidden ('.':_) = True
    isHidden _       = False

-- ** Path display

displayPath :: Maybe FilePath -> FilePath -> FilePath
displayPath Nothing     p = p
displayPath (Just root) p
  | root' `isPrefixOf` p = drop (length root') p
  | otherwise            = p
  where
    root' = if "/" `isSuffixOf` root then root else root ++ "/"

-- ** Entry

main :: IO ()
main = do
  rawArgv <- getArgs
  -- `--version` / `--numeric-version` / `--show-defaults` short-circuit before
  -- any config discovery/load, so they work with no project / a broken config.
  when ("--numeric-version" `elem` rawArgv) (putStrLn numericVersion >> exitSuccess)
  when (any (`elem` rawArgv) ["--version", "-V"]) (putStrLn (versionLine "agda-unused") >> exitSuccess)
  when ("--show-defaults" `elem` rawArgv) (putStr defaultsYaml >> exitSuccess)
  let (explicitCfg, argv) = extractConfigFlag rawArgv

  cfgPath <- discoverConfigPath explicitCfg
  (seedOpts, cfgApplied) <- case cfgPath of
    Nothing -> return (defaultOptions, Nothing)
    Just p  -> do
      loaded <- loadConfig p
      case loaded of
        Left err -> do
          hPutStrLn stderr $ "agda-unused: failed to parse config " ++ p ++ ": " ++ err
          exitFailure
        Right c -> return (applyConfig configTarget c defaultOptions, Just p)

  opts <- case parseArgs seedOpts argv of
    Left ""  -> putStrLn usage >> exitSuccess
    Left err -> do
      hPutStrLn stderr ("agda-unused: " ++ err)
      hPutStrLn stderr "Try 'agda-unused --help'."
      exitFailure
    Right o  -> return o

  -- Stderr breadcrumb. Suppressed in --json-out for clean stdout
  -- consumers that pipe stderr through too (e.g. CI scripts).
  case (cfgApplied, optFormat opts) of
    (Just p, OutPlain) ->
      hPutStrLn stderr $ "agda-unused: applied config from " ++ p
    _ -> return ()

  graphE <- loadExpandedGraph (optJsonPath opts)
  graph  <- case graphE of
    Left err -> do
      hPutStrLn stderr ("agda-unused: failed to read " ++ optJsonPath opts ++ ": " ++ err)
      exitFailure
    Right g -> return g

  -- Absolutise every ROOT before discovery so the file paths
  -- 'discoverAgdaFiles' builds (via @root </> e@) are absolute and line
  -- up with the graph's absolute 'egModuleFiles' values. A relative
  -- root would otherwise yield relative file paths that never match any
  -- graph key, skipping every file and silently reporting 0 findings.
  absRoots <- mapM makeAbsolute (optRoots opts)
  files  <- concat <$> mapM discoverAgdaFiles absRoots
  caps   <- getNumCapabilities
  let poolSize  = max 1 (min 8 caps)
      readOne f = do
        exists <- doesFileExist f
        if not exists then return Nothing else
          (Just . (,) f <$> TIO.readFile f) `catch` \(_ :: IOException) -> return Nothing
      chunks    = chunksOf (max 1 ((length files + poolSize - 1) `div` poolSize)) files
  bodies <- concat <$> mapConcurrently (mapM readOne) chunks
  let pairs = [ p | Just p <- bodies ]

  -- Never silently return 0 on a mis-scoped run. Compare the scanned
  -- source paths against the graph's moduleFiles values (both under
  -- 'normalise'); if we scanned files but none matched the graph, the
  -- ROOT and the @--json@ don't line up. Hard-error to stderr (stdout
  -- must stay byte-stable for --json-out) instead of printing a
  -- deceptive @# total: 0@. A genuine zero (files matched, no findings)
  -- still falls through to the normal output below.
  let graphPaths  = S.fromList (map normalise (M.elems (egModuleFiles graph)))
      matchedCnt  = length [ () | (p, _) <- pairs, normalise p `S.member` graphPaths ]
  when (not (null pairs) && matchedCnt == 0) $ do
    hPutStrLn stderr $
      "agda-unused: scanned " ++ show (length pairs)
        ++ " source file(s) but none matched the graph's moduleFiles "
        ++ "(paths don't line up — pass an absolute ROOT, or check --graph is for this project)"
    exitFailure

  let allFindings = analyse graph pairs
      -- Tokenise each exclude pattern once (partial application of
      -- globMatch), rather than re-parsing it for every finding.
      matchers    = map globMatch (optExclude opts)
      excluded f  = any (\m -> m (fileFinding f) || m (T.unpack (moduleFinding f))) matchers
      kindMatched = filter (\f -> kindFinding f `elem` optKinds opts) allFindings
      (dropped, keep) = partition excluded kindMatched
      sorted      = sortOn (\f -> (fileFinding f, lineFinding f)) keep
      -- Findings that matched the active kinds but were dropped solely
      -- by --exclude. Reported so a low/zero total can't be mistaken for
      -- an over-broad exclude.
      suppressed  = length dropped

  -- Output dispatch. Precedence: --count-only wins over --group-by;
  -- --group-by replaces the per-line body with aggregated rows. The
  -- `# total:` and `# excluded:` breadcrumbs survive in every plain-text
  -- mode so a low count can't be mistaken for an over-broad exclude.
  let total       = length sorted
      excludeLine = when (not (null (optExclude opts))) $
        putStrLn $ "# excluded: " ++ intercalate ", " (optExclude opts)
                     ++ " (" ++ show suppressed ++ " suppressed)"
  case optFormat opts of
    OutPlain
      | optCountOnly opts -> do
          putStrLn $ "# total: " ++ show total ++ " finding(s)"
          excludeLine
      | Just g <- optGroupBy opts -> do
          mapM_ (\(k, n) -> putStrLn $ T.unpack k ++ "\t" ++ show n)
                (aggregate opts g sorted)
          putStrLn $ "# total: " ++ show total ++ " finding(s)"
          excludeLine
      | otherwise -> do
          mapM_ (putStrLn . formatLine opts) sorted
          putStrLn $ "# total: " ++ show total ++ " finding(s)"
          excludeLine
    OutJson
      | optCountOnly opts ->
          BLC.putStrLn (A.encode (A.object ["total" .= total]))
      | Just g <- optGroupBy opts ->
          BLC.putStrLn (A.encode (A.toJSON
            [ A.object ["group" .= k, "count" .= n]
            | (k, n) <- aggregate opts g sorted ]))
      | otherwise ->
          BLC.putStrLn (A.encode (toJson opts sorted))

-- | Take 'renderFindingLine's absolute-path output and rewrite the
-- file prefix to the user's preferred relative form. The renderer
-- always starts with the absolute path followed by ":<line>:".
formatLine :: Options -> Finding -> String
formatLine opts f =
  let raw   = renderFindingLine f
      shown = displayPath (optRelTo opts) (fileFinding f)
  in case stripPrefix (fileFinding f) raw of
       Just rest -> shown ++ rest
       Nothing   -> raw

-- | Bucket findings into @(group-key, count)@ pairs for @--group-by@.
-- Counting uses 'M.insertWith (+)', an associative-commutative reduce,
-- so the result is order-independent (determinism-safe under @+RTS -N@).
-- Rendering order is a TOTAL order — descending count, ties broken by
-- group key ascending — so two groups with equal counts can never flip
-- between @-N1@ and @-NK@ runs. Group keys are derived AFTER
-- relativisation (so @--rel-to@ collapses paths sharing a subdir) and a
-- @dir@ with no directory component is bucketed under @\".\"@ rather
-- than dropped.
aggregate :: Options -> GroupBy -> [Finding] -> [(Text, Int)]
aggregate opts g fs =
  sortBy (comparing (Down . snd) <> comparing fst)
    (M.toList (M.fromListWith (+) [ (groupKey opts g f, 1) | f <- fs ]))

-- | The group key for one finding under a given 'GroupBy'.
groupKey :: Options -> GroupBy -> Finding -> Text
groupKey opts g f = case g of
  GByKind -> kindTag (kindFinding f)
  GByFile -> T.pack shown
  GByDir  -> T.pack (takeDirectory shown)
  where
    shown = displayPath (optRelTo opts) (fileFinding f)

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
  | n <= 0    = [xs]
  | null xs   = []
  | otherwise = let (h, t) = splitAt n xs in h : chunksOf n t


-- | Setters that let 'AgdaUnused.Config.applyConfig' touch our
-- internal 'Options' record without importing it.
configTarget :: ConfigTarget Options
configTarget = ConfigTarget
  { ctSetJson      = \v o -> o { optJsonPath  = v }
  , ctSetRelTo     = \v o -> o { optRelTo     = Just v }
  , ctSetJsonOut   = \v o -> o { optFormat    = if v then OutJson else OutPlain }
  , ctSetKinds     = \v o -> o { optKinds     = v }
  , ctSetRoots     = \v o -> o { optRoots     = v }
  , ctSetExclude   = \v o -> o { optExclude   = v }
  , ctSetGroupBy   = \v o -> o { optGroupBy   = Just v }
  , ctSetCountOnly = \v o -> o { optCountOnly = v }
  }

-- ** JSON-out

-- | A JSON array of findings, one object per finding. Keys mirror the
-- plain-text columns: @file@ (path, optionally relativised via
-- @--rel-to@), @line@, @module@, @symbol@ (or @null@), @kind@.
-- Built via aeson so string escaping is correct by construction.
toJson :: Options -> [Finding] -> A.Value
toJson opts fs = A.toJSON (map (one opts) fs)
  where
    one o f = A.object $
      [ "file"       .= displayPath (optRelTo o) (fileFinding f)
      , "line"       .= lineFinding f
      , "module"     .= moduleFinding f
      , "symbol"     .= symbolFinding f
      , "kind"       .= kindTag (kindFinding f)
      , "confidence" .= confTag (confFinding f)
      ]
      -- Argument findings carry their positions, not just the prose note:
      -- a consumer acting on one (the offline delete-and-retypecheck
      -- check, a cascade loop) needs the indices and — for a removal —
      -- the whole set that must go with each, or it strands a binder.
      -- Absent on every other kind.
      ++ [ "arguments" .= argumentsJson (kindFinding f) au
         | Just au <- [argsFinding f] ]

    confTag :: Confidence -> T.Text
    confTag High = "high"
    confTag Low  = "low"

