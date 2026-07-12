{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Pure union of several expanded graphs into one.
--
-- The @agda-explore@ daemon's live mode builds the dependency graph by
-- shelling out to @agda-deps@. A /single/ @agda-deps@ invocation only
-- compiles the import closure of /one/ entry module, so to cover several
-- entry modules at once the daemon runs the producer once per entry (into
-- separate out-dirs), parses each 'ExpandedGraph', and unions the results
-- here. The single in-memory 'AgdaGraph.Index.buildIndex' over the unioned
-- graph then covers the union of all the entries' closures — every
-- downstream query/tool stays unchanged because it operates purely on the
-- 'AgdaGraph.Index.Index'.
--
-- The union is by node KEY — a definition's fully-qualified name
-- ('defName'), which is exactly the key 'AgdaGraph.Index' uses
-- ('idxNameToId'). A node appearing in more than one input graph is merged
-- once: its out-edges are unioned (deduplicated), and the /richer/ rendered
-- signature wins (a 'Just' 'defSig' over a 'Nothing'). Definitions are
-- emitted /sorted by node key/ so the in-memory id assignment is stable and
-- a repeated build is deterministic.
--
-- Single-input ('[g]') is a deliberate identity (modulo the by-name dedup a
-- single graph never needs) — callers keep the one-graph path
-- byte-identical to today by /not/ routing it through here at all; this
-- module is only invoked for the genuine multi-entry case.
module AgdaGraph.Union
  ( unionExpandedGraphs
  ) where

import           Data.List        (sort, sortOn)
import qualified Data.Map.Strict  as M
import           Data.Text        (Text)
import           Data.Word        (Word64)

import           AgdaGraph.Schema (Definition (..), ExpandedGraph (..),
                                   Provenance (..))

-- | Union a non-empty list of expanded graphs into one.
--
-- Contract:
--
--   * __Definitions__ are deduplicated by 'defName' (the node key). When a
--     name occurs in several inputs, the merged record keeps the first
--     graph's record but upgrades 'defSig' to the first 'Just' seen across
--     the inputs (prefer the richer signature). The merged definition list
--     is __sorted by 'defName'__ for a stable, deterministic node-id
--     assignment in 'AgdaGraph.Index.buildIndex'.
--   * __Subterm hashes / depths__ are parallel to the definitions; the
--     merged arrays are rebuilt in the same sorted order so the parallel
--     invariant ('AgdaGraph.Schema' enforces @length == #definitions@)
--     holds. A name's hashes/depths come from the first input that carried
--     a non-empty array for it. If /no/ input emitted these arrays, the
--     merged graph emits @[]@ (the absent-field sentinel).
--   * __Edges__ are text pairs @(user, usee)@; they are unioned and
--     deduplicated (an edge present in several graphs appears once). Its
--     'Provenance' is the first non-'ProvUnknown' tag seen, falling back to
--     'ProvUnknown'. If /no/ input emitted provenance, the merged graph
--     emits @[]@.
--   * __moduleFiles__ / __modules__ / __failedModules__ /
--     __externalModules__ are unioned (deduped, order-stable).
--   * __moduleOptionEscapes__ is unioned by module; a module escaping in
--     several inputs keeps the sorted, deduped union of its escape flags.
--   * __entryModule__ is the first input's (representative); __producer__ /
--     __nodeKeyVersion__ are taken from the first input. The schema records
--     a single 'egEntryModule', so it is necessarily cosmetic under a
--     multi-entry union; @agda-explore@ surfaces the full entry set from
--     'Config', not from here.
--
-- Pre/postconditions: the input list must be non-empty (callers only build
-- a union for @>= 2@ entries); 'egNodeKeyVersion' is assumed identical
-- across inputs (they come from one @agda-deps@ binary in one daemon run).
unionExpandedGraphs :: [ExpandedGraph] -> ExpandedGraph
unionExpandedGraphs []  =
  error "AgdaGraph.Union.unionExpandedGraphs: empty input list"
unionExpandedGraphs [g] = g
unionExpandedGraphs gs@(g0 : _) =
  ExpandedGraph
    { egDefinitions      = mergedDefs
    , egDefinitionEdges  = mergedEdges
    , egModules          = nubOrd (concatMap egModules gs)
    , egEntryModule      = egEntryModule g0
    , egExternalModules  = nubOrd (concatMap egExternalModules gs)
    , egFailedModules    = nubOrd (concatMap egFailedModules gs)
    , egModuleFiles      = M.unions (map egModuleFiles gs)
    , egProducer         = egProducer g0
    , egNodeKeyVersion   = egNodeKeyVersion g0
    , egReExports        = concatMap egReExports gs
    , egExternalsSummary = egExternalsSummary g0
    , egModuleOptionEscapes = M.unionsWith mergeEscapes
                                (map egModuleOptionEscapes gs)
    , egEdgeProvenance   = mergedProvenance
    , egSubtermHashes    = mergedHashes
    , egSubtermDepths    = mergedDepths
    }
  where
    -- (1) Per-definition: collect each graph's defs alongside its parallel
    -- subterm arrays (already padded so positionally aligned), then fold by
    -- name into an accumulator keyed by 'defName'.
    perGraph :: ExpandedGraph -> [(Definition, [Word64], [Int])]
    perGraph g =
      let defs  = egDefinitions g
          hs    = padTo (length defs) [] (egSubtermHashes g)
          ds    = padTo (length defs) [] (egSubtermDepths g)
      in zip3 defs hs ds

    allDefsWithArrays :: [(Definition, [Word64], [Int])]
    allDefsWithArrays = concatMap perGraph gs

    -- A name -> (representative def, subterm hashes, subterm depths). The
    -- representative starts as the first record seen and is upgraded as
    -- richer data arrives (a 'Just' 'defSig', or non-empty subterm arrays).
    merge :: M.Map Text (Definition, [Word64], [Int])
          -> (Definition, [Word64], [Int])
          -> M.Map Text (Definition, [Word64], [Int])
    merge !acc (d, hs, ds) =
      M.insertWith mergeOne (defName d) (d, hs, ds) acc

    -- @new@ is the existing entry, @old@ the one already present (insertWith
    -- passes the to-be-inserted value first). Keep the earliest-seen record
    -- but pull up the richer signature. The subterm hashes and depths are
    -- chosen ATOMICALLY from a single input — never field-by-field — so we
    -- can't pair one graph's hashes with another's depths (which would break
    -- the per-def inner-length invariant the Schema parser enforces). Prefer
    -- the input whose hashes are non-empty (hashes are the primary signal;
    -- 'subtermMultisetsVec' uses only them); fall back to the other input's
    -- pair otherwise.
    mergeOne :: (Definition, [Word64], [Int]) -> (Definition, [Word64], [Int])
             -> (Definition, [Word64], [Int])
    mergeOne (dNew, hNew, sNew) (dOld, hOld, sOld) =
      let (h, s) | not (null hOld) = (hOld, sOld)
                 | otherwise       = (hNew, sNew)
      in ( dOld { defSig = defSig dOld `orElseSig` defSig dNew }, h, s )

    byName :: M.Map Text (Definition, [Word64], [Int])
    byName = foldl' merge M.empty allDefsWithArrays

    -- Sorted by node key (the def name) for a stable, deterministic id
    -- assignment downstream. 'M.toAscList' is already key-sorted, but be
    -- explicit so the intent survives a future refactor.
    sortedByName :: [(Definition, [Word64], [Int])]
    sortedByName = map snd (sortOn fst (M.toList byName))

    mergedDefs :: [Definition]
    mergedDefs = [ d | (d, _, _) <- sortedByName ]

    -- Parallel subterm arrays. Emit the field only if /some/ input carried
    -- it (otherwise keep the absent-field sentinel @[]@ so the schema's
    -- emptiness contract is preserved).
    anyHashes = any (not . null . egSubtermHashes) gs
    anyDepths = any (not . null . egSubtermDepths) gs

    mergedHashes :: [[Word64]]
    mergedHashes | anyHashes = [ hs | (_, hs, _) <- sortedByName ]
                 | otherwise = []

    mergedDepths :: [[Int]]
    mergedDepths | anyDepths = [ ds | (_, _, ds) <- sortedByName ]
                 | otherwise = []

    -- (2) Edges: dedup the (user, usee) text pairs across graphs, keeping
    -- the first non-'ProvUnknown' provenance tag for each. Insertion order
    -- of first appearance is preserved so the emitted list is stable.
    anyProv = any (not . null . egEdgeProvenance) gs

    -- For each graph, zip its edges with provenance (padding to
    -- 'ProvUnknown' when that graph omitted the field).
    edgesWithProv :: [((Text, Text), Provenance)]
    edgesWithProv =
      concatMap
        (\g -> zip (egDefinitionEdges g)
                   (padTo (length (egDefinitionEdges g)) ProvUnknown
                          (egEdgeProvenance g)))
        gs

    -- Fold preserving first-seen order: a list of keys in order + a map for
    -- the chosen provenance and membership test.
    foldEdges :: ([(Text, Text)], M.Map (Text, Text) Provenance)
              -> ((Text, Text), Provenance)
              -> ([(Text, Text)], M.Map (Text, Text) Provenance)
    foldEdges (!order, !m) (e, p) =
      case M.lookup e m of
        Nothing -> (e : order, M.insert e p m)
        Just p0 -> (order, M.insert e (betterProv p0 p) m)

    (revOrder, provMap) = foldl' foldEdges ([], M.empty) edgesWithProv
    mergedEdges :: [(Text, Text)]
    mergedEdges = reverse revOrder

    mergedProvenance :: [Provenance]
    mergedProvenance
      | anyProv   = [ M.findWithDefault ProvUnknown e provMap | e <- mergedEdges ]
      | otherwise = []

-- | Take the richer signature: a present one wins over an absent one;
-- otherwise keep the first.
orElseSig :: Maybe Text -> Maybe Text -> Maybe Text
orElseSig (Just s) _ = Just s
orElseSig Nothing  m = m

-- | Prefer a classified provenance tag over 'ProvUnknown'; otherwise keep
-- the first.
betterProv :: Provenance -> Provenance -> Provenance
betterProv ProvUnknown p = p
betterProv p           _ = p

-- | Merge two graphs' escape-flag lists for the same module: the sorted,
-- deduped union, preserving the producer's ascending-per-module contract.
-- The common case is identical lists (a module built the same way in every
-- entry), where this is the input unchanged.
mergeEscapes :: [Text] -> [Text] -> [Text]
mergeEscapes a b = nubOrd (sort (a ++ b))

-- | Pad (or truncate) a list to length @n@ with a filler. An empty list
-- pads entirely with the filler — used so a graph that omitted a parallel
-- array still lines up positionally with its definitions/edges.
padTo :: Int -> a -> [a] -> [a]
padTo n filler xs = take n (go xs)
  where
    go []        = repeat filler
    go (x : xs') = x : go xs'

-- | Order-preserving dedup (first occurrence wins). Deterministic given a
-- deterministic input order.
nubOrd :: Ord a => [a] -> [a]
nubOrd = goN M.empty
  where
    goN _    []       = []
    goN seen (x : xs)
      | x `M.member` seen = goN seen xs
      | otherwise         = x : goN (M.insert x () seen) xs
