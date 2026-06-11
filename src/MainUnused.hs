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
import           Data.List         ( intercalate, isPrefixOf, isSuffixOf, sortOn
                                   , stripPrefix )
import qualified Data.Text         as T
import qualified Data.Text.IO      as TIO

import           System.Directory ( doesDirectoryExist, doesFileExist, listDirectory )
import           System.Environment ( getArgs )
import           System.Exit ( exitFailure, exitSuccess )
import           System.FilePath ( (</>) )
import           System.IO ( hPutStrLn, stderr )

import           AgdaUnused.Analysis
import           AgdaUnused.Config   ( ConfigTarget(..)
                                     , applyConfig, discoverConfigPath, loadConfig
                                     , parseKindsToken
                                     )
import           AgdaUnused.Json     ( loadExpandedGraph )

-- ** CLI options

data Options = Options
  { optJsonPath :: !FilePath
  , optRoots    :: ![FilePath]
  , optKinds    :: ![FindingKind]
  , optRelTo    :: !(Maybe FilePath)
  , optFormat   :: !OutFormat
  , optExclude  :: ![String]
  }

data OutFormat = OutPlain | OutJson

defaultOptions :: Options
defaultOptions = Options
  { optJsonPath = ""
  , optRoots    = []
  , optKinds    = [UnusedInUsing, DuplicateUsingForModule]
  , optRelTo    = Nothing
  , optFormat   = OutPlain
  , optExclude  = []
  }

usage :: String
usage = unlines
  [ "agda-unused — flag unused imports in an Agda project."
  , ""
  , "USAGE:"
  , "  agda-unused --json=DEPS.JSON [--kinds=...] [--rel-to=DIR] [--json-out] ROOT…"
  , ""
  , "OPTIONS:"
  , "  --json=FILE       agda-deps expanded JSON (produced by"
  , "                      `agda-deps --format=json --json-mode=expanded`)."
  , "  --config=PATH     load options from YAML config (otherwise auto-discovered:"
  , "                      $AGDA_UNUSED_CONFIG, ./.agda-unused.yml, then walk-up to"
  , "                      the first dir containing a *.agda-lib)."
  , "  --rel-to=DIR      print file paths relative to DIR (default: absolute)."
  , "  --exclude=GLOB    drop findings whose file path or module name matches GLOB"
  , "                      (repeatable). `**` spans directories, `*` stops at `/`,"
  , "                      `?` one char — e.g. `--exclude='**/Init.agda'` or"
  , "                      `--exclude='Prelude.*'`."
  , "  --json-out        emit findings as a JSON array instead of plain text."
  , "  --kinds=K[,K…]    which checks to run (default: 'using,duplicate')."
  , "                      using          — symbols in `using (…)` not referenced in body"
  , "                      duplicate      — same module opened twice from same file"
  , "                      blanket        — blanket `open import M` with no observed use"
  , "                      defined        — alias for `dead,internal-only`"
  , "                      dead           — no callers anywhere (deletion candidate)"
  , "                      internal-only  — intra-module callers only (private candidate)"
  , "                      public         — `open … public` re-exports with no consumer"
  , "                      all            — every check above"
  , ""
  , "ROOT…  one or more directories to source-scan for `.agda` / `.lagda*` files."
  ]

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
      | null (optJsonPath o) = Left "missing --json=…"
      | hadRoots && null cliRoots && null (optRoots o)
          = Left "missing ROOT directory"
      | not hadRoots && null (optRoots o)
          = Left "missing ROOT directory"
      | otherwise = Right $ if hadRoots
          then o { optRoots = reverse cliRoots }
          else o
    go !st []      = finish st
    go !st (a:rest)
      | Just v <- stripPrefix "--json="    a = go st { psOpts = (psOpts st) { optJsonPath = v } } rest
      | Just v <- stripPrefix "--rel-to="  a = go st { psOpts = (psOpts st) { optRelTo    = Just v } } rest
      | Just v <- stripPrefix "--exclude=" a = go st { psOpts = (psOpts st) { optExclude  = optExclude (psOpts st) ++ [v] } } rest
      | Just v <- stripPrefix "--kinds="   a = case parseKinds v of
          Left e   -> Left e
          Right ks -> go st { psOpts = (psOpts st) { optKinds = ks } } rest
      | a == "--json-out" = go st { psOpts = (psOpts st) { optFormat = OutJson } } rest
      | a == "-h" || a == "--help" = Left ""
      | "--" `isPrefixOf` a = Left $ "unrecognised flag: " ++ a
      | otherwise = go st
          { psCliRoots = a : psCliRoots st
          , psHadRoots = True
          } rest

parseKinds :: String -> Either String [FindingKind]
parseKinds = fmap concat . mapM parseKindsToken . splitComma
  where
    splitComma s = case break (== ',') s of
      (a, "")     -> [a]
      (a, _:rest) -> a : splitComma rest

-- ** Source-file discovery

isAgdaSource :: FilePath -> Bool
isAgdaSource p = any (`isSuffixOf` p)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex"
  , ".lagda.org", ".lagda.tree", ".lagda.typ"
  ]

discoverAgdaFiles :: FilePath -> IO [FilePath]
discoverAgdaFiles root = do
  exists <- doesDirectoryExist root
  if not exists then return [] else go [] root
  where
    go acc d = do
      entries <- listDirectory d `catch` \(_ :: IOException) -> return []
      foldM step acc [ d </> e | e <- entries, not (isHidden e) ]

    step acc p = do
      isDir <- doesDirectoryExist p
      if isDir
        then go acc p
        else return (if isAgdaSource p then p : acc else acc)

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
      hPutStrLn stderr usage
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

  files  <- concat <$> mapM discoverAgdaFiles (optRoots opts)
  caps   <- getNumCapabilities
  let poolSize  = max 1 (min 8 caps)
      readOne f = do
        exists <- doesFileExist f
        if not exists then return Nothing else
          (Just . (,) f <$> TIO.readFile f) `catch` \(_ :: IOException) -> return Nothing
      chunks    = chunksOf (max 1 ((length files + poolSize - 1) `div` poolSize)) files
  bodies <- concat <$> mapConcurrently (mapM readOne) chunks
  let pairs = [ p | Just p <- bodies ]

  let allFindings = analyse graph pairs
      -- Tokenise each exclude pattern once (partial application of
      -- globMatch), rather than re-parsing it for every finding.
      matchers    = map globMatch (optExclude opts)
      excluded f  = any (\m -> m (fileFinding f) || m (T.unpack (moduleFinding f))) matchers
      kindMatched = filter (\f -> kindFinding f `elem` optKinds opts) allFindings
      keep        = filter (not . excluded) kindMatched
      sorted      = sortOn (\f -> (fileFinding f, lineFinding f)) keep
      -- Findings that matched the active kinds but were dropped solely
      -- by --exclude. Reported so a low/zero total can't be mistaken for
      -- an over-broad exclude.
      suppressed  = length (filter excluded kindMatched)

  case optFormat opts of
    OutPlain -> do
      mapM_ (putStrLn . formatLine opts) sorted
      putStrLn $ "# total: " ++ show (length sorted) ++ " finding(s)"
      when (not (null (optExclude opts))) $
        putStrLn $ "# excluded: " ++ intercalate ", " (optExclude opts)
                     ++ " (" ++ show suppressed ++ " suppressed)"
    OutJson ->
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

chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
  | n <= 0    = [xs]
  | null xs   = []
  | otherwise = let (h, t) = splitAt n xs in h : chunksOf n t

-- ** Exclude globbing

-- | Minimal glob matcher for @--exclude@. @**@ matches any run of
-- characters (including @\/@); @*@ matches any run /except/ @\/@; @?@
-- matches a single non-@\/@ char; everything else is literal. The
-- pattern is tested against both the absolute file path and the dotted
-- module name, so @**\/Init.agda@ and @Prelude.*@ both work. No new
-- dependency — patterns are short so the back-tracking match is cheap.
data GTok = GStarStar | GStar | GQuest | GLit !Char

globTokens :: String -> [GTok]
globTokens []           = []
globTokens ('*':'*':cs) = GStarStar : globTokens cs
globTokens ('*':cs)     = GStar     : globTokens cs
globTokens ('?':cs)     = GQuest    : globTokens cs
globTokens (c:cs)       = GLit c    : globTokens cs

globMatch :: String -> String -> Bool
globMatch pat = match (globTokens pat)
  where
    match []                s  = null s
    match (GStarStar : ts)  s  =
      match ts s || case s of { (_:cs) -> match (GStarStar : ts) cs; [] -> False }
    match (GStar : ts)      s  =
      match ts s || case s of { (c:cs) | c /= '/' -> match (GStar : ts) cs; _ -> False }
    match (GQuest : ts) (c:cs) | c /= '/' = match ts cs
    match (GQuest : _)  _      = False
    match (GLit p : ts) (c:cs) | p == c   = match ts cs
    match (GLit _ : _)  _      = False

-- | Strip @--config=PATH@ (or @--config PATH@) from argv, returning
-- the path (if any) and the remaining args.
extractConfigFlag :: [String] -> (Maybe FilePath, [String])
extractConfigFlag = go []
  where
    go acc []                 = (Nothing, reverse acc)
    go acc (a:rest)
      | Just v <- stripPrefix "--config=" a = (Just v, reverse acc ++ rest)
      | a == "--config" = case rest of
          (v:rest') -> (Just v, reverse acc ++ rest')
          []        -> (Nothing, reverse acc)  -- malformed; let parseArgs error later
      | otherwise = go (a : acc) rest

-- | Setters that let 'AgdaUnused.Config.applyConfig' touch our
-- internal 'Options' record without importing it.
configTarget :: ConfigTarget Options
configTarget = ConfigTarget
  { ctSetJson    = \v o -> o { optJsonPath = v }
  , ctSetRelTo   = \v o -> o { optRelTo    = Just v }
  , ctSetJsonOut = \v o -> o { optFormat   = if v then OutJson else OutPlain }
  , ctSetKinds   = \v o -> o { optKinds    = v }
  , ctSetRoots   = \v o -> o { optRoots    = v }
  , ctSetExclude = \v o -> o { optExclude  = v }
  }

-- ** JSON-out

-- | A JSON array of findings, one object per finding. Keys mirror the
-- plain-text columns: @file@ (path, optionally relativised via
-- @--rel-to@), @line@, @module@, @symbol@ (or @null@), @kind@.
-- Built via aeson so string escaping is correct by construction.
toJson :: Options -> [Finding] -> A.Value
toJson opts fs = A.toJSON (map (one opts) fs)
  where
    one o f = A.object
      [ "file"   .= displayPath (optRelTo o) (fileFinding f)
      , "line"   .= lineFinding f
      , "module" .= moduleFinding f
      , "symbol" .= symbolFinding f
      , "kind"   .= kindTag (kindFinding f)
      ]

    kindTag :: FindingKind -> T.Text
    kindTag UnusedInUsing           = "unused-in-using"
    kindTag UnusedBlanketOpen       = "unused-blanket-open"
    kindTag DefinedDead             = "defined-dead"
    kindTag DefinedInternalOnly     = "defined-internal-only"
    kindTag DuplicateUsingForModule = "duplicate-using"
    kindTag PublicWithoutDownstream = "public-no-downstream"
