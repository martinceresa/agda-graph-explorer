{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Efficient in-memory representation of an 'ExpandedGraph'.
--
-- Strategy: every QName gets a stable 'Int' node id (the
-- 'egDefinitions' index for the ones we have records for; trailing ids
-- for edge-only QNames — see 'idxSyntheticCount'). Edges live as two
-- 'IntMap's of 'IntSet's; the definition vector is a boxed
-- 'V.Vector Definition' so the def payload is O(1) indexed.
--
-- All traversal helpers here are strict and rely on 'IntMap.Strict' /
-- 'IntSet' / 'foldl'' / bang patterns. Topo / longest-path / closure
-- routines are the hot path for the optimisation analyses.
module AgdaGraph.Index
  ( -- * Index
    Index(..)
  , buildIndex
  , buildIndexLean

    -- * Queries
  , lookupId
  , lookupDef
  , defAt

    -- * Traversal
  , topoSort
  , descendants
  , ancestors
  , longestPathDP
  ) where

import           Control.DeepSeq     ( NFData(..) )
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap.Strict  as IM
import qualified Data.IntSet         as IS
import           Data.List           ( sortOn )
import qualified Data.Sequence       as Seq
import           Data.Sequence       ( Seq, ViewL(..) )
import           Data.Text           ( Text )
import qualified Data.Text           as T
import qualified Data.Vector         as V
import           Data.Word           ( Word64 )

import           AgdaGraph.Schema    ( Access(..), Definition(..)
                                     , ExpandedGraph(..), ExternalsSummary
                                     , Kind(..), Provenance(..), State(..) )

-- | All the precomputed bits the analyses share.
--
-- Invariants:
--   * @V.length idxDefs == idxNodeCount@.
--   * @HM.size idxNameToId == idxNodeCount@.
--   * Every node id 'i' satisfies @0 <= i < idxNodeCount@.
--   * 'idxForward' and 'idxReverse' map each source to its set of
--     targets / sources respectively; absent keys imply an empty set.
--   * The first 'idxRealCount' ids correspond one-for-one to the input
--     'egDefinitions' (preserving its order); the trailing
--     'idxSyntheticCount' ids are synthetic placeholders for QNames
--     that appeared only in 'egDefinitionEdges'.
data Index = Index
  { idxDefs              :: !(V.Vector Definition)
  , idxNameToId          :: !(HM.HashMap Text Int)
  , idxForward           :: !(IM.IntMap IS.IntSet)
  , idxReverse           :: !(IM.IntMap IS.IntSet)
  , idxNodeCount         :: !Int
  , idxRealCount         :: !Int
    -- ^ Defs sourced from 'egDefinitions'. Ids @[0 .. idxRealCount-1]@.
  , idxSyntheticCount    :: !Int
    -- ^ Synthetic def nodes invented because they only appeared as
    -- endpoints of 'egDefinitionEdges'. Ids
    -- @[idxRealCount .. idxNodeCount-1]@.
  , idxExternalsSummary  :: !(Maybe ExternalsSummary)
    -- ^ Pass-through of 'egExternalsSummary' so analyses can reach the
    -- producer's @--no-externals@ diagnostic without re-parsing the
    -- JSON. 'Nothing' for graphs produced without @--no-externals@.
  , idxEdgeProvenance    :: !(Maybe (IM.IntMap (IM.IntMap Provenance)))
    -- ^ Per-edge 'Provenance' indexed as @src -> tgt -> tag@. 'Just'
    -- when the producer emitted 'egEdgeProvenance' (one tag per edge);
    -- 'Nothing' when the field was absent (older JSON) so analyses can
    -- detect the missing-data case and degrade gracefully. Built lazily
    -- per (src, tgt) but the spine and values are strict.
  , idxSubtermHashes     :: !(Maybe (IM.IntMap [Word64]))
    -- ^ Per-real-def canonical-form subterm hashes, indexed
    -- @defId -> [hashes]@. 'Just' when the producer emitted
    -- 'egSubtermHashes' (i.e. ran with @--with-term-hashes@);
    -- 'Nothing' otherwise. Only real defs (ids
    -- @[0 .. idxRealCount - 1]@) appear; synthetic edge-only ids never
    -- have hashes and aren't in the map. Consumed by the
    -- @term-cluster@ subcommand.
  , idxSubtermDepths     :: !(Maybe (IM.IntMap [Int]))
    -- ^ Parallel to 'idxSubtermHashes' — AST depth of each emitted
    -- subterm. 'Just' iff the producer emitted 'egSubtermDepths';
    -- older snapshots may have hashes but no depths, in which case
    -- this is 'Nothing' and consumers fall back to size-only ranking.
  }

instance NFData Index where
  rnf Index{..} =
        rnf idxDefs
    `seq` rnf idxNameToId
    `seq` rnf idxForward
    `seq` rnf idxReverse
    `seq` rnf idxNodeCount
    `seq` rnf idxRealCount
    `seq` rnf idxSyntheticCount
    `seq` rnf idxExternalsSummary
    `seq` rnf idxEdgeProvenance
    `seq` rnf idxSubtermHashes
    `seq` rnf idxSubtermDepths

-- | Build the 'Index' from an 'ExpandedGraph'. O(|defs| + |edges|).
--
-- Synthetic nodes (QNames in edges but missing from 'egDefinitions')
-- are assigned trailing ids and tagged @defState = Defined, defKind =
-- KOther@ so downstream analyses don't need to special-case them.
buildIndex :: ExpandedGraph -> Index
buildIndex ExpandedGraph{..} =
  let -- (1) Real defs, in 'egDefinitions' order. The producer assigns
      -- a stable @"id"@ field but we re-key by position so callers can
      -- treat the vector as O(1) indexed.
      realDefs :: [Definition]
      realDefs = zipWith (\d i -> d { defId = i })
                         egDefinitions [0..]

      nReal :: Int
      !nReal = length realDefs

      realMap :: HM.HashMap Text Int
      !realMap = HM.fromList [ (defName d, defId d) | d <- realDefs ]

      -- (2) Discover edge-only QNames; allocate trailing ids.
      addNew :: (HM.HashMap Text Int, Int) -> Text
             -> (HM.HashMap Text Int, Int)
      addNew (!m, !n) t
        | HM.member t m = (m, n)
        | otherwise     = (HM.insert t n m, n + 1)

      addPair :: (HM.HashMap Text Int, Int) -> (Text, Text)
              -> (HM.HashMap Text Int, Int)
      addPair acc (a, b) = addNew (addNew acc a) b

      (nameToId, total) =
        foldl' addPair (realMap, nReal) egDefinitionEdges

      nSynth :: Int
      !nSynth = total - nReal

      -- (3) Materialise synthetic defs. Stored in id order so the
      -- vector slot at index @i@ matches @defId = i@.
      syntheticDefs :: [Definition]
      syntheticDefs =
        [ Definition
            { defId     = i
            , defName   = qn
            , defModule = moduleOfQName qn
            , defState  = Defined
            , defKind   = KOther
            , defLine   = Nothing
            , defAccess = Public
            , defSig    = Nothing
            , defX      = 0
            , defY      = 0
            , defOrigin = Nothing
            }
        | (qn, i) <- sortOn snd [ (qn, i)
                                | (qn, i) <- HM.toList nameToId
                                , i >= nReal
                                ]
        ]

      defsVec :: V.Vector Definition
      !defsVec = V.fromListN total (realDefs ++ syntheticDefs)

      -- (4) Adjacency. Drop any edge whose endpoints we somehow can't
      -- resolve (shouldn't happen post-step-2, but be defensive).
      resolvePair :: (Text, Text) -> Maybe (Int, Int)
      resolvePair (a, b) = do
        ai <- HM.lookup a nameToId
        bi <- HM.lookup b nameToId
        pure (ai, bi)

      (!forward, !reverseAdj) =
        foldl' insBoth (IM.empty, IM.empty) egDefinitionEdges
        where
          insBoth (!f, !r) e = case resolvePair e of
            Just (s, t) ->
              ( IM.insertWith IS.union s (IS.singleton t) f
              , IM.insertWith IS.union t (IS.singleton s) r
              )
            Nothing     -> (f, r)

      -- Provenance map. 'Nothing' when the producer didn't emit per-edge
      -- tags (preserves the old wire format for analyses that don't care).
      -- When 'Just', we zip edges with their tags and fold into a nested
      -- IntMap; duplicate (src, tgt) keys take the last tag seen, matching
      -- the implicit dedup behaviour of 'IS.union' on 'idxForward'.
      provIdx :: Maybe (IM.IntMap (IM.IntMap Provenance))
      !provIdx
        | null egEdgeProvenance = Nothing
        | otherwise =
            let insP !acc (e, p) = case resolvePair e of
                  Just (s, t) ->
                    let !inner = IM.findWithDefault IM.empty s acc
                        !inner' = IM.insert t p inner
                    in IM.insert s inner' acc
                  Nothing -> acc
                !m = foldl' insP IM.empty (zip egDefinitionEdges egEdgeProvenance)
            in Just m

      -- Subterm hashes / depths. 'Nothing' when the producer didn't emit
      -- the array; otherwise a sparse IntMap keyed by real-def id (the
      -- arrays are parallel to 'egDefinitions', one-for-one in step 1
      -- above), dropping empty inner lists. Both arrays share one builder.
      toIdxMap :: [[a]] -> Maybe (IM.IntMap [a])
      toIdxMap xss
        | null xss  = Nothing
        | otherwise =
            Just $! foldl'
                      (\ !acc (i, xs) ->
                         if null xs then acc else IM.insert i xs acc)
                      IM.empty
                      (zip [0 :: Int ..] xss)

      !sthIdx = toIdxMap egSubtermHashes
      !stdIdx = toIdxMap egSubtermDepths

  in Index
       { idxDefs             = defsVec
       , idxNameToId         = nameToId
       , idxForward          = forward
       , idxReverse          = reverseAdj
       , idxNodeCount        = total
       , idxRealCount        = nReal
       , idxSyntheticCount   = nSynth
       , idxExternalsSummary = egExternalsSummary
       , idxEdgeProvenance   = provIdx
       , idxSubtermHashes    = sthIdx
       , idxSubtermDepths    = stdIdx
       }

-- | Build an 'Index' that drops the two fields no @agda-explore@ daemon
-- query ever reads: 'idxSubtermDepths' (only @agda-optimization term-cluster@
-- consumes it) and 'idxExternalsSummary' (only @debt@\/@ledger@\/@horizon@).
-- Nulling them lets the daemon's @evaluate (force ix)@ and lifelong snapshot
-- skip materialising / retaining the per-def depth lists, while the shared
-- 'buildIndex' is left untouched so the batch analyses keep both fields.
--
-- 'idxSubtermHashes' is /kept/ (it backs @similar_bodies@) and so is
-- 'idxEdgeProvenance' (it backs @similar_types@ via 'splitSigBodyAdj').
buildIndexLean :: ExpandedGraph -> Index
buildIndexLean eg = (buildIndex eg)
  { idxSubtermDepths    = Nothing
  , idxExternalsSummary = Nothing
  }

-- ** Lookups

-- | Look up the integer id of a QName.
lookupId :: Index -> Text -> Maybe Int
lookupId Index{..} t = HM.lookup t idxNameToId

-- | Look up the full record by QName.
lookupDef :: Index -> Text -> Maybe Definition
lookupDef ix t = defAt ix <$> lookupId ix t

-- | Direct access by id. /Crashes/ on out-of-range — call with an id
-- you got from this 'Index'.
defAt :: Index -> Int -> Definition
defAt Index{..} i = idxDefs V.! i

-- ** Traversal

-- | Topological sort of the dependency graph (edges point user ->
-- usee). Returns either the order or a witness cycle (a non-empty list
-- of node ids that still had positive in-degree after the queue
-- drained — i.e. they participate in at least one cycle).
--
-- Kahn's algorithm over 'IntMap'/'IntSet'. O(V + E).
topoSort :: Index -> Either [Int] [Int]
topoSort Index{..} =
  let -- In-degree from the forward adjacency.
      inDeg0 :: IM.IntMap Int
      !inDeg0 = foldl' bump IM.empty
        [ t
        | (_, ts) <- IM.toList idxForward
        , t       <- IS.toList ts
        ]
        where
          bump !acc t = IM.insertWith (+) t 1 acc

      -- Seed every node so that isolated nodes appear in the order too.
      seeded :: IM.IntMap Int
      !seeded = foldl' seed inDeg0 [0 .. idxNodeCount - 1]
        where
          seed !acc i
            | IM.member i acc = acc
            | otherwise       = IM.insert i 0 acc

      initialQ :: Seq Int
      !initialQ = Seq.fromList
        [ i | (i, d) <- IM.toAscList seeded, d == 0 ]

      go :: [Int] -> IM.IntMap Int -> Seq Int -> Either [Int] [Int]
      go !acc !inDeg q = case Seq.viewl q of
        EmptyL ->
          if length acc == idxNodeCount
            then Right (reverse acc)
            else Left (IM.keys (IM.filter (> 0) inDeg))
        cur :< rest ->
          let neighbours = IM.findWithDefault IS.empty cur idxForward
              (inDeg', enq) = IS.foldl' step (inDeg, []) neighbours
              step (!m, !buf) n =
                let !d  = IM.findWithDefault 0 n m - 1
                    !m' = IM.insert n d m
                in if d <= 0 then (m', n : buf) else (m', buf)
              q' = foldl' (Seq.|>) rest enq
          in go (cur : acc) inDeg' q'
  in go [] seeded initialQ

-- | Forward transitive closure of a seed set (the set is excluded
-- from the result unless reachable from a seed via a non-empty path).
-- Iterative DFS; visits each node at most once.
descendants :: Index -> IS.IntSet -> IS.IntSet
descendants ix seeds = traverseClosure (idxForward ix) seeds

-- | Reverse transitive closure of a seed set.
ancestors :: Index -> IS.IntSet -> IS.IntSet
ancestors ix seeds = traverseClosure (idxReverse ix) seeds

-- | Shared closure walker. Returns the set of /reachable/ nodes from
-- @seeds@ excluding the seeds themselves.
traverseClosure :: IM.IntMap IS.IntSet -> IS.IntSet -> IS.IntSet
traverseClosure adj seeds =
  let initial = IS.toList seeds
      go !acc [] = acc
      go !acc (n : rest) =
        let nbrs   = IM.findWithDefault IS.empty n adj
            !fresh = IS.difference nbrs acc
            !acc'  = IS.union acc fresh
            !rest' = IS.foldr (:) rest fresh
        in go acc' rest'
      reachable = go IS.empty initial
  in IS.difference reachable seeds

-- | Depth of each node to the deepest reachable sink, computed in
-- /reverse/ topological order (i.e. sinks first). A sink that's in the
-- given seed set gets depth 0; a non-sink gets @1 + max(depth child)@.
--
-- Nodes that don't reach any seed are absent from the returned map
-- (caller uses 'IM.notMember' to filter — interpret-as-(-1) is a
-- caller convention).
--
-- O(V + E) over the topo order. Returns an empty map if the graph has
-- a cycle (no meaningful longest-path on a non-DAG).
longestPathDP :: Index -> IS.IntSet -> IM.IntMap Int
longestPathDP ix sinks = case topoSort ix of
  Left _   -> IM.empty
  Right xs ->
    let rev = reverse xs
        step !acc n
          | IS.member n sinks =
              IM.insert n 0 acc
          | otherwise =
              let kids = IM.findWithDefault IS.empty n (idxForward ix)
                  best = IS.foldl' bestStep Nothing kids
                  bestStep !mb k = case IM.lookup k acc of
                    Just d  -> Just $! case mb of
                      Nothing -> d + 1
                      Just b  -> max b (d + 1)
                    Nothing -> mb
              in case best of
                   Just d  -> IM.insert n d acc
                   Nothing -> acc
    in foldl' step IM.empty rev

-- ** Helpers

-- | Strip the last dot-component of a fully-qualified name. Used only
-- for synthetic nodes (edge-only QNames where we have no producer
-- 'defModule'). Returns the input unchanged if it has no dot.
moduleOfQName :: Text -> Text
moduleOfQName t =
  let (pre, _) = T.breakOnEnd "." t
  in if T.null pre
       then t            -- no dot at all => treat the whole name as its own "module".
       else T.dropEnd 1 pre  -- drop the trailing '.'
