{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | @hint-bench@ — offline leave-one-out evaluation of the lemma ranker.
--
-- Every proved theorem is a self-labelled retrieval query: its signature
-- is the goal and its body-provenance dependencies are the ground-truth
-- premises. Hiding the theorem and ranking the rest of the library against
-- its signature measures how often the real premises surface in the top-k
-- hint budget — the number that predicts whether seeding those candidates
-- as Mimer hints would let @auto@ close the goal. This lets a ranking
-- change be judged with no live @agda@ run: no ranking change should land
-- without moving these numbers.
--
-- The corpus, strategies, and scoring are the pure 'AgdaGraph.PremiseBench'
-- core (shared with @test/Spec.hs@, which pins a regression floor on the
-- shipped @baseline@ strategy). This module is only the CLI skin: flag
-- parsing, strategy selection, and human / JSON rendering.
--
-- A graph with no edge provenance (legacy JSON) or no signatures yields an
-- empty corpus; the subcommand reports the reason and exits cleanly (0).
module AgdaOptimization.HintBench
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Data.List            ( intercalate )
import qualified Data.Set             as Set
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           System.Exit          ( exitFailure )
import           System.IO            ( hPutStrLn, stderr )
import           Text.Read            ( readMaybe )

import qualified Data.Aeson           as A
import qualified Data.Aeson.Key       as AK
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Schema     ( Definition )
import           AgdaGraph.Index      ( Index(..), defAt )
import           AgdaGraph.LemmaRank  ( RankEnv, mkRankEnv )
import           AgdaGraph.PremiseBench

import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, showD3
                                         , emitJsonReport, withHumanOutput
                                         , withHumanReport )

-- ---------------------------------------------------------------------------
-- Options

-- | User-facing knobs. See module header for the semantics.
data Options = Options
  { optStrategy  :: !Text
    -- ^ Strategy name to score, or @"all"@ for every registered strategy.
  , optCutoffs   :: ![Int]
    -- ^ Recall\/any-hit cutoffs; parsed + validated by the @--k@ flag
    -- (ascending, deduplicated).
  , optMinSim    :: !Double
    -- ^ Coverage floor for the ranker (mirrors the @auto@ hint path's 0.4).
  , optDropCtors :: !Bool
    -- ^ Drop constructor \/ record premises from the ground truth.
  , optKnnK      :: !Int
    -- ^ Phase-2 k-NN neighbourhood size (@knn@ \/ @blend@ strategies).
  , optKnnAlpha  :: !Double
    -- ^ Phase-2 blend weight (@blend@ strategy): @α·knn + (1-α)·lexical@.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optStrategy  = "baseline"
  , optCutoffs   = [3, 6, 10]
  , optMinSim    = 0.4
  , optDropCtors = True
  , optKnnK      = 32
  , optKnnAlpha  = 0.5
  }

-- | Declarative flag spec; drives 'parseOptions', 'applyConfig', and the
-- @--help@ block. Help lines are verbatim in 'AgdaOptimization.CLI.subFlags'.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ TextFlag "strategy" "--strategy=NAME  ranking strategy to score, or 'all' (default baseline)"
      (\t o -> o { optStrategy = t })
  , EnumFlag "k" "--k=N[,N...]     recall/any-hit cutoffs (default 3,6,10)"
      parseCutoffs EnumWrapped (\ks o -> o { optCutoffs = ks })
  , DblFlag "min-sim" "--min-sim=F      ranker coverage floor (default 0.4, the auto hint path)"
      (\x o -> o { optMinSim = x })
  , SwitchFlag "keep-ctors" "--keep-ctors     keep constructor/record premises in the ground truth"
      SwitchPreGuard (\o -> o { optDropCtors = False })
      (Just "keep-ctors") (\v o -> o { optDropCtors = not v })
  , IntFlag "knn-k" "--knn-k=N        Phase-2 k-NN neighbourhood size (default 32)"
      (\n o -> o { optKnnK = n })
  , DblFlag "knn-alpha" "--knn-alpha=F    Phase-2 blend weight α·knn+(1-α)·lexical (default 0.5)"
      (\x o -> o { optKnnAlpha = x })
  ]

-- | Hand-rolled CLI parser for the @hint-bench@ subcommand.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "hint-bench" flagSpecs

-- | Overlay the @hint-bench:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "hint-bench" flagSpecs obj o0

-- ---------------------------------------------------------------------------
-- Entry

-- | Build the corpus, score the selected strategies, and emit the report.
-- @--k@ is validated by the parser, so 'run' has a ready 'optCutoffs'.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = do
  let benchOpts = BenchOpts
        { boCutoffs   = optCutoffs
        , boMinSim    = optMinSim
        , boDropCtors = optDropCtors
        , boKnnK      = optKnnK
        , boKnnAlpha  = optKnnAlpha
        }
      !rows = benchRows ix benchOpts

  case rows of
    [] -> emitEmpty gOpts opts (noRowReason ix rows)
    _  -> do
      -- Build the ranker corpus only when there are rows to rank. The IDF map
      -- is per-strategy (built in 'strategyRegistry'), so the base env is empty;
      -- the rows double as the k-NN training corpus (Phase 2).
      strats <- resolveStrategies optStrategy rows (mkRankEnv (realDefsOf ix) mempty) benchOpts
      let reports = map (\s -> scoreStrategy benchOpts s rows) strats
      case gOutFormat gOpts of
        OutJson  -> emitJsonReport (gOutPath gOpts)
                      (hintBenchJson opts (length rows) Nothing reports)
        OutHuman -> withHumanReport gOpts "hint-bench"
                      (emitHuman opts (length rows) reports)

-- | The real (non-synthetic) defs, in id order — the ranker's corpus.
realDefsOf :: Index -> [Definition]
realDefsOf ix = [ defAt ix i | i <- [0 .. idxRealCount ix - 1] ]

-- | Resolve @--strategy@ to the concrete strategies, or exit with the
-- list of available names. @rows@ double as the k-NN training corpus.
resolveStrategies :: Text -> [BenchRow] -> RankEnv -> BenchOpts -> IO [Strategy]
resolveStrategies name rows env opts
  | name == "all" = pure (strategyRegistry rows env opts)
  | otherwise = case lookupStrategy name rows env opts of
      Just s  -> pure [s]
      Nothing -> do
        hPutStrLn stderr $
          "hint-bench: unknown strategy: " ++ T.unpack name
          ++ " (available: " ++ intercalate ", " (map T.unpack strategyNames)
          ++ ", or 'all')"
        exitFailure

-- | Parse a comma-separated list of positive cutoffs, ascending and
-- deduplicated. Blanks are skipped; an empty\/all-blank list, a
-- non-integer, or a non-positive value is an error. Shape matches
-- 'AgdaOptimization.FlagSpec.EnumFlag' (the @--k@ flag validates on both
-- the argv and YAML paths through it), so the messages omit the @--k:@
-- prefix that 'EnumWrapped' adds.
parseCutoffs :: String -> Either String [Int]
parseCutoffs raw =
  case mapM readOne toks of
    Nothing -> Left ("expected a comma-separated list of positive integers, got "
                       ++ show raw)
    Just [] -> Left "needs at least one cutoff"
    Just ks -> Right (Set.toAscList (Set.fromList ks))
  where
    toks = filter (not . null) (map (T.unpack . T.strip) (T.splitOn "," (T.pack raw)))
    readOne t = case readMaybe t of
      Just n | n > 0 -> Just n
      _              -> Nothing

-- ---------------------------------------------------------------------------
-- Human rendering

emitHuman :: Options -> Int -> [BenchReport] -> IO ()
emitHuman Options{..} nRows reports = do
  putStrLn $ "# hint-bench — leave-one-out premise-selection recall"
  putStrLn $ "  corpus rows   : " ++ show nRows
  putStrLn $ "  min-sim floor : " ++ showD3 optMinSim
  putStrLn $ "  premise set   : " ++ (if optDropCtors then "constructors/records dropped"
                                                       else "all body-provenance targets")
  putStrLn $ "  cutoffs (k)   : " ++ intercalate ", " (map show optCutoffs)
  putStrLn ""
  let header = ["Strategy"]
                 ++ [ "R@" ++ show k | k <- optCutoffs ]
                 ++ [ "A@" ++ show k | k <- optCutoffs ]
                 ++ ["MRR", "|cand|"]
      row r  = [ T.unpack (brpStrategy r) ]
                 ++ [ showD3 v | (_, v) <- brpRecallAt r ]
                 ++ [ showD3 v | (_, v) <- brpAnyHitAt r ]
                 ++ [ showD3 (brpMRR r), showD3 (brpMeanCand r) ]
  -- R@k / A@k / MRR are glossed in 'AgdaOptimization.Legend' with the rest
  -- of the column glossary, so the metrics are described in one place.
  putStr (renderTable header (map row reports))

-- | The empty-corpus report: state the reason and stop, exit 0.
emitEmpty :: GlobalOpts -> Options -> Maybe Text -> IO ()
emitEmpty gOpts opts mReason =
  case gOutFormat gOpts of
    OutJson  -> emitJsonReport (gOutPath gOpts)
                  (hintBenchJson opts 0 mReason [])
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn "# hint-bench — leave-one-out premise-selection recall"
      putStrLn "  corpus rows   : 0"
      putStrLn $ "  note          : " ++ maybe "no rows" T.unpack mReason

-- ---------------------------------------------------------------------------
-- JSON rendering

hintBenchJson :: Options -> Int -> Maybe Text -> [BenchReport] -> A.Value
hintBenchJson Options{..} nRows mReason reports =
  A.object
    [ "subcommand" .= ("hint-bench" :: Text)
    , "options"    .= A.object
        [ "strategy"   .= optStrategy
        , "cutoffs"    .= optCutoffs
        , "min_sim"    .= optMinSim
        , "drop_ctors" .= optDropCtors
        ]
    , "stats"      .= A.object
        ([ "rows" .= nRows ]
           ++ [ "note" .= r | Just r <- [mReason] ])
    , "strategies" .= A.toJSON (map reportJson reports)
    ]

reportJson :: BenchReport -> A.Value
reportJson r =
  A.object
    [ "strategy"  .= brpStrategy r
    , "rows"      .= brpRows r
    , "recall_at" .= atObject (brpRecallAt r)
    , "any_hit_at".= atObject (brpAnyHitAt r)
    , "mrr"       .= brpMRR r
    , "mean_cand" .= brpMeanCand r
    ]
  where
    -- keyed by the cutoff rendered as a string, so downstream tools can
    -- route on "3"/"6"/"10" without positional coupling.
    atObject :: [(Int, Double)] -> A.Value
    atObject = A.object . map (\(k, v) -> AK.fromString (show k) .= v)
