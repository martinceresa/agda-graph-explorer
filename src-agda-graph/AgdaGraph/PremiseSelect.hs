{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Dependency-informed premise selection (Phase 2), MaSh/CoqHammer-style.
--
-- The Phase-1 lexical ranker asks "which library definition's /signature/
-- looks like the goal?". This module asks a different question: "which
-- proved /theorems/ look like the goal, and what premises did /their/ proofs
-- use?". The body-provenance edges are the training labels — every proved
-- theorem @n@ is a row @(F(n), B(n))@ of feature bag + premise set, and a
-- goal's premises are voted for by its nearest neighbours' premise sets. This
-- is an entirely different signal from lexical coverage (it can surface a
-- premise whose /own/ signature shares nothing with the goal, purely because
-- similar theorems reached for it), so it is blended with the lexical score
-- rather than replacing it.
--
-- The scoring core ('premiseVotes' / 'blendScores' / 'buildCorpus' /
-- 'featuresOf' / 'alphaFor') is pure over a generic 'Corpus' its caller
-- assembles — it knows nothing of the bench row type, so there is no import
-- cycle with @AgdaGraph.PremiseBench@ (which builds the corpus from its rows).
-- Two thin adapters ('bodyPremises' / 'corpusRowsFromIndex') do read an
-- 'AgdaGraph.Index' so the daemon and bench build the corpus (and its premise
-- labels) from one shared definition of @B(d)@.
--
-- __Determinism.__ Every step is a stable sort or an order-fixed
-- 'Map.fromListWith' fold over a deterministic list, so votes/blends are
-- identical across RTS core counts (the repo-wide acceptance test).
module AgdaGraph.PremiseSelect
  ( -- * Corpus
    CorpusRow(..)
  , Corpus(..)
  , buildCorpus
  , featuresOf
  , bodyPremises
  , provedRows
  , corpusRowsFromIndex

    -- * Voting + blending
  , premiseVotes
  , blendScores
  , alphaFor
  ) where

import           Control.DeepSeq  ( NFData(..) )
import           Data.List        ( sortBy )
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict  as Map
import           Data.Map.Strict  ( Map )
import           Data.Maybe       ( isJust )
import           Data.Ord         ( Down(..), comparing )
import           Data.Set         ( Set )
import qualified Data.Set         as Set
import           Data.Text        ( Text )

import           AgdaGraph.GoalCanon ( goalFeatures, weightedCoverageIdf, idfOf )
import           AgdaGraph.Schema    ( Definition(..), Kind(..), Provenance(..)
                                     , State(..) )
import           AgdaGraph.Index     ( Index(..), defAt )

-- | One proved theorem as a training row: its node key, the feature bag of
-- its signature ('featuresOf'), and its body-provenance premise set.
data CorpusRow = CorpusRow
  { crName     :: !Text
  , crFeatures :: !(Set Text)
  , crPremises :: !(Set Text)
  }

instance NFData CorpusRow where
  rnf (CorpusRow a b c) = rnf a `seq` rnf b `seq` rnf c

-- | The assembled training corpus: the rows, the two IDF maps voting uses
-- (token IDF — weights neighbour-similarity, shared with the Phase-1a ranker;
-- premise IDF — down-weights a premise reached for by /every/ proof, like
-- @refl@\/@cong@), and the base-name vocabulary the features were built with
-- (cached so a query's goal features use the __same__ vocab as the corpus, and
-- 'featuresOf' need not rebuild it per query).
data Corpus = Corpus
  { cRows       :: ![CorpusRow]
  , cVocab      :: !(Set Text)
  , cTokenIdf   :: !(Map Text Double)
  , cPremiseIdf :: !(Map Text Double)
  }

instance NFData Corpus where
  rnf (Corpus a b c d) = rnf a `seq` rnf b `seq` rnf c `seq` rnf d

-- | Assemble a 'Corpus' from its rows, the vocabulary and token-IDF the caller
-- built the features with (so similarity lines up with the lexical ranker and
-- a query's features match). The premise-IDF is derived here via 'idfOf' over
-- the rows' premise sets.
buildCorpus :: Set Text -> Map Text Double -> [CorpusRow] -> Corpus
buildCorpus vocab tokenIdf rows = Corpus
  { cRows       = rows
  , cVocab      = vocab
  , cTokenIdf   = tokenIdf
  , cPremiseIdf = idfOf (map crPremises rows)
  }

-- | The feature bag of a (goal or signature) string, via the shared
-- 'goalFeatures' (conclusion match-tokens ∪ algebraic shape). @vocab@ selects
-- which lowercase identifiers to keep; passing 'cVocab' keeps a query's goal
-- features consistent with the corpus rows'.
featuresOf :: Set Text -> Text -> Set Text
featuresOf vocab = goalFeatures (`Set.member` vocab)

-- | @B(d)@ for the real def with id @i@: its 'ProvBody' edge targets that are
-- 'Defined', signature-carrying defs (constructors / records dropped when the
-- flag is set — Mimer builds those for free, so they are noise as premise
-- recommendations). Empty when the graph carries no edge provenance. The one
-- premise definition shared by the bench corpus ('AgdaGraph.PremiseBench') and
-- the daemon corpus ('corpusRowsFromIndex'), so training labels never diverge.
bodyPremises :: Bool -> Index -> Int -> Set Text
bodyPremises dropCtors ix i = case idxEdgeProvenance ix of
  Nothing   -> Set.empty
  Just prov -> Set.fromList
    [ defName t
    | (tid, ProvBody) <- IM.toList (IM.findWithDefault IM.empty i prov)
    , tid /= i
    , let t = defAt ix tid
    , defState t == Defined
    , isJust (defSig t)
    , not (dropCtors && defKind t `elem` [KConstructor, KRecord]) ]

-- | The single scan behind a training row: every real def that is 'Defined',
-- signature-carrying, and has a non-empty body-premise set, as
-- @(name, signature, premises)@. Shared by the daemon corpus
-- ('corpusRowsFromIndex') and the offline bench rows
-- ('AgdaGraph.PremiseBench.benchRows') so "a training row" has one definition.
provedRows :: Bool -> Index -> [(Text, Text, Set Text)]
provedRows dropCtors ix =
  [ (defName d, sig, prems)
  | i <- [0 .. idxRealCount ix - 1]
  , let d = defAt ix i
  , defState d == Defined
  , Just sig <- [defSig d]
  , let prems = bodyPremises dropCtors ix i
  , not (Set.null prems) ]

-- | The k-NN training rows straight off an 'Index' (the daemon path): one
-- 'CorpusRow' per 'provedRows' entry. @vocab@ is the base-name vocabulary for
-- 'featuresOf' (see 'AgdaGraph.LemmaRank.envVocab').
corpusRowsFromIndex :: Bool -> Set Text -> Index -> [CorpusRow]
corpusRowsFromIndex dropCtors vocab ix =
  [ CorpusRow nm (featuresOf vocab sig) prems
  | (nm, sig, prems) <- provedRows dropCtors ix ]

-- | Premise votes for a goal: rank the corpus rows by similarity to the goal
-- features, keep the top @k@ neighbours (those the @keepRow@ predicate admits
-- — leave-one-out hides the goal's own theorem), and accumulate
-- @score(p) += sim(n) · idf(p)@ over each neighbour's premises. A premise
-- reached for by many similar proofs, discounted by how common it is
-- library-wide, scores highest.
premiseVotes :: Int -> Corpus -> (Text -> Bool) -> Set Text -> Map Text Double
premiseVotes k Corpus{..} keepRow fgoal =
  Map.fromListWith (+)
    [ (p, sim * Map.findWithDefault 1.0 p cPremiseIdf)
    | (sim, prems) <- topK
    , p <- Set.toList prems ]
  where
    sims = [ (sim, crPremises r)
           | r <- cRows, keepRow (crName r)
           , let !sim = weightedCoverageIdf cTokenIdf fgoal (crFeatures r)
           , sim > 0 ]
    -- stable sort over a fixed list ⇒ deterministic top-k (ties keep corpus order).
    topK = take k (sortBy (comparing (Down . fst)) sims)

-- | Blend two per-candidate score maps into @α · knn + (1-α) · lexical@, each
-- min-max normalised to @[0,1]@ over its own values first (so the two signals
-- are comparable regardless of raw scale). A candidate present in only one map
-- contributes 0 from the other.
blendScores :: Double -> Map Text Double -> Map Text Double -> Map Text Double
blendScores alpha knn lexical =
  Map.fromSet
    (\c -> alpha * get nk c + (1 - alpha) * get nl c)
    (Set.union (Map.keysSet knn) (Map.keysSet lexical))
  where
    nk = minmax knn
    nl = minmax lexical
    get m c = Map.findWithDefault 0 c m

-- | Min-max normalise a map's values to @[0,1]@. An empty map is unchanged;
-- an all-equal map maps every value to 1 (no discrimination, but present).
minmax :: Map Text Double -> Map Text Double
minmax m
  | Map.null m = m
  | hi <= lo   = Map.map (const 1) m
  | otherwise  = Map.map (\v -> (v - lo) / (hi - lo)) m
  where
    -- Lazy on purpose: lo/hi are forced only past the Map.null guard, so
    -- minimum/maximum never see the empty list.
    vs = Map.elems m
    lo = minimum vs
    hi = maximum vs

-- | The blend weight for a corpus of @n@ rows: 0 (pure lexical) below a
-- minimum corpus size, else the caller's base @α@. k-NN needs a populated
-- training corpus to say anything, so on a young or provenance-less graph it
-- degrades to today's lexical ranking.
alphaFor :: Int -> Double -> Double
alphaFor n base
  | n < minCorpus = 0
  | otherwise     = base
  where minCorpus = 50
