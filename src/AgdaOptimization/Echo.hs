{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Echo — reverse-direction structural near-duplicate detection.
--
-- Echo is the dual of 'AgdaOptimization.Fingerprint': it runs the same
-- Weisfeiler-Lehman fingerprinting machinery but always over the
-- /reverse/ (incoming) edges of the dependency graph. Two defs land in
-- the same reverse cluster iff they ANSWER the same callers — useful
-- for spotting parallel "endpoints" of distinct call paths that
-- ultimately serve the same purpose.
--
-- The actionable signal is the /delta/ between the reverse-direction
-- clusters and the forward-direction clusters computed from the same
-- corpus:
--
--   * If a reverse cluster's members all share a single forward cluster,
--     the reverse cluster is redundant with the forward analysis.
--   * If a reverse cluster's members come from /many/ different forward
--     clusters, that's the interesting case: defs that look unrelated
--     from a callee perspective but converge from a caller perspective.
--
-- Reverse clusters are ranked by this "forward spread" descending.
--
-- 'optMaxClusterSpread' rejects reverse clusters whose
-- @forward-spread / cluster-size@ ratio is __below__ the threshold
-- (default 0.3): large reverse clusters that collapse to one or two
-- forward clusters are mostly noise w.r.t. the delta signal. Pass
-- @--max-cluster-spread=0@ to disable.
--
-- WL refinement, weighted-Jaccard, union-find and candidate selection come
-- from the shared 'AgdaGraph.WL' / 'AgdaOptimization.UnionFind' /
-- 'AgdaOptimization.Cluster' helpers, so forward fingerprints stay
-- byte-comparable across the analyses that use them.
module AgdaOptimization.Echo
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad        ( forM_ )
import           Control.DeepSeq             ( NFData(..) )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.List            ( sortBy )
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           Data.Vector          ( Vector )
import           Text.Printf          ( printf )
import           System.IO            ( hPutStrLn, stderr )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), defAt, descendants, ancestors )
import           AgdaGraph.Schema     ( Definition(..), Kind(..) )
import           Data.Text            ( Text )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.UnionFind ( UF, ufFind )
import           AgdaOptimization.Cluster ( SimEdge, bfsBoundedLayers, seededUF
                                          , clustersOfSize2, clusterAvgSim )
import           AgdaGraph.WL         ( ColorVec, Fingerprint, fingerprintAt
                                      , initialColors, refine, weightedJaccard )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , emitJsonReport, withHumanOutput )

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

-- | Configuration for the echo analysis. Mirror of
-- 'AgdaOptimization.Fingerprint.Options' minus the @--direction@ flag
-- (always Incoming for echo) plus @--delta-only@, @--top-n@ and
-- @--max-cluster-spread@.
data Options = Options
  { optWlK              :: !Int
    -- ^ Depth of WL refinement (applied to both forward and reverse).
  , optJaccardThreshold :: !Double
    -- ^ Lower bound on weighted-Jaccard similarity for cluster edges.
  , optMinSize          :: !Int
    -- ^ Minimum subtree size (incoming closure) for a candidate.
  , optWlDepth          :: !Int
    -- ^ Bound on per-candidate subtree radius. @0@ = unbounded.
  , optDeltaOnly        :: !Bool
    -- ^ Only emit reverse clusters whose forward spread is > 1.
  , optTopN             :: !Int
    -- ^ Maximum reverse clusters to render.
  , optMaxClusterSpread :: !Double
    -- ^ Reject reverse clusters whose @forward-spread / size@ ratio is
    --   __below__ this threshold.  A low ratio means a large reverse
    --   cluster of defs that share a single forward cluster — i.e. the
    --   reverse cluster is mostly noise w.r.t. the actionable
    --   delta-vs-forward signal.  Set to @0@ to disable the filter
    --   entirely (no rejection).  Applied AFTER the @--jaccard@
    --   similarity filter, BEFORE the @--top-n@ cap.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optWlK              = 2
  , optJaccardThreshold = 0.8
  , optMinSize          = 3
  , optWlDepth          = 0
  , optDeltaOnly        = False
  , optTopN             = 50
  , optMaxClusterSpread = 0.3
  }

-- | Declarative flag spec for the @echo@ subcommand. Drives both the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--delta-only@ is a 'SwitchRejectValue' switch: an attached @=value@
-- is a hard error @echo: --delta-only does not take a value@; its YAML
-- key is @delta-only@.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "wl-k" "--wl-k=N                  WL refinement depth (default 2)"
      (\n o -> o { optWlK = n })
  , DblFlag "jaccard" "--jaccard=F               weighted-Jaccard threshold (default 0.8)"
      (\x o -> o { optJaccardThreshold = x })
  , IntFlag "min-size" "--min-size=N              min candidate subtree size (default 3)"
      (\n o -> o { optMinSize = n })
  , IntFlag "wl-depth" "--wl-depth=N              per-candidate subtree hop bound; 0 = unbounded (default)"
      (\n o -> o { optWlDepth = n })
  , SwitchFlag "delta-only" "--delta-only              show only reverse clusters with forward-spread > 1"
      SwitchRejectValue (\o -> o { optDeltaOnly = True })
      (Just "delta-only") (\v o -> o { optDeltaOnly = v })
  , DblFlag "max-cluster-spread" "--max-cluster-spread=F    reject clusters with spread/size below this (default 0.3, 0 disables)"
      (\x o -> o { optMaxClusterSpread = x })
  , IntFlag "top-n" "--top-n=N                 rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  ]

-- | Hand-rolled CLI parser. Same shape as
-- 'AgdaOptimization.Fingerprint.parseOptions'.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "echo" flagSpecs

-- | Overlay the @echo:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "echo" flagSpecs obj o0

--------------------------------------------------------------------------------
-- WL adjacency (hashing, tags, refinement, fingerprints and union-find now
-- live in "AgdaGraph.WL" / "AgdaOptimization.UnionFind"). Echo runs
-- the refinement twice — once per direction — so it keeps its own 'Dir'.
--------------------------------------------------------------------------------

-- | Which adjacency map to follow. Echo runs the refinement twice: once
-- with 'idxForward' (for the reference forward clusters), once with
-- 'idxReverse' (the headline analysis).
data Dir = DForward | DReverse
  deriving (Show, Eq)

dirAdj :: Index -> Dir -> IM.IntMap IS.IntSet
dirAdj ix DForward = idxForward ix
dirAdj ix DReverse = idxReverse ix

neighboursOf :: Index -> Dir -> Int -> IS.IntSet
neighboursOf ix dir i = IM.findWithDefault IS.empty i (dirAdj ix dir)

-- | Rooted subtree under @dir@. @maxDepth <= 0@ uses the unbounded
-- closure (the library 'descendants' / 'ancestors'); otherwise BFS by
-- layers (the shared 'bfsBoundedLayers').
rootedSubtree :: Index -> Dir -> Int -> Int -> IS.IntSet
rootedSubtree ix dir maxDepth root
  | maxDepth <= 0 = case dir of
      DForward -> IS.insert root (descendants ix (IS.singleton root))
      DReverse -> IS.insert root (ancestors   ix (IS.singleton root))
  | otherwise = bfsBoundedLayers (neighboursOf ix dir) maxDepth root

--------------------------------------------------------------------------------
-- Candidate selection (adapted from Fingerprint.hs).
--
-- Candidates are chosen by /reverse/-subtree size: a def is a candidate
-- iff it has at least 'optMinSize' callers in its incoming closure and
-- isn't a KOther synthetic node. The forward-direction clusters are
-- computed over the same candidate set, so cluster-membership lookup is
-- a single Int compare per member.
--------------------------------------------------------------------------------

-- | A candidate carries its reverse-direction subtree (used to size /
-- rank cluster members) and both fingerprints. The forward subtree
-- itself isn't retained — we only need its colour histogram.
data Cand = Cand
  { cId          :: !Int
  , cRevSubtree  :: !IS.IntSet
  , cRevFp       :: !Fingerprint
  , cFwdFp       :: !Fingerprint
  }

instance NFData Cand where
  rnf (Cand i s r f) = rnf i `seq` rnf s `seq` rnf r `seq` rnf f

candidates :: Index -> ColorVec -> ColorVec -> Options -> [Cand]
candidates ix revColors fwdColors Options{..} =
  let n   = idxNodeCount ix
      mk i =
        let d = defAt ix i
        in if defKind d == KOther
             then Nothing
             else
               let !revSub  = rootedSubtree ix DReverse optWlDepth i
                   !size    = IS.size revSub
               in if size < optMinSize
                    then Nothing
                    else
                      let !fwdSub = rootedSubtree ix DForward optWlDepth i
                          !revFp  = fingerprintAt revColors revSub
                          !fwdFp  = fingerprintAt fwdColors fwdSub
                      in if IM.null revFp
                           then Nothing
                           else Just (Cand i revSub revFp fwdFp)
      -- Each candidate builds two independent per-node closures + colour
      -- histograms; spark them (order-preserving parMap → identical list).
  in [ c | Just c <- parMap rdeepseq mk [0 .. n - 1] ]

--------------------------------------------------------------------------------
-- Pair scoring
--------------------------------------------------------------------------------

-- | Score all O(N^2 / 2) pairs against the supplied fingerprint
-- selector. Parallelised per row via 'parMap rdeepseq', preserving the
-- iteration order of the sequential build for determinism.
scorePairs :: Double
           -> (Cand -> Fingerprint)
           -> Vector Cand
           -> [SimEdge]
scorePairs thr getFp cs =
  let !n = V.length cs
      perI :: Int -> [SimEdge]
      perI !i =
        let !ci = cs V.! i
            !fi = getFp ci
            go !j !acc
              | j >= n    = acc
              | otherwise =
                  let !cj = cs V.! j
                      !s  = weightedJaccard fi (getFp cj)
                      !acc' = if s >= thr then (i, j, s) : acc else acc
                  in go (j + 1) acc'
        in go (i + 1) []
      chunks = parMap rdeepseq perI [0 .. n - 1]
  in concat (reverse chunks)

-- | Per-candidate forward-cluster id. Two candidates share a cluster id
-- iff the union-find puts them in the same component.
fwdClusterIds :: Int -> UF -> V.Vector Int
fwdClusterIds n uf = V.generate n $ \i -> ufFind i uf

--------------------------------------------------------------------------------
-- Delta computation
--------------------------------------------------------------------------------

-- | For a reverse-cluster's members, count how many /distinct/ forward
-- clusters they come from. 1 = redundant with forward; >1 = actionable.
forwardSpread :: V.Vector Int -> [Int] -> Int
forwardSpread fwdIds members =
  IS.size $ foldl' (\acc i -> IS.insert (fwdIds V.! i) acc) IS.empty members

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- | Run the analysis. Computes forward and reverse fingerprints in
-- sequence (each WL step is internally parallelised), then ranks
-- reverse clusters by delta and emits either human or JSON output.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = do
  let -- WL refinement for both directions.
      !revC0    = initialColors ix (neighboursOf ix DReverse)
      !revCk    = refine ix (neighboursOf ix DReverse) optWlK revC0
      !fwdC0    = initialColors ix (neighboursOf ix DForward)
      !fwdCk    = refine ix (neighboursOf ix DForward) optWlK fwdC0

      !candList = candidates ix revCk fwdCk opts
      !candVec  = V.fromList candList
      !nCand    = V.length candVec

      -- Forward and reverse similarity edges.
      !revEdges = scorePairs optJaccardThreshold cRevFp candVec
      !fwdEdges = scorePairs optJaccardThreshold cFwdFp candVec

      -- Forward union-find (the reverse-cluster grouping goes straight
      -- through the shared 'clustersOfSize2'; the forward one we keep as
      -- a 'UF' for the per-candidate cluster-id lookup below).
      !fwdUF    = seededUF nCand fwdEdges

      -- Forward cluster id per candidate (a single Int).
      !fwdIds   = fwdClusterIds nCand fwdUF

      -- Reverse clusters of size >= 2.
      !revCs    = clustersOfSize2 nCand revEdges

      -- Annotate each reverse cluster with its forward spread.
      !annot    = [ (members, forwardSpread fwdIds members) | members <- revCs ]

      -- Count distinct forward clusters (size >= 2) just for stats.
      !nFwdClus = length (clustersOfSize2 nCand fwdEdges)
      !nRevClus = length revCs
      !nDelta   = length [ () | (_, s) <- annot, s > 1 ]

      -- Apply --delta-only filter, then --max-cluster-spread filter,
      -- then rank by forward spread desc, then by cluster size desc.
      -- Cap at --top-n (applied last so the cap reflects the kept set,
      -- not the pre-filter set).
      --
      -- The spread filter rejects reverse clusters whose
      -- @forward-spread / size@ ratio is below 'optMaxClusterSpread'.
      -- Threshold @0@ disables it.  Empty / singleton clusters can't
      -- appear here (revClusters keeps size >= 2), but we still guard
      -- the divisor.
      !filtered = if optDeltaOnly
                    then [ a | a@(_, s) <- annot, s > 1 ]
                    else annot
      passesSpread (m, s) =
        let !sz = length m
        in optMaxClusterSpread <= 0
            || sz <= 0
            || (fromIntegral s / fromIntegral sz :: Double)
                 >= optMaxClusterSpread
      !filteredSpread  = filter passesSpread filtered
      !nRejectedSpread = length filtered - length filteredSpread
      !rank     = sortBy
                    (comparing (\(m, s) -> (Down s, Down (length m))))
                    filteredSpread
      !topped   = take (max 0 optTopN) rank

  hPutStrLn stderr $
    "[echo] candidates=" ++ show nCand
    ++ ", reverse-clusters=" ++ show nRevClus
    ++ ", forward-clusters=" ++ show nFwdClus
    ++ ", delta-actionable=" ++ show nDelta
    ++ ", rejected-by-spread=" ++ show nRejectedSpread

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        echoJson ix opts candVec fwdIds revEdges
                 nCand nFwdClus nRevClus nDelta nRejectedSpread topped
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn $ "# Echo — reverse-direction fingerprint "
              ++ "(k=" ++ show optWlK
              ++ ", jaccard>=" ++ printf "%.2f" optJaccardThreshold
              ++ ", min-size=" ++ show optMinSize
              ++ (if optWlDepth == 0 then "" else ", wl-depth=" ++ show optWlDepth)
              ++ (if optDeltaOnly then ", delta-only" else "")
              ++ ", max-cluster-spread=" ++ printf "%.2f" optMaxClusterSpread
              ++ ", top-n=" ++ show optTopN
              ++ ")"
      putStrLn ""
      putStrLn $ "candidates considered     : " ++ show nCand
      putStrLn $ "forward clusters found    : " ++ show nFwdClus
      putStrLn $ "reverse clusters found    : " ++ show nRevClus
      putStrLn $ "reverse-cluster pairs     : "
              ++ show (sum [ length m * (length m - 1) `div` 2
                           | (m, _) <- annot ])
      putStrLn $ "delta-actionable clusters : " ++ show nDelta
      putStrLn $ "rejected by --max-cluster-spread: "
              ++ show nRejectedSpread ++ " clusters"
      putStrLn ""
      if null topped
        then putStrLn "no reverse clusters above threshold."
        else do
          putStrLn "## Top reverse clusters by delta"
          putStrLn ""
          forM_ (zip [(1 :: Int) ..] topped) $ \(idx, (members, spread)) -> do
            let !avgSim = clusterAvgSim optJaccardThreshold revEdges members
            putStrLn $ "[cluster " ++ show idx ++ "]"
                    ++ "  size " ++ show (length members)
                    ++ "   reverse-Jaccard ≥ " ++ printf "%.2f" avgSim
                    ++ "   forward-cluster-spread " ++ show spread
            -- Sort members within a cluster by reverse-subtree size desc
            -- for predictable output.
            let sortedMembers =
                  sortBy (comparing (Down . IS.size . cRevSubtree . (candVec V.!)))
                         members
            forM_ sortedMembers $ \memIdx -> do
              let c   = candVec V.! memIdx
                  d   = defAt ix (cId c)
                  fId = fwdIds V.! memIdx
              putStrLn $ "  " ++ T.unpack (defName d)
                      ++ "  (fwd-cluster " ++ show fId ++ ")"
            putStrLn ""

--------------------------------------------------------------------------------
-- JSON rendering
--------------------------------------------------------------------------------

echoJson
  :: Index
  -> Options
  -> Vector Cand
  -> V.Vector Int       -- ^ Forward cluster id per candidate index.
  -> [SimEdge]          -- ^ Reverse similarity edges.
  -> Int                -- ^ candidates
  -> Int                -- ^ forward clusters
  -> Int                -- ^ reverse clusters
  -> Int                -- ^ delta-actionable count
  -> Int                -- ^ clusters rejected by --max-cluster-spread
  -> [([Int], Int)]     -- ^ Ranked clusters with their spread.
  -> A.Value
echoJson ix opts candVec fwdIds revEdges
         nCand nFwd nRev nDelta nRejectedSpread topped =
  A.object
    [ "subcommand" .= ("echo" :: Text)
    , "options"    .= echoOptionsJson opts
    , "stats"      .= A.object
        [ "candidates"                  .= nCand
        , "forward_clusters"            .= nFwd
        , "reverse_clusters"            .= nRev
        , "delta_actionable"            .= nDelta
        , "clusters_rejected_by_spread" .= nRejectedSpread
        ]
    , "clusters" .= A.toJSON
        (zipWith (clusterJson ix candVec fwdIds revEdges (optJaccardThreshold opts))
                 [1 :: Int ..] topped)
    ]

echoOptionsJson :: Options -> A.Value
echoOptionsJson Options{..} = A.object
  [ "wl_k"                .= optWlK
  , "jaccard"             .= optJaccardThreshold
  , "min_size"            .= optMinSize
  , "wl_depth"            .= optWlDepth
  , "delta_only"          .= optDeltaOnly
  , "top_n"               .= optTopN
  , "max_cluster_spread"  .= optMaxClusterSpread
  ]

clusterJson
  :: Index
  -> Vector Cand
  -> V.Vector Int
  -> [SimEdge]
  -> Double
  -> Int
  -> ([Int], Int)
  -> A.Value
clusterJson ix candVec fwdIds revEdges thr cid (members, spread) =
  let !avgSim = clusterAvgSim thr revEdges members
      sortedMembers =
        sortBy (comparing (Down . IS.size . cRevSubtree . (candVec V.!)))
               members
      memberJson memIdx =
        let c   = candVec V.! memIdx
            d   = defAt ix (cId c)
            fId = fwdIds V.! memIdx
        in A.object
             [ "qname"            .= defName d
             , "forward_cluster"  .= fId
             ]
  in A.object
       [ "id"              .= cid
       , "reverse_size"    .= length members
       , "forward_spread"  .= spread
       , "avg_similarity"  .= avgSim
       , "members"         .= A.toJSON (map memberJson sortedMembers)
       ]
