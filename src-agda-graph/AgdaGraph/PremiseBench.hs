{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Offline leave-one-out benchmark for the lemma ranker (@hint-bench@).
--
-- The dependency graph is its own benchmark. Every /proved/ theorem @d@
-- carries both a goal (its signature) and a ground-truth premise set —
-- the definitions its proof body actually used (the @body@-provenance
-- edges out of @d@). Leave-one-out: hide @d@, rank the rest of the
-- library against @d@'s signature, and score whether @d@'s real premises
-- surface near the top. That number — how often a real premise lands in
-- the top-k hint budget — is exactly what predicts whether seeding those
-- candidates as Mimer hints would let @auto@ close the goal, so a ranking
-- change can be judged offline before any live @agda@ run.
--
-- This is the shared, pure core (no @agda-explore@ / process dependency)
-- so both the @agda-optimization hint-bench@ subcommand and @test/Spec.hs@
-- can reach it. The CLI surface, flag parsing, and rendering live in
-- @AgdaOptimization.HintBench@.
--
-- A 'Strategy' is a name plus a @'BenchRow' -> ['Text']@ ranking function.
-- @baseline@ is today's 'rankLemmaCandidates'; Phase 1/2 ranking variants
-- register beside it in 'strategyRegistry' so they are scored on the same
-- rows by construction.
--
-- __Graceful degradation.__ A graph with no per-edge provenance
-- (@idxEdgeProvenance = Nothing@, i.e. legacy JSON) or no signatures
-- yields zero rows — 'benchRows' returns @[]@ and the caller reports the
-- empty corpus cleanly rather than crashing. 'noRowReason' classifies
-- which is the case.
--
-- __Determinism.__ Per-row scoring is a @parListChunk rdeepseq@ over a
-- fixed row list (order preserved) and the aggregation is a left fold in
-- that same order, so a report is byte-identical under @+RTS -N1@ and
-- @-NK@ — the repo-wide acceptance test.
module AgdaGraph.PremiseBench
  ( -- * Corpus
    BenchRow(..)
  , BenchOpts(..)
  , defaultBenchOpts
  , benchRows
  , noRowReason

    -- * Strategies
  , Strategy(..)
  , strategyRegistry
  , strategyNames
  , lookupStrategy

    -- * Scoring
  , BenchReport(..)
  , scoreStrategy
  ) where

import           Control.DeepSeq  ( NFData(..) )
import           Control.Parallel.Strategies ( parListChunk, rdeepseq, withStrategy )
import qualified Data.IntMap.Strict as IM
import           Data.Maybe       ( isJust )
import           Data.Set         ( Set )
import qualified Data.Set         as Set
import           Data.Text        ( Text )

import           AgdaGraph.Schema    ( Definition(..), Kind(..), Provenance(..)
                                     , State(..) )
import           AgdaGraph.Index     ( Index(..), defAt )
import           AgdaGraph.LemmaRank ( RankEnv(..), rankLemmaCandidates )

-- ---------------------------------------------------------------------
-- Corpus
-- ---------------------------------------------------------------------

-- | One leave-one-out benchmark row: a proved, signature-carrying
-- theorem plus its ground-truth premise set.
data BenchRow = BenchRow
  { brName     :: !Text        -- ^ The theorem's node key; excluded from its own candidate list.
  , brGoal     :: !Text        -- ^ Its signature — the goal text the ranker scores against.
  , brPremises :: !(Set Text)  -- ^ @B(d)@: node keys of the body-provenance premises kept (see 'benchRows').
  } deriving (Show, Eq)

instance NFData BenchRow where
  rnf (BenchRow a b c) = rnf a `seq` rnf b `seq` rnf c

-- | Knobs shared by corpus construction and scoring.
data BenchOpts = BenchOpts
  { boCutoffs   :: ![Int]
    -- ^ The @k@ values reported for recall@k / any-hit@k, ascending
    -- (e.g. @[3,6,10]@). Any-hit@6 is the headline predictor of an
    -- @auto@ success.
  , boMinSim    :: !Double
    -- ^ Coverage floor handed to 'rankLemmaCandidates'. Defaults to the
    -- @auto@/hint path's 0.4 so the bench mirrors deployment; a candidate
    -- below the floor is dropped before ranking (and so caps recall).
  , boDropCtors :: !Bool
    -- ^ Drop constructor / record premises from @B(d)@ — Mimer builds
    -- those for free, so they are noise in a lemma-recall measurement.
    -- Toggle off to measure the raw premise set.
  } deriving (Show)

defaultBenchOpts :: BenchOpts
defaultBenchOpts = BenchOpts
  { boCutoffs   = [3, 6, 10]
  , boMinSim    = 0.4
  , boDropCtors = True
  }

-- | The leave-one-out corpus for a graph. Empty when the graph carries no
-- edge provenance (legacy JSON) or no signatures — 'noRowReason' says which.
--
-- A row exists for each real def @d@ that is 'Defined' and signature-carrying
-- and whose kept premise set is non-empty. @B(d)@ collects the targets of
-- @d@'s 'ProvBody' edges (the definitions the /proof/ leaned on, as opposed
-- to the ones its type mentions) that are themselves 'Defined',
-- signature-carrying real defs — optionally minus constructors / records.
benchRows :: Index -> BenchOpts -> [BenchRow]
benchRows ix opts = case idxEdgeProvenance ix of
  Nothing   -> []
  Just prov ->
    [ BenchRow
        { brName     = defName d
        , brGoal     = sig
        , brPremises = prems
        }
    | i <- [0 .. idxRealCount ix - 1]
    , let d = defAt ix i
    , defState d == Defined
    , Just sig <- [defSig d]
    , let prems = premisesOf ix opts prov i
    , not (Set.null prems)
    ]

-- | @B(d)@ for the real def with id @i@: the 'ProvBody' edge targets that
-- are 'Defined', signature-carrying defs (constructors / records dropped
-- when 'boDropCtors'). Synthetic edge-only nodes never carry a signature,
-- so the signature guard already excludes them.
premisesOf :: Index -> BenchOpts -> IM.IntMap (IM.IntMap Provenance) -> Int -> Set Text
premisesOf ix BenchOpts{..} prov i =
  Set.fromList
    [ defName t
    | (tid, ProvBody) <- IM.toList (IM.findWithDefault IM.empty i prov)
    , let t = defAt ix tid
    , tid /= i
    , defState t == Defined
    , Just _ <- [defSig t]
    , not (boDropCtors && defKind t `elem` [KConstructor, KRecord])
    ]

-- | Human explanation of an empty corpus, for the CLI's clean exit.
-- Takes the already-computed rows (the caller holds them) rather than
-- rebuilding the corpus; 'Nothing' when it is non-empty. Classifying /why/
-- it is empty still inspects the 'Index'.
noRowReason :: Index -> [BenchRow] -> Maybe Text
noRowReason ix rows
  | not (null rows) = Nothing
  | idxEdgeProvenance ix == Nothing =
      Just "this graph carries no edge provenance (regenerate agda-deps with \
           \definition-edge provenance); premise ground truth is unavailable"
  | not (any hasSig realDefs) =
      Just "this graph carries no signatures (regenerate agda-deps with \
           \--with-signatures); the ranker has no goal text to score"
  | otherwise =
      Just "no proved, signature-carrying definition has a body-provenance \
           \premise that is itself a signature-carrying definition"
  where
    realDefs = [ defAt ix i | i <- [0 .. idxRealCount ix - 1] ]
    hasSig d = defState d == Defined && isJust (defSig d)

-- ---------------------------------------------------------------------
-- Strategies
-- ---------------------------------------------------------------------

-- | A ranking strategy under test: a stable name and a function that,
-- given a row, returns the ranked candidate node keys (best first). The
-- function closes over the corpus ('RankEnv') it ranks against.
data Strategy = Strategy
  { stratName :: !Text
  , stratRank :: BenchRow -> [Text]
  }

-- | The registered strategies for a graph. @baseline@ is the shipped
-- 'rankLemmaCandidates' (context-free, carrier-affinity tiebreak intact),
-- excluding the row's own theorem from its candidates. Phase 1/2 variants
-- append here.
strategyRegistry :: RankEnv -> BenchOpts -> [Strategy]
strategyRegistry env opts =
  [ Strategy "baseline" (baselineRank env (boMinSim opts)) ]

-- | Today's ranker as a strategy: rank every signature-carrying def
-- (bar @d@ itself) by 'rankLemmaCandidates' at the given coverage floor,
-- with no live context types.
baselineRank :: RankEnv -> Double -> BenchRow -> [Text]
baselineRank env minSim row =
  map (defName . snd)
      (rankLemmaCandidates env candKeep minSim (brGoal row) [])
  where
    candKeep d = defName d /= brName row

-- | The registered strategy names, for @--help@ / error listing. Strategy
-- names are env-independent, so a throwaway empty 'RankEnv' is enough to
-- enumerate them (keep it that way — a name that varied with the graph
-- would make this list silently wrong).
strategyNames :: [Text]
strategyNames = map stratName (strategyRegistry (RankEnv [] mempty) defaultBenchOpts)

-- | Resolve a strategy by name against a graph's registry.
lookupStrategy :: Text -> RankEnv -> BenchOpts -> Maybe Strategy
lookupStrategy nm env opts =
  case filter ((== nm) . stratName) (strategyRegistry env opts) of
    (s : _) -> Just s
    []      -> Nothing

-- ---------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------

-- | Aggregate metrics for one strategy over the whole corpus.
data BenchReport = BenchReport
  { brpStrategy :: !Text
  , brpRows     :: !Int
  , brpRecallAt :: ![(Int, Double)]
    -- ^ Mean recall@k: mean over rows of @|B(d) ∩ top-k| / |B(d)|@.
  , brpAnyHitAt :: ![(Int, Double)]
    -- ^ Any-hit@k: fraction of rows with at least one real premise in the top-k.
  , brpMRR      :: !Double
    -- ^ Mean reciprocal rank of the first real premise (0 for a row with none).
  , brpMeanCand :: !Double
    -- ^ Mean candidate-set size after the coverage floor (Phase 1b signal).
  } deriving (Show, Eq)

-- | Per-row score, forced before the parallel spark joins.
data RowScore = RowScore
  { rsRecall :: ![Double]  -- ^ recall@k, parallel to 'boCutoffs'.
  , rsAnyHit :: ![Bool]    -- ^ any-hit@k, parallel to 'boCutoffs'.
  , rsRR     :: !Double    -- ^ reciprocal rank of the first hit (0 if none).
  , rsCand   :: !Int       -- ^ candidate-set size.
  }

instance NFData RowScore where
  rnf (RowScore a b c d) = rnf a `seq` rnf b `seq` c `seq` d `seq` ()

-- | Score a strategy over the corpus. Per-row work is sparked
-- (order-preserving) and folded in list order, so the result is
-- deterministic across RTS core counts.
scoreStrategy :: BenchOpts -> Strategy -> [BenchRow] -> BenchReport
scoreStrategy opts strat rows =
  let !scores = withStrategy (parListChunk 32 rdeepseq)
                             (map (scoreRow opts strat) rows)
      n       = length rows
      cutoffs = boCutoffs opts
      zeros   = map (const 0) cutoffs
      !sumRecall = foldl' (zipWith (+)) zeros (map rsRecall scores)
      !sumAnyHit = foldl' (zipWith (+)) zeros
                     (map (map (\b -> if b then 1 else 0) . rsAnyHit) scores)
      !sumRR     = foldl' (+) 0 (map rsRR scores)
      !sumCand   = foldl' (+) 0 (map (fromIntegral . rsCand) scores) :: Double
      mean s | n == 0    = 0
             | otherwise = s / fromIntegral n
  in BenchReport
       { brpStrategy = stratName strat
       , brpRows     = n
       , brpRecallAt = zip cutoffs (map mean sumRecall)
       , brpAnyHitAt = zip cutoffs (map mean sumAnyHit)
       , brpMRR      = mean sumRR
       , brpMeanCand = mean sumCand
       }

-- | Score one row: rank its candidates, then read off recall / any-hit /
-- reciprocal-rank against the ground-truth premises. The ranked list has
-- distinct names, so counting set-membership hits among the top-k is the
-- recall numerator directly.
scoreRow :: BenchOpts -> Strategy -> BenchRow -> RowScore
scoreRow BenchOpts{..} strat row =
  RowScore
    { rsRecall = map recallAt boCutoffs
    , rsAnyHit = map anyHitAt boCutoffs
    , rsRR     = maybe 0 (\r -> 1 / fromIntegral r) firstRank
    , rsCand   = length ranked
    }
  where
    ranked   = stratRank strat row
    prem     = brPremises row
    premN    = Set.size prem
    hitFlags = map (`Set.member` prem) ranked
    firstRank = case [ i | (i, True) <- zip [1 :: Int ..] hitFlags ] of
                  (r : _) -> Just r
                  []      -> Nothing
    recallAt k
      | premN == 0 = 0
      | otherwise  = fromIntegral (length (filter id (take k hitFlags)))
                       / fromIntegral premN
    anyHitAt k = maybe False (<= k) firstRank
