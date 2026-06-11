{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Silhouette — type-signature topology vs. body topology.
--
-- When 'agda-deps' tags every edge with a 'Provenance', we can split a
-- definition's outgoing edges into the /signature subgraph/ (edges
-- sourced from the def's type — 'ProvSignature') and the /body
-- subgraph/ (everything else — 'ProvBody', 'ProvWhere', 'ProvWith',
-- 'ProvUnknown'). Running Weisfeiler-Lehman fingerprinting independently
-- on each subgraph lets us answer two distinct questions:
--
--   * /Do two defs have the same shape of statement?/ — equal signature
--     fingerprint = "structural twins". The lemmas declare the same
--     thing modulo names.
--   * /Do two defs prove that statement the same way?/ — body
--     fingerprint overlap (weighted Jaccard).
--
-- The interesting silhouette signals are then:
--
--   * **Structural twins with high body overlap** (Jaccard ≥
--     'optHighOverlap') — both the statement and the proof are nearly
--     identical: extract a combinator.
--   * **Structural twins with disjoint bodies** (Jaccard <
--     'optLowOverlap') — same statement, different proofs: a
--     re-proved lemma, candidate for unification.
--
-- When the producer hasn't emitted edge provenance (older JSON;
-- 'idxEdgeProvenance' is 'Nothing') we degrade to running WL on
-- 'idxForward' only and emit one cluster set as "body twins" with no
-- signature/body split, after a clear stderr warning.
--
-- WL hashing, weighted Jaccard, and tag codes are copied verbatim from
-- 'AgdaOptimization.Fingerprint'. Keeping the hash mixer and tag codes
-- bit-identical means a Silhouette body fingerprint and a Fingerprint
-- body-only run produce the same colour histograms.
module AgdaOptimization.Silhouette
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad        ( forM_, when )
import           Data.Foldable        ( foldl' )
import           Data.List            ( sortBy, tails )
import qualified Data.Map.Strict      as Map
import           Data.Map.Strict      ( Map )
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           Data.Vector          ( Vector )
import           System.IO            ( hPutStrLn, stderr )
import           Text.Printf          ( printf )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), defAt )
import           AgdaGraph.Schema     ( Definition(..), Kind(..), State(..) )
import           Data.Text            ( Text )

import           AgdaOptimization.FlagSpec ( FlagSpec(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaGraph.WL         ( Fingerprint, weightedJaccard )
import           AgdaGraph.Similarity ( SigBodyFingerprints(..)
                                      , buildSigBodyFingerprints, fingerprintSize )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , emitJsonReport, withHumanOutput )

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

-- | Tunables for the silhouette analysis. All fields strict; numeric
-- defaults are documented at the field.
data Options = Options
  { optWlK            :: !Int
    -- ^ WL refinement depth, applied to both subgraphs. Default 2 —
    --   plenty of discrimination on Agda-shaped graphs.
  , optMinSize        :: !Int
    -- ^ Minimum candidate signature-subtree size. Filters trivial defs
    --   that would otherwise generate degenerate twin clusters of
    --   nullary primitives.
  , optTopN           :: !Int
    -- ^ Maximum number of structural-twin clusters reported.
  , optMinClusterSize :: !Int
    -- ^ Minimum number of members for a twin cluster to be reported.
  , optHighOverlap    :: !Double
    -- ^ Body Jaccard at/above this is a combinator candidate.
  , optLowOverlap     :: !Double
    -- ^ Body Jaccard below this is a copy-paste candidate.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optWlK            = 2
  , optMinSize        = 3
  , optTopN           = 50
  , optMinClusterSize = 2
  , optHighOverlap    = 0.5
  , optLowOverlap     = 0.2
  }

-- | Declarative flag spec for the @silhouette@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "wl-k" "--wl-k=N              WL refinement depth (default 2)"
      (\n o -> o { optWlK = n })
  , IntFlag "min-size" "--min-size=N          min candidate subtree size (default 3)"
      (\n o -> o { optMinSize = n })
  , IntFlag "min-cluster-size" "--min-cluster-size=N  min twin-cluster size (default 2)"
      (\n o -> o { optMinClusterSize = n })
  , DblFlag "high-overlap" "--high-overlap=F      combinator-candidate threshold (default 0.5)"
      (\x o -> o { optHighOverlap = x })
  , DblFlag "low-overlap" "--low-overlap=F       copy-paste-reproof threshold (default 0.2)"
      (\x o -> o { optLowOverlap = x })
  , IntFlag "top-n" "--top-n=N             clusters to keep (default 50)"
      (\n o -> o { optTopN = n })
  ]

-- | Hand-rolled CLI parser for the @silhouette@ subcommand. Shape mirrors
-- 'AgdaOptimization.Fingerprint.parseOptions'.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "silhouette" flagSpecs

-- | Overlay the @silhouette:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "silhouette" flagSpecs obj o0

--------------------------------------------------------------------------------
-- Candidate selection + cluster types
--
-- The signature/body adjacency split, WL refinement, rooted subtrees and
-- per-node fingerprints now come from "AgdaGraph.Similarity"
-- ('buildSigBodyFingerprints') — the same core "AgdaMcp" reuses for the
-- @similar_types@ point query, so a daemon pairwise hit and a batch
-- structural-twin cluster agree by construction.
--------------------------------------------------------------------------------

-- | A candidate carries its node id, signature subtree size (for
-- diagnostics + ranking), and both fingerprints. The body subtree
-- itself isn't retained — only its colour histogram matters downstream.
data Cand = Cand
  { cId      :: !Int
  , cSigSize :: !Int
  , cSigFp   :: !Fingerprint
  , cBodyFp  :: !Fingerprint
  }

-- | Build candidates from the precomputed signature/body fingerprints.
-- Filter rules:
--
--   * Skip 'KOther' nodes (synthetic / unknown shape).
--   * Skip when the signature subtree is smaller than 'optMinSize' —
--     trivial signatures (nullary types, leaves) generate noisy
--     same-shape clusters. The subtree size is read back from the
--     fingerprint ('fingerprintSize'), which sums to the node count.
--
-- The body fingerprint is carried for every surviving candidate so
-- structural twins always have a body number to compare against.
candidates :: Index -> SigBodyFingerprints -> Options -> [Cand]
candidates ix sf Options{..} =
  let n = idxNodeCount ix
      mk i =
        let d = defAt ix i
        in if defKind d == KOther
             then Nothing
             else
               let !sigFp   = sbfSig sf V.! i
                   !sigSize = fingerprintSize sigFp
               in if sigSize < optMinSize
                    then Nothing
                    else
                      let !bodyFp = sbfBody sf V.! i
                      in Just (Cand i sigSize sigFp bodyFp)
  in [ c | Just c <- [ mk i | i <- [0 .. n - 1] ] ]

--------------------------------------------------------------------------------
-- Cluster construction
--------------------------------------------------------------------------------

-- | Group candidates by exact signature-fingerprint equality.
-- 'IntMap Int' has 'Ord', so we can use it directly as a 'Map' key —
-- no lossy hash. Returns clusters of size at least 'optMinClusterSize',
-- as lists of candidate /indices/ (into the candidate vector).
signatureTwinClusters :: Vector Cand -> Int -> [[Int]]
signatureTwinClusters cs minSize =
  let n = V.length cs
      -- fromListWith preserves insertion order if we cons new onto old
      -- (so we get ascending candidate indices per bucket).
      buckets :: Map Fingerprint [Int]
      !buckets = foldl' step Map.empty [0 .. n - 1]
        where
          step !m i =
            let !fp = cSigFp (cs V.! i)
            in Map.insertWith
                 (\new old -> head new : old)  -- cons single new index
                 fp [i] m
      raw = map snd (Map.toAscList buckets)
      -- Buckets came out reverse-of-insertion-order due to cons-prepend;
      -- reverse to get ascending candidate-index order, which then makes
      -- the JSON/human output deterministic.
      cleaned = map reverse raw
  in [ ks | ks <- cleaned, length ks >= minSize ]

-- | Tag for an individual body-overlap measurement between two
-- structural twins.
data OverlapTag = TagCombinator | TagCopyPaste | TagMixed
  deriving (Show, Eq)

overlapTag :: Options -> Double -> OverlapTag
overlapTag Options{..} s
  | s >= optHighOverlap = TagCombinator
  | s <  optLowOverlap  = TagCopyPaste
  | otherwise           = TagMixed

overlapTagLabel :: OverlapTag -> String
overlapTagLabel t = case t of
  TagCombinator -> "combinator"
  TagCopyPaste  -> "copy-paste"
  TagMixed      -> "mixed"

-- | Per-cluster summary: average body overlap across all pairs in the
-- cluster, and the dominant tag (the one assigned to ≥ half the pairs
-- by the per-pair tagging; ties break combinator > mixed > copy-paste).
data ClusterSummary = ClusterSummary
  { csAvgBodyOverlap :: !Double
  , csTag            :: !OverlapTag
  , csPairCount      :: !Int
    -- ^ Number of unordered pairs in the cluster (n*(n-1)/2).
  }

summariseCluster :: Options -> Vector Cand -> [Int] -> ClusterSummary
summariseCluster opts cs members =
  let pairs =
        [ (i, j)
        | (i:rest) <- tails members
        , j <- rest
        ]
      sims = [ weightedJaccard (cBodyFp (cs V.! i)) (cBodyFp (cs V.! j))
             | (i, j) <- pairs ]
      !nPairs = length pairs
      !sumSim = sum sims
      !avg = if nPairs == 0 then 0 else sumSim / fromIntegral nPairs
      tags = map (overlapTag opts) sims
      !tag = dominantTag tags
  in ClusterSummary
       { csAvgBodyOverlap = avg
       , csTag            = tag
       , csPairCount      = nPairs
       }

-- | Pick the dominant tag in a list. Counts each tag; on tie, prefer
-- combinator > mixed > copy-paste. Empty list => 'TagMixed' (the
-- 1-member cluster degenerate case; callers should never hit it because
-- 'optMinClusterSize' is at least 2 by default).
dominantTag :: [OverlapTag] -> OverlapTag
dominantTag [] = TagMixed
dominantTag ts =
  let !nCom = length (filter (== TagCombinator) ts)
      !nCp  = length (filter (== TagCopyPaste)  ts)
      !nMix = length (filter (== TagMixed)      ts)
      best = maximumByTiebreak
        [ (TagCombinator, nCom)
        , (TagMixed,      nMix)
        , (TagCopyPaste,  nCp)
        ]
  in fst best

-- | maximum-by-count with the supplied list order as the tiebreak.
maximumByTiebreak :: [(OverlapTag, Int)] -> (OverlapTag, Int)
maximumByTiebreak = foldl1Strict pick
  where
    pick acc@(_, !aN) cur@(_, !cN)
      | cN > aN   = cur
      | otherwise = acc

foldl1Strict :: (a -> a -> a) -> [a] -> a
foldl1Strict _ []     = error "foldl1Strict: empty list"
foldl1Strict f (x:xs) = foldl' f x xs

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- | Run the analysis. 'Index' is the caller's responsibility (parser at
-- the CLI layer). Never throws.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts =
  let !sf = buildSigBodyFingerprints (optWlK opts) ix
  in if sbfHasProvenance sf
       then runProvenance ix gOpts opts sf
       else do
         hPutStrLn stderr $
           "[silhouette] no edge-provenance data in graph.json (producer "
           ++ "did not tag edges); analysis degrades to "
           ++ "fingerprint-equivalent over all edges. Re-run agda-deps "
           ++ "with provenance tagging when available."
         runFallback ix gOpts opts sf

----------------------------------------------------------------------
-- Provenance-aware path.

runProvenance :: Index -> GlobalOpts -> Options -> SigBodyFingerprints -> IO ()
runProvenance ix gOpts opts@Options{..} sf = do
  let !cands     = candidates ix sf opts
      !candVec   = V.fromList cands
      !nCand     = V.length candVec

      !rawClusters = signatureTwinClusters candVec optMinClusterSize
      !summarised  =
        [ (c, summariseCluster opts candVec c) | c <- rawClusters ]
      -- Rank: combinator > copy-paste > mixed; secondary key is cluster
      -- size desc; tertiary is average overlap (combinator: high first;
      -- copy-paste: low first; mixed: high first as a sensible default).
      !ranked = sortBy clusterRankCmp summarised
      !topClusters = take (max 0 optTopN) ranked
      !nClus      = length ranked

      !nCombinator = length [ () | (_, s) <- ranked, csTag s == TagCombinator ]
      !nCopyPaste  = length [ () | (_, s) <- ranked, csTag s == TagCopyPaste  ]
      !nMixed      = length [ () | (_, s) <- ranked, csTag s == TagMixed      ]

  let !sigEdgeCount  = sbfSigEdges sf
      !bodyEdgeCount = sbfBodyEdges sf

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        silhouetteJson ix opts candVec nCand sigEdgeCount bodyEdgeCount
                       nClus nCombinator nCopyPaste nMixed topClusters
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn $ "# Silhouette — type-signature topology"
              ++ " (wl-k=" ++ show optWlK
              ++ ", min-size=" ++ show optMinSize
              ++ ", min-cluster-size=" ++ show optMinClusterSize
              ++ ", high-overlap=" ++ printf "%.2f" optHighOverlap
              ++ ", low-overlap="  ++ printf "%.2f" optLowOverlap
              ++ ", top-n=" ++ show optTopN
              ++ ")"
      putStrLn ""
      putStrLn $ "candidates considered : " ++ show nCand
      putStrLn $ "signature edges       : " ++ show sigEdgeCount
      putStrLn $ "body edges            : " ++ show bodyEdgeCount
      putStrLn $ "structural-twin clusters: " ++ show nClus
      putStrLn $ "  combinator candidates : " ++ show nCombinator
      putStrLn $ "  copy-paste candidates : " ++ show nCopyPaste
      putStrLn $ "  mixed                 : " ++ show nMixed
      putStrLn ""
      if null topClusters
        then putStrLn "no structural-twin clusters at these parameters."
        else
          forM_ (zip [1 :: Int ..] topClusters) $ \(rank, (members, cs)) ->
            renderCluster ix candVec rank members cs

-- | Sort key for the cluster output. Combinator-tagged clusters first
-- (most actionable), then copy-paste, then mixed. Within a tag, larger
-- clusters first; within size, higher avg body overlap first for
-- combinator/mixed and lower first for copy-paste (the actionable
-- direction in each case).
clusterRankCmp
  :: ([Int], ClusterSummary)
  -> ([Int], ClusterSummary)
  -> Ordering
clusterRankCmp (ma, sa) (mb, sb) =
  let tagPri t = case t of
        TagCombinator -> (0 :: Int)
        TagCopyPaste  -> 1
        TagMixed      -> 2
      sizeKey c = Down (length c)
      overlapKey t v = case t of
        TagCopyPaste -> v          -- low overlap is more actionable
        _            -> negate v   -- high overlap is more actionable
  in comparing (\(c, s) -> ( tagPri (csTag s)
                           , sizeKey c
                           , overlapKey (csTag s) (csAvgBodyOverlap s) ))
       (ma, sa) (mb, sb)

renderCluster
  :: Index
  -> Vector Cand
  -> Int
  -> [Int]
  -> ClusterSummary
  -> IO ()
renderCluster ix candVec rank members ClusterSummary{..} = do
  putStrLn $ "Cluster #" ++ show rank
          ++ " — " ++ show (length members) ++ " members"
          ++ ", body overlap " ++ printf "%.3f" csAvgBodyOverlap
          ++ " [" ++ overlapTagLabel csTag ++ "]"
  -- Sort members by signature subtree size desc for a tidy printout.
  let sortedMembers =
        sortBy (comparing (Down . cSigSize . (candVec V.!))) members
  forM_ sortedMembers $ \memIdx -> do
    let c   = candVec V.! memIdx
        d   = defAt ix (cId c)
    putStrLn $ "  - " ++ T.unpack (defName d)
            ++ " (" ++ T.unpack (defModule d) ++ ")"
            ++ " [" ++ stateLabel (defState d) ++ "]"
            ++ "  sig-size=" ++ show (cSigSize c)
  case csTag of
    TagCombinator ->
      putStrLn "    -> high body overlap; extract a shared combinator."
    TagCopyPaste  ->
      putStrLn "    -> disjoint bodies; copy-paste re-proof — consider unifying."
    TagMixed      ->
      putStrLn "    -> partial body overlap; inspect for partial reuse."
  putStrLn ""

----------------------------------------------------------------------
-- Fallback path: no provenance data.

-- | When 'idxEdgeProvenance' is 'Nothing' we still emit something
-- useful: run WL on the full forward graph and report exact
-- fingerprint-equality clusters as "body twins" (no signature/body
-- split possible).
runFallback :: Index -> GlobalOpts -> Options -> SigBodyFingerprints -> IO ()
runFallback ix gOpts opts@Options{..} sf = do
      -- 'sf' carries body == signature fingerprints over the full forward
      -- graph (the no-provenance case of 'buildSigBodyFingerprints'), so
      -- the candidate machinery reuses the regular skipped-on-size path.
  let !cands    = candidates ix sf opts
      !candVec  = V.fromList cands
      !nCand    = V.length candVec

      !rawClusters = signatureTwinClusters candVec optMinClusterSize
      -- No body/sig split; every cluster is "body twins" with avg
      -- overlap = 1.0 by construction (the fingerprints are equal),
      -- tagged 'TagCombinator' to reflect that the analyses would
      -- coincide if the producer tagged edges.
      !nClus    = length rawClusters
      !topClusters = take (max 0 optTopN)
                   $ sortBy (comparing (Down . length . fst))
                       [ (c, ClusterSummary 1.0 TagCombinator
                              (length c * (length c - 1) `div` 2))
                       | c <- rawClusters ]
      !edgeCount = sbfBodyEdges sf

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        silhouetteJson ix opts candVec nCand 0 edgeCount
                       nClus nClus 0 0 topClusters
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn $ "# Silhouette — type-signature topology (fallback, no provenance)"
              ++ " (wl-k=" ++ show optWlK
              ++ ", min-size=" ++ show optMinSize
              ++ ", min-cluster-size=" ++ show optMinClusterSize
              ++ ", top-n=" ++ show optTopN
              ++ ")"
      putStrLn ""
      putStrLn $ "candidates considered : " ++ show nCand
      putStrLn $ "edges (all)           : " ++ show edgeCount
      putStrLn $ "body-twin clusters    : " ++ show nClus
      putStrLn ""
      if null topClusters
        then putStrLn "no body-twin clusters at these parameters."
        else
          forM_ (zip [1 :: Int ..] topClusters) $ \(rank, (members, cs)) ->
            renderCluster ix candVec rank members cs
      when (not (null topClusters)) $
        putStrLn
          "note: signature/body split unavailable — analysis is over all edges."

----------------------------------------------------------------------
-- JSON rendering.

-- | Compact JSON shape. Per-cluster member list mirrors the human
-- output (sorted by sig-size desc); summary counters mirror the human
-- header.
silhouetteJson
  :: Index
  -> Options
  -> Vector Cand
  -> Int                   -- ^ candidates considered
  -> Int                   -- ^ signature edge count
  -> Int                   -- ^ body edge count
  -> Int                   -- ^ total structural-twin clusters
  -> Int                   -- ^ combinator candidates
  -> Int                   -- ^ copy-paste candidates
  -> Int                   -- ^ mixed
  -> [([Int], ClusterSummary)]
  -> A.Value
silhouetteJson ix opts candVec nCand sigEdges bodyEdges nClus
               nComb nCp nMix topClusters =
  A.object
    [ "subcommand" .= ("silhouette" :: Text)
    , "options"    .= silhouetteOptionsJson opts
    , "stats"      .= A.object
        [ "candidates_considered"     .= nCand
        , "signature_edges"           .= sigEdges
        , "body_edges"                .= bodyEdges
        , "structural_twin_clusters"  .= nClus
        , "combinator_candidates"     .= nComb
        , "copy_paste_candidates"     .= nCp
        , "mixed_candidates"          .= nMix
        ]
    , "clusters" .= A.toJSON
        (zipWith (clusterJson ix candVec) [1 :: Int ..] topClusters)
    ]

silhouetteOptionsJson :: Options -> A.Value
silhouetteOptionsJson Options{..} = A.object
  [ "wl_k"               .= optWlK
  , "min_size"           .= optMinSize
  , "top_n"              .= optTopN
  , "min_cluster_size"   .= optMinClusterSize
  , "high_overlap"       .= optHighOverlap
  , "low_overlap"        .= optLowOverlap
  ]

clusterJson
  :: Index
  -> Vector Cand
  -> Int
  -> ([Int], ClusterSummary)
  -> A.Value
clusterJson ix candVec rank (members, ClusterSummary{..}) =
  let sortedMembers =
        sortBy (comparing (Down . cSigSize . (candVec V.!))) members
      memberJson memIdx =
        let c  = candVec V.! memIdx
            d  = defAt ix (cId c)
        in A.object
             [ "qname"           .= defName d
             , "module"          .= defModule d
             , "state"           .= stateLabel (defState d)
             , "signature_size"  .= cSigSize c
             ]
  in A.object
       [ "cluster"          .= rank
       , "size"             .= length members
       , "tag"              .= overlapTagLabel csTag
       , "avg_body_overlap" .= csAvgBodyOverlap
       , "pair_count"       .= csPairCount
       , "members"          .= A.toJSON (map memberJson sortedMembers)
       ]

-- | Single-character label matching the producer's wire encoding.
stateLabel :: State -> String
stateLabel s = case s of
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"
