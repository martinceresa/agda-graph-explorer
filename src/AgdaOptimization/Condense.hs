{-# LANGUAGE BangPatterns #-}

-- | SCC-condensation of an 'Index': collapse each strongly-connected
-- component to a single node so downstream passes can run a topological DP
-- on the resulting DAG. Shared by every analysis that needs it
-- (@load-bearing@, @horizon@, @pyre@, @chokepoint@).
module AgdaOptimization.Condense
  ( Condensation(..)
  , buildCondensation
  ) where

import qualified Data.Graph         as G
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS

import           AgdaGraph.Index    ( Index(..) )

-- | The SCC-condensation of an 'Index'. Each SCC gets a small @Int@ id.
-- Edges in 'cdForward' / 'cdReverse' are between SCC ids and form a DAG.
data Condensation = Condensation
  { cdSccOf   :: !(IM.IntMap Int)         -- ^ node id -> SCC id
  , cdMembers :: !(IM.IntMap IS.IntSet)   -- ^ SCC id  -> member node ids
  , cdForward :: !(IM.IntMap IS.IntSet)   -- ^ SCC forward adjacency (no self-loops)
  , cdReverse :: !(IM.IntMap IS.IntSet)   -- ^ SCC reverse adjacency
  , cdTopo    :: ![Int]                   -- ^ SCC topo order (sources first)
  , cdCount   :: !Int                     -- ^ number of SCCs
  }

-- | Build the SCC condensation. O((V+E) * log V) thanks to 'IM.insert';
-- 'Data.Graph.stronglyConnCompR' returns SCCs in REVERSE topo order
-- (cf. 'containers' docs), so we reverse to put sources first.
buildCondensation :: Index -> Condensation
buildCondensation !ix =
  let nodes = [0 .. idxNodeCount ix - 1]
      adjList :: [(Int, Int, [Int])]
      !adjList =
        [ ( n
          , n
          , IS.toList (IM.findWithDefault IS.empty n (idxForward ix))
          )
        | n <- nodes
        ]
      sccs = G.stronglyConnCompR adjList
      sccsForward :: [[(Int, Int, [Int])]]
      sccsForward = reverse (map flatten sccs)
      flatten (G.AcyclicSCC v)  = [v]
      flatten (G.CyclicSCC vs)  = vs
      indexed :: [(Int, [(Int, Int, [Int])])]
      indexed     = zip [0 :: Int ..] sccsForward

      sccOf :: IM.IntMap Int
      members :: IM.IntMap IS.IntSet
      (!sccOf, !members) = foldl' assignSCC (IM.empty, IM.empty) indexed
      assignSCC (!so, !mm) (!sid, scc) =
        let memberIds = [ n | (_, n, _) <- scc ]
            !so'      = foldl' (\acc i -> IM.insert i sid acc) so memberIds
            !mm'      = IM.insert sid (IS.fromList memberIds) mm
        in (so', mm')

      -- SCC forward edges: for each original edge a->b, add scc(a) -> scc(b)
      -- unless they're in the same SCC.
      fwd :: IM.IntMap IS.IntSet
      !fwd = foldl' (\acc (a, ts) ->
                       IS.foldl' (\ !m b ->
                                    let !sa = sccOf IM.! a
                                        !sb = sccOf IM.! b
                                    in if sa == sb
                                         then m
                                         else IM.insertWith IS.union sa
                                                (IS.singleton sb) m)
                                 acc ts)
                  IM.empty (IM.toList (idxForward ix))

      rev :: IM.IntMap IS.IntSet
      !rev = IM.foldlWithKey'
               (\acc src tgts ->
                  IS.foldl' (\ !m t ->
                               IM.insertWith IS.union t (IS.singleton src) m)
                            acc tgts)
               IM.empty fwd

      topo = [ sid | (sid, _) <- indexed ]
  in Condensation
       { cdSccOf   = sccOf
       , cdMembers = members
       , cdForward = fwd
       , cdReverse = rev
       , cdTopo    = topo
       , cdCount   = length indexed
       }
