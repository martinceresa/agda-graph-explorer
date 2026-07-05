{-# LANGUAGE BangPatterns #-}

-- | Shared primitives for the graph-clustering analyses (@fingerprint@
-- and @echo@): the bounded/unbounded BFS walks, the union-find
-- clusterisation and the intra-cluster average-similarity score.
--
-- The bits that genuinely diverge between the two analyses stay in their
-- own modules: the direction enum ('AgdaOptimization.Fingerprint.Direction'
-- carries a @Bidirectional@ case that @echo@ has no use for), the
-- direction-aware @neighboursOf@, the candidate selection, and pair
-- scoring (@fingerprint@ skips same-owner pairs; @echo@ scores against
-- a caller-supplied fingerprint selector). Those callers parameterise
-- the helpers here by passing in their own neighbour function and
-- threshold.
module AgdaOptimization.Cluster
  ( SimEdge
    -- * Subtree walks
  , bfsBoundedLayers
  , bfsUnbounded
    -- * Union-find clusterisation
  , seededUF
  , clustersOfSize2
    -- * Scoring
  , clusterAvgSim
  ) where

import           Data.Foldable        ( foldl' )
import qualified Data.IntSet          as IS
import qualified Data.Sequence        as Seq
import           Data.Sequence        ( ViewL(..), (|>) )

import           AgdaOptimization.UnionFind ( UF, emptyUF, ufClusters, ufInsert, ufUnion )

-- | An edge of the similarity graph: @(uIdx, vIdx, similarity)@ where the
-- indices reference the candidate list, not the global node ids.
type SimEdge = (Int, Int, Double)

--------------------------------------------------------------------------------
-- Subtree walks
--------------------------------------------------------------------------------

-- | Subtree limited to @maxDepth@ hops from @root@ under the supplied
-- neighbour function, BFS by layers (decrementing depth at each frontier
-- expansion). @seen@ accumulates everything reached so far (including the
-- root); @frontier@ is the most-recently-added layer. The returned set
-- always includes the root. Callers pass @maxDepth >= 1@; the unbounded
-- case is handled separately (see 'bfsUnbounded' and the library
-- 'AgdaGraph.Index.descendants' / 'AgdaGraph.Index.ancestors').
bfsBoundedLayers :: (Int -> IS.IntSet) -> Int -> Int -> IS.IntSet
bfsBoundedLayers nbrs maxDepth root = step maxDepth (IS.singleton root) (IS.singleton root)
  where
    step !d !seen !frontier
      | d <= 0 || IS.null frontier = seen
      | otherwise =
          let !nextRaw   = IS.foldl' (\acc x -> IS.union acc (nbrs x))
                                      IS.empty frontier
              !nextLayer = IS.difference nextRaw seen
              !seen'     = IS.union seen nextLayer
          in step (d - 1) seen' nextLayer

-- | Unbounded BFS from @root@ under the supplied neighbour function. Used
-- only for the 'Bidirectional' fingerprint case, where both endpoints
-- (forward + reverse) must be followed simultaneously, so neither
-- 'AgdaGraph.Index.descendants' nor 'AgdaGraph.Index.ancestors' applies.
-- The returned set always includes the root.
bfsUnbounded :: (Int -> IS.IntSet) -> Int -> IS.IntSet
bfsUnbounded nbrs root = go (IS.singleton root) (Seq.singleton root)
  where
    go !seen !q = case Seq.viewl q of
      EmptyL    -> seen
      x :< rest ->
        let !ns      = nbrs x
            !newOnes = IS.difference ns seen
            !seen'   = IS.union seen newOnes
            !q'      = IS.foldl' (|>) rest newOnes
        in go seen' q'

--------------------------------------------------------------------------------
-- Union-find clusterisation
--------------------------------------------------------------------------------

-- | Union-find over the supplied edge set, seeding every candidate index
-- @[0 .. n-1]@ first so singletons can be looked up (and filtered out)
-- later.
seededUF :: Int -> [SimEdge] -> UF
seededUF n edges =
  let seeded = foldl' (flip ufInsert) emptyUF [0 .. n - 1]
  in foldl' (\uf (a, b, _) -> ufUnion a b uf) seeded edges

-- | Group candidate indices into clusters via a 'seededUF' over the edge
-- set, keeping only clusters with @>= 2@ members.
clustersOfSize2 :: Int -> [SimEdge] -> [[Int]]
clustersOfSize2 n edges =
  [ ks | ks <- ufClusters (seededUF n edges), length ks >= 2 ]

--------------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------------

-- | Average pairwise similarity within a cluster. Uses the precomputed
-- edge list; pairs missing from it are below threshold (we treat their
-- similarity as the threshold to avoid double-counting noise — the
-- average stays informative).
clusterAvgSim :: Double -> [SimEdge] -> [Int] -> Double
clusterAvgSim thr edges members =
  let memberSet = IS.fromList members
      contrib (a, b, s)
        | IS.member a memberSet && IS.member b memberSet = Just s
        | otherwise                                      = Nothing
      sims   = [ s | Just s <- map contrib edges ]
      nMems  = length members
      nPairs = nMems * (nMems - 1) `div` 2
  in case (sims, nPairs) of
       ([], _)   -> thr
       (_,  0)   -> thr
       (xs, np)  ->
         let !sumKnown   = sum xs
             !missing    = np - length xs
             !sumMissing = fromIntegral missing * thr
         in (sumKnown + sumMissing) / fromIntegral np
