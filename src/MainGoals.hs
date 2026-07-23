{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @agda-goals@ — experimental process driver, not on the documented
-- end-user surface.
--
-- Drive @agda --interaction-json@ over one or more Agda source files,
-- capture every @?@-hole's rendered goal type, canonicalise the
-- string, and bucket by hash. The largest bucket is the "missing
-- intermediate lemma" candidate; its centroid (first-seen
-- representative) is the combinator's type signature.
--
-- Canonicalisation is textual rather than structural (see
-- @AgdaGoals.Canon@) because @--interaction-json@ only exposes
-- rendered strings, not internal 'Term' values.
module Main where

import           Control.Monad        ( forM_, when )
import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )
import qualified Data.ByteString.Lazy.Char8 as BLC
import           Data.List            ( isPrefixOf, stripPrefix )
import qualified Data.Text            as T
import           System.Environment   ( getArgs )
import           System.Directory     ( doesFileExist )
import           System.Exit          ( exitFailure, exitSuccess, exitWith
                                      , ExitCode(..) )
import           System.IO            ( hPutStrLn, stderr )

import           AgdaGraph.ConfigCore ( extractConfigFlag )
import           AgdaGraph.Version    ( numericVersion, versionLine )
import           AgdaGoals.Bucket     ( Bucket(..), GoalOccurrence(..)
                                      , bucketGoals, rankBuckets )
import           AgdaGoals.Canon      ( CanonicalGoal(..) )
import           AgdaGoals.Config     ( ConfigTarget(..), applyConfig
                                      , discoverConfigPath, loadConfig )
import           AgdaGoals.Driver     ( DriverConfig(..), DriverError(..)
                                      , DriverResult(..), runDriverBatch
                                      , driverErrorTag )
import           AgdaGoals.Protocol   ( Goal(..), GoalRange(..), RangePos(..) )

----------------------------------------------------------------------
-- Options & defaults.

data OutFormat = OutHuman | OutJson
  deriving (Show, Eq)

data Options = Options
  { optAgdaBin    :: !FilePath
  , optIncludes   :: ![FilePath]
  , optAgdaArgs   :: ![String]
  , optRoots      :: ![FilePath]
  , optFormat     :: !OutFormat
  , optQuiet      :: !Bool
  , optVerbose    :: !Bool
  , optTopN       :: !Int
    -- ^ Cap on number of buckets printed in human mode. JSON output
    -- emits every bucket regardless.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optAgdaBin   = "agda"
  , optIncludes  = []
  , optAgdaArgs  = []
  , optRoots     = []
  , optFormat    = OutHuman
  , optQuiet     = False
  , optVerbose   = False
  , optTopN      = 25
  }

usage :: String
usage = unlines
  [ "agda-goals — bucket goal types from `agda --interaction-json` to surface missing lemmas."
  , ""
  , "USAGE:"
  , "  agda-goals [OPTIONS] FILE..."
  , ""
  , "OPTIONS:"
  , "  -i, --include=DIR    pass DIR to agda as an include path (repeatable)."
  , "      --agda-bin=PATH  use the given agda binary instead of $PATH lookup."
  , "      --agda-arg=A     extra argument forwarded to agda (repeatable, e.g."
  , "                         --agda-arg=--allow-unsolved-metas)."
  , "      --config=PATH    load options from YAML config (otherwise auto-discovered:"
  , "                         $AGDA_GOALS_CONFIG, ./.agda-goals.yml, then walk up to"
  , "                         the first dir containing a *.agda-lib)."
  , "      --show-defaults  print a starter .agda-goals.yml (all defaults) to stdout"
  , "                         and exit (redirect it: --show-defaults > .agda-goals.yml)."
  , "      --format=FMT     output format: 'human' (default) or 'json'."
  , "      --top-n=N        in human mode, show only the top-N buckets (default 25)."
  , "      --quiet          suppress the 'applied config' stderr breadcrumb."
  , "      --verbose        echo the IOTCM command and agda's raw output to stderr."
  , "  -h, --help           print this help and exit."
  , "  -V, --version        print the agda-goals version and exit."
  , "      --numeric-version  print just the version number and exit."
  , ""
  , "ENVIRONMENT:"
  , "  AGDA_GOALS_AGDA_BIN  fallback for --agda-bin when neither flag nor config set it."
  , "  AGDA_GOALS_CONFIG    explicit config-file path (highest priority after --config)."
  , ""
  , "EXIT CODES:"
  , "  0  success."
  , "  1  CLI / usage error."
  , "  2  agda binary missing or could not be exec'd."
  , "  3  agda exited non-zero."
  , "  4  agda emitted output we couldn't parse."
  , "  5  no AllGoalsWarnings reply (protocol skew)."
  , "  6  agda reported a structured error before reaching the goal pass."
  ]

-- | The @--show-defaults@ payload: a documented @.agda-goals.yml@ with scalar
-- options at their defaults and the list keys shown as commented examples.
-- Values bind to 'defaultOptions'; keys mirror what "AgdaGoals.Config" decodes.
defaultsYaml :: String
defaultsYaml = unlines
  [ "# .agda-goals.yml — configuration for agda-goals (defaults shown)."
  , "# Generated by `agda-goals --show-defaults`. Keys mirror the CLI flags;"
  , "# merge order is defaults < config < CLI. Uncomment/edit to override."
  , ""
  , "# agda binary to drive (else $PATH lookup)."
  , "agda-bin: " ++ optAgdaBin defaultOptions
  , "# Output format: human | json."
  , "format: " ++ (case optFormat defaultOptions of OutJson -> "json"; OutHuman -> "human")
  , "# Suppress the 'applied config' stderr breadcrumb."
  , "quiet: " ++ yn (optQuiet defaultOptions)
  , "# In human mode, show only the top-N buckets (json emits all)."
  , "top-n: " ++ show (optTopN defaultOptions)
  , ""
  , "# --- Optional keys (uncomment and set a value to use) ---"
  , "# Agda include paths (list; each passed to agda as -i)."
  , "# include-paths: [src]"
  , "# Extra arguments forwarded to agda (list)."
  , "# agda-args: [--allow-unsolved-metas]"
  , "# Source files (or directories) to drive agda over (the positional FILEs)."
  , "# roots: [src/Foo.agda]"
  ]
  where
    yn b = if b then "true" else "false"

----------------------------------------------------------------------
-- CLI parsing.

parseArgs :: Options -> [String] -> Either String Options
parseArgs seed = go seed
  where
    go !o [] = case optRoots o of
      [] -> Left "missing FILE argument"
      _  -> Right o
    go !o (a:as)
      | a == "-h" || a == "--help" = Left ""
      | a == "--quiet"             = go (o { optQuiet = True }) as
      | a == "--verbose"           = go (o { optVerbose = True }) as
      | a == "-i" = case as of
          (v:as') -> go (o { optIncludes = optIncludes o ++ [v] }) as'
          []      -> Left "-i requires a value"
      | Just v <- stripPrefix "--include=" a =
          go (o { optIncludes = optIncludes o ++ [v] }) as
      | Just v <- stripPrefix "--agda-bin=" a =
          go (o { optAgdaBin = v }) as
      | Just v <- stripPrefix "--agda-arg=" a =
          go (o { optAgdaArgs = optAgdaArgs o ++ [v] }) as
      | Just v <- stripPrefix "--format=" a = case v of
          "human" -> go (o { optFormat = OutHuman }) as
          "json"  -> go (o { optFormat = OutJson  }) as
          _       -> Left $ "unknown --format value: " ++ v
      | Just v <- stripPrefix "--top-n=" a = case reads v of
          [(n, "")] -> go (o { optTopN = n }) as
          _         -> Left $ "--top-n expects an integer, got: " ++ v
      | "--" `isPrefixOf` a = Left $ "unrecognised flag: " ++ a
      | otherwise           = go (o { optRoots = optRoots o ++ [a] }) as

----------------------------------------------------------------------
-- Config glue.

configTarget :: ConfigTarget Options
configTarget = ConfigTarget
  { ctSetAgdaBin   = \v o -> o { optAgdaBin   = v }
  , ctSetIncludes  = \v o -> o { optIncludes  = v }
  , ctSetExtraArgs = \v o -> o { optAgdaArgs  = v }
  , ctSetFormat    = \v o -> case v of
                              "json"  -> o { optFormat = OutJson  }
                              _       -> o { optFormat = OutHuman }
  , ctSetQuiet     = \v o -> o { optQuiet     = v }
  , ctSetTopN      = \v o -> o { optTopN      = v }
  , ctSetRoots     = \v o -> o { optRoots     = v }
  }

----------------------------------------------------------------------
-- Entry point.

main :: IO ()
main = do
  rawArgv <- getArgs
  -- `--version` / `--numeric-version` / `--show-defaults` short-circuit before
  -- any config discovery/load, so they work with no project / a broken config.
  when ("--numeric-version" `elem` rawArgv) (putStrLn numericVersion >> exitSuccess)
  when (any (`elem` rawArgv) ["--version", "-V"]) (putStrLn (versionLine "agda-goals") >> exitSuccess)
  when ("--show-defaults" `elem` rawArgv) (putStr defaultsYaml >> exitSuccess)
  let (explicitCfg, argv) = extractConfigFlag rawArgv

  cfgPath <- discoverConfigPath explicitCfg
  (seedOpts, cfgApplied) <- case cfgPath of
    Nothing -> pure (defaultOptions, Nothing)
    Just p  -> do
      loaded <- loadConfig p
      case loaded of
        Left err -> do
          hPutStrLn stderr $ "agda-goals: failed to parse config " ++ p
                              ++ ": " ++ err
          exitFailure
        Right c -> pure (applyConfig configTarget c defaultOptions, Just p)

  opts <- case parseArgs seedOpts argv of
    Left ""  -> putStrLn usage >> exitSuccess
    Left err -> do
      hPutStrLn stderr ("agda-goals: " ++ err)
      hPutStrLn stderr "Try 'agda-goals --help'."
      exitFailure
    Right o  -> pure o

  -- Stderr breadcrumb. Suppressed under --quiet and --format=json.
  case (cfgApplied, optQuiet opts, optFormat opts) of
    (Just p, False, OutHuman) ->
      hPutStrLn stderr $ "agda-goals: applied config from " ++ p
    _ -> pure ()

  -- Drive Agda over the root files via ONE persistent
  -- `agda --interaction-json` process (reusing its .agdai cache across
  -- files), single-threaded. 'dcModuleFile' is a placeholder here —
  -- 'runDriverBatch' sets it per file.
  let tmpl = DriverConfig
        { dcAgdaBin      = optAgdaBin opts
        , dcModuleFile   = ""
        , dcIncludePaths = optIncludes opts
        , dcExtraArgs    = optAgdaArgs opts
        , dcVerbose      = optVerbose opts
        }

  -- Fail fast on a missing target file with a direct message + exit 2,
  -- instead of driving agda over it and surfacing the read failure
  -- through the interaction protocol (a confusing AgdaReportedError /
  -- exit 6).
  oks <- mapM doesFileExist (optRoots opts)
  let missing = [ f | (f, ok) <- zip (optRoots opts) oks, not ok ]
  when (not (null missing)) $ do
    forM_ missing $ \f -> hPutStrLn stderr ("agda-goals: file not found: " ++ f)
    exitWith (ExitFailure 2)

  results <- runDriverBatch tmpl (optRoots opts)

  -- Collect goals + propagate the first hard error to set exit code.
  -- Note: we still emit buckets for any successful files even if one
  -- module errored, so partial runs surface partial information.
  let tagged              = zip (optRoots opts) results
      errs                = foldl' (\acc (f, r) -> case r of
                                      DriverError e -> (f, e) : acc
                                      _             -> acc) [] tagged
      occurrences         = concat [ map (mkOcc modName) goals
                                   | (_, DriverOk modName goals) <- tagged ]
      buckets             = rankBuckets (bucketGoals occurrences)

  case optFormat opts of
    OutHuman -> renderHuman opts buckets errs
    OutJson  -> renderJson  buckets errs

  -- Exit code policy. If everything succeeded, exit 0. If at least
  -- one module failed, pick the highest-priority error and exit with
  -- its tag-mapped code.
  case errs of
    [] -> exitSuccess
    _  -> exitWith (errorExitCode (head errs))

-- | Tag a goal with its enclosing module as a 'GoalOccurrence',
-- keyed by its rendered type for bucketing.
mkOcc :: T.Text -> Goal -> (T.Text, GoalOccurrence)
mkOcc modName g =
  ( goalType g
  , GoalOccurrence
      { occModule  = modName
      , occLine    = fmap (rpLine . grStart) (goalRange g)
      , occRawType = goalType g
      }
  )

errorExitCode :: (FilePath, DriverError) -> ExitCode
errorExitCode (_, e) = ExitFailure (codeFor e)
  where
    codeFor MissingBinary{}     = 2
    codeFor AgdaNonZero{}       = 3
    codeFor BadOutput{}         = 4
    codeFor NoGoalsReply        = 5
    codeFor AgdaReportedError{} = 6

----------------------------------------------------------------------
-- Output renderers.

renderHuman :: Options -> [Bucket] -> [(FilePath, DriverError)] -> IO ()
renderHuman opts buckets errs = do
  -- Errors first, so users notice them.
  forM_ errs $ \(f, e) ->
    hPutStrLn stderr $
      "agda-goals: " ++ f ++ ": " ++ formatError e
  if null buckets
    then putStrLn "# 0 buckets (no goals found)."
    else do
      let total = sum (map bucketSize buckets)
          shown = take (optTopN opts) buckets
      putStrLn $ "# " ++ show (length buckets) ++ " bucket(s), "
                  ++ show total ++ " goal occurrence(s)"
      putStrLn ""
      forM_ (zip [(1 :: Int)..] shown) $ \(i, b) ->
        renderBucket i b
      when (length buckets > length shown) $
        putStrLn $ "# ... " ++ show (length buckets - length shown)
                    ++ " more bucket(s) hidden (use --top-n=N to widen)"

renderBucket :: Int -> Bucket -> IO ()
renderBucket i Bucket{..} = do
  let centroid = case bucketOccurrences of
        (o:_) -> occRawType o
        []    -> ""
  putStrLn $ "## bucket #" ++ show i
            ++ "  size=" ++ show bucketSize
            ++ "  hash=" ++ show bucketHash
  putStrLn $ "    centroid: " ++ T.unpack centroid
  putStrLn $ "    canonical: " ++ T.unpack (unCanonical bucketCanonical)
  forM_ (take 5 bucketOccurrences) $ \occ ->
    putStrLn $ "      " ++ T.unpack (occModule occ)
                ++ maybe "" (\l -> ":" ++ show l) (occLine occ)
                ++ " " ++ T.unpack (occRawType occ)
  when (length bucketOccurrences > 5) $
    putStrLn $ "      ... " ++ show (length bucketOccurrences - 5)
                ++ " more occurrence(s)"
  putStrLn ""

formatError :: DriverError -> String
formatError = \case
  MissingBinary p msg     -> "could not exec " ++ p ++ ": " ++ msg
  AgdaNonZero code err    -> "agda exited " ++ show code
                              ++ (if null err then "" else "\n  stderr: " ++ err)
  BadOutput errs          -> "couldn't parse agda output:\n"
                              ++ unlines (map ("  " ++) errs)
  AgdaReportedError msg   -> "agda reported an error before goal collection:\n"
                              ++ unlines (map ("  " ++) (lines (T.unpack msg)))
  NoGoalsReply            -> "agda emitted no AllGoalsWarnings reply"

----------------------------------------------------------------------
-- JSON output.

-- | Emit the bucket/error report as a JSON object with @buckets@ and
-- @errors@ arrays. Keys and value shapes mirror the human renderer;
-- encoded via aeson so string escaping (and the goal-type unicode) is
-- correct by construction.
renderJson :: [Bucket] -> [(FilePath, DriverError)] -> IO ()
renderJson buckets errs = BLC.putStrLn $ A.encode $ A.object
  [ "buckets" .= map bucketJ buckets
  , "errors"  .= map errJ errs
  ]
  where
    bucketJ b = A.object
      [ "hash"        .= bucketHash b
      , "size"        .= bucketSize b
      , "canonical"   .= unCanonical (bucketCanonical b)
      , "centroid"    .= case bucketOccurrences b of
                            (o:_) -> occRawType o
                            []    -> T.empty
      , "occurrences" .= map occJ (bucketOccurrences b)
      ]
    occJ o = A.object
      [ "module" .= occModule o
      , "line"   .= occLine o
      , "raw"    .= occRawType o
      ]
    errJ (f, e) = A.object
      [ "file"   .= f
      , "tag"    .= driverErrorTag e
      , "detail" .= formatError e
      ]
