{-# LANGUAGE BangPatterns #-}

-- | The structural-similarity cores shared by the batch
-- @agda-optimization@ analyses (@silhouette@, @term-cluster@) and the
-- @agda-explore@ daemon's point queries (@similar_types@,
-- @similar_bodies@).
--
-- Factoring these out of the executable into the @agda-graph@ library is
-- what lets the daemon's pairwise queries agree with the bulk analyses
-- /by construction/ rather than by re-implementing a lookalike metric:
--
--   * 'buildSigBodyFingerprints' is the signature\/body Weisfeiler–Leman
--     fingerprint pair @silhouette@ clusters on. @similar_types@ ranks
--     candidates by 'weightedJaccard' of the same signature fingerprints,
--     so a high-similarity pair here is exactly a same-signature-shape
--     pair there.
--   * 'subtermMultiset' is the occurrence-weighted canonical-subterm
--     multiset @term-cluster@ buckets over. @similar_bodies@ ranks by
--     'weightedJaccard' of these multisets, matching @term-cluster@'s
--     occurrence-counted view of body structure.
module AgdaGraph.Similarity
  ( -- * Signature / body topology (silhouette core)
    silhouetteDefaultWlK
  , fingerprintSize
  , SigBodyFingerprints(..)
  , buildSigBodyFingerprints
    -- * Subterm structure (term-cluster core)
  , subtermMultisetsVec
  ) where

import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS
import           Data.Vector        ( Vector )
import qualified Data.Vector        as V

import           AgdaGraph.Index    ( Index(..), closureFrom )
import           AgdaGraph.Schema   ( Provenance(..) )
import           AgdaGraph.WL       ( ColorVec, Fingerprint, fingerprintAt
                                    , fingerprintSize, initialColors, refine )

--------------------------------------------------------------------------------
-- Signature / body adjacency split: read the index directly and name the
-- no-provenance fallback explicitly.
--------------------------------------------------------------------------------

-- | The WL refinement depth @silhouette@ uses by default. Exposed so
-- @agda-explore@'s @similar_types@ refines to the same depth and the two
-- fingerprint spaces coincide.
silhouetteDefaultWlK :: Int
silhouetteDefaultWlK = 2

-- | Split the forward adjacency into the /signature subgraph/ (edges the
-- producer tagged 'ProvSignature') and the /body subgraph/ (everything
-- else: 'ProvBody' \/ 'ProvModuleLocal' \/ 'ProvWhere' \/ 'ProvWith' \/
-- 'ProvUnknown', plus any edge missing a tag, which defaults to body).
--
-- The third component is 'True' when the graph carried per-edge
-- provenance. When it didn't ('idxEdgeProvenance' is 'Nothing') both
-- halves are the full forward adjacency and the flag is 'False' — callers
-- then degrade to a single fingerprint space over all edges, exactly as
-- @silhouette@'s fallback does.
splitSigBodyAdj :: Index -> (IM.IntMap IS.IntSet, IM.IntMap IS.IntSet, Bool)
splitSigBodyAdj ix = case idxEdgeProvenance ix of
  Nothing      -> (idxForward ix, idxForward ix, False)
  Just provMap ->
    let step (!sigAcc, !bodyAcc) src tgts =
          let inner = IM.findWithDefault IM.empty src provMap
              (sigTs, bodyTs) = IS.foldl' (classify inner) (IS.empty, IS.empty) tgts
              sigAcc'  = if IS.null sigTs  then sigAcc  else IM.insert src sigTs  sigAcc
              bodyAcc' = if IS.null bodyTs then bodyAcc else IM.insert src bodyTs bodyAcc
          in (sigAcc', bodyAcc')
        classify innerMap (!s, !b) t =
          case IM.lookup t innerMap of
            Just ProvSignature -> (IS.insert t s, b)
            Just _             -> (s, IS.insert t b)
            Nothing            -> (s, IS.insert t b)  -- missing tag -> body
        (!sig, !body) = IM.foldlWithKey' step (IM.empty, IM.empty) (idxForward ix)
    in (sig, body, True)

-- | Unbounded rooted subtree under the supplied adjacency: every node
-- reachable from @root@ via forward edges, plus the root itself. A thin
-- specialisation of 'closureFrom' (seed kept).
subtreeUnder :: IM.IntMap IS.IntSet -> Int -> IS.IntSet
subtreeUnder adj root = closureFrom True adj (IS.singleton root)

--------------------------------------------------------------------------------
-- Signature / body fingerprints (silhouette's per-node WL fingerprint
-- pair, computed once for the whole graph).
--------------------------------------------------------------------------------

-- | Per-node signature and body fingerprints over the whole graph, plus
-- the edge counts and the provenance flag. Index both vectors by node id.
data SigBodyFingerprints = SigBodyFingerprints
  { sbfSig          :: !(Vector Fingerprint) -- ^ signature-subgraph fingerprint per node.
  , sbfBody         :: !(Vector Fingerprint) -- ^ body-subgraph fingerprint per node.
  , sbfSigEdges     :: !Int                  -- ^ signature edge count.
  , sbfBodyEdges    :: !Int                  -- ^ body edge count.
  , sbfHasProvenance :: !Bool                -- ^ False ⇒ both halves are the full forward graph.
  }

-- | Build the signature/body fingerprint pair. Refines each subgraph
-- independently with @wlK@ WL rounds (pass 'silhouetteDefaultWlK' to match
-- the batch analysis), then for every node records the colour histogram of
-- its rooted subtree under each subgraph. This is the exact computation
-- @silhouette@ runs per candidate, lifted to the whole node range so a
-- daemon can cache it once per snapshot.
buildSigBodyFingerprints :: Int -> Index -> SigBodyFingerprints
buildSigBodyFingerprints wlK ix =
  let (!sigAdj, !bodyAdj, !hasProv) = splitSigBodyAdj ix
      nbrSig  i = IM.findWithDefault IS.empty i sigAdj
      nbrBody i = IM.findWithDefault IS.empty i bodyAdj
      !sigCk  = refine ix nbrSig  wlK (initialColors ix nbrSig)  :: ColorVec
      !bodyCk = refine ix nbrBody wlK (initialColors ix nbrBody) :: ColorVec
      !n = idxNodeCount ix
      -- Each node's rooted-subtree closure + fingerprint is an independent
      -- O(V+E) computation; spark them (order-preserving parMap → identical
      -- vectors). This is the dominant cost and the first similar_* query /
      -- silhouette run forces the whole vector, so parallelising it turns a
      -- serial O(V*(V+E)) build into a per-core one.
      mkFps ck adj = V.fromListN n
                       (parMap rdeepseq
                          (\i -> fingerprintAt ck (subtreeUnder adj i)) [0 .. n - 1])
      countEdges   = IM.foldl' (\ !a s -> a + IS.size s) 0
      !sigFps    = mkFps sigCk  sigAdj
      !bodyFps   = mkFps bodyCk bodyAdj
      !sigEdges  = countEdges sigAdj
      !bodyEdges = countEdges bodyAdj
  in SigBodyFingerprints
       { sbfSig           = sigFps
       , sbfBody          = bodyFps
       , sbfSigEdges      = sigEdges
       , sbfBodyEdges     = bodyEdges
       , sbfHasProvenance = hasProv
       }

--------------------------------------------------------------------------------
-- Subterm multiset (term-cluster's occurrence-weighted view, per def).
--------------------------------------------------------------------------------

-- | Per-real-def occurrence-weighted subterm multisets, indexed by def id
-- — the @term-cluster@ view a daemon caches once per snapshot. 'Nothing'
-- when the graph carries no subterm hashes at all (producer ran without
-- @--with-term-hashes@); otherwise each element is the @hash -> occurrences@
-- multiset of that def's canonical subterms (empty for a def with none).
-- Counting occurrences (not mere set membership) is what aligns a pairwise
-- body comparison with @term-cluster@'s per-hash occurrence buckets.
subtermMultisetsVec :: Index -> Maybe (Vector Fingerprint)
subtermMultisetsVec ix = case idxSubtermHashes ix of
  Nothing -> Nothing
  Just hm -> Just $ V.generate (idxRealCount ix) (multisetOf hm)
  where
    multisetOf hm i = foldl' bump IM.empty (IM.findWithDefault [] i hm)
    bump !acc h     = IM.insertWith (+) (fromIntegral h) 1 acc
