{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | ProofPrint — structural near-duplicate detection via Weisfeiler-Lehman
-- fingerprinting of rooted dependency subtrees.
--
-- 'optDirection' defaults to 'Incoming': the reverse direction surfaces
-- defs that ANSWER the same callers, which is the right answer for the
-- common case. Pass @--direction=outgoing@ for the forward (callees)
-- view.
--
-- For each candidate node @v@, the analysis:
--
--   1. Computes the rooted subtree @{v} ∪ descendants(v)@ under
--      'idxForward'.
--   2. Refines per-node colours for @optWlK@ rounds, where each round
--      mixes a node's current colour with the sorted multiset of its
--      forward neighbours' colours.
--   3. Summarises the subtree as a colour histogram (the
--      \"fingerprint\").
--   4. Compares fingerprints pairwise with weighted Jaccard / Ruzicka
--      similarity; pairs at or above 'optJaccardThreshold' become
--      union-find edges. Each connected component is a cluster of
--      near-duplicates.
--
-- The output is human-readable text on stdout; clusters of size >= 2 are
-- reported, sorted by size descending.
--
-- Notes on correctness vs. ergonomics:
--
--   * Hashing is a hand-rolled mixing function on 'Int' tuples — no
--     external @Data.Hashable@ dependency.  The hash is good enough for
--     a triage filter; collisions are tolerable.
--
--   * WL is a heuristic.  False positives are expected and acceptable.
--
--   * We intentionally skip 'KOther' nodes as /candidates/ — they're
--     synthetic / unknown shape.  They can still appear inside another
--     candidate's subtree.
module AgdaOptimization.Fingerprint
  ( Options(..)
  , Direction(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad        ( forM_, when )
import           System.IO            ( hPutStrLn, stderr )
import           Control.DeepSeq             ( NFData(..) )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.HashMap.Strict  as HM
import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.List            ( sortBy, sortOn )
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           Data.Vector          ( Vector )
import           Text.Printf          ( printf )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), defAt, descendants, ancestors )
import           AgdaGraph.Schema     ( Definition(..), Kind(..), State(..) )
import           Data.Text            ( Text )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Cluster ( SimEdge, bfsBoundedLayers, bfsUnbounded
                                          , clustersOfSize2, clusterAvgSim )
import           AgdaGraph.WL         ( ColorVec, Fingerprint, fingerprintAt
                                      , initialColors, refine, weightedJaccard )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , emitJsonReport, withHumanOutput )

-- | Which side of the dependency graph drives the WL refinement and
-- the per-candidate rooted subtree.
--
--   * 'Outgoing': forward edges (callees).  "Two defs that USE the same
--     helpers."
--   * 'Incoming': reverse edges (callers).  "Two defs that ANSWER the
--     same callers."
--   * 'Bidirectional': union of forward and reverse.  Closure under
--     "anything connected" — broadest, noisiest.
data Direction = Outgoing | Incoming | Bidirectional
  deriving (Show, Eq)

-- | Configuration for the fingerprint analysis.  Fields are strict;
-- the entire record fits in a register-sized chunk.
data Options = Options
  { optWlK              :: !Int
    -- ^ Depth of the Weisfeiler-Lehman refinement.  Larger = more
    --   structural discrimination, more cost.  Default 2 is usually
    --   plenty.
  , optJaccardThreshold :: !Double
    -- ^ Lower bound on weighted-Jaccard similarity for a pair to be
    --   considered near-duplicate.
  , optMinSize          :: !Int
    -- ^ Minimum subtree size (in nodes) for a node to be a candidate.
    --   Filters out leaves and tiny stubs.
  , optWlDepth          :: !Int
    -- ^ Bound on the per-candidate rooted subtree radius (hops from
    --   the root).  @0@ = unbounded (full closure).  The WL refinement
    --   itself still runs to 'optWlK' over the whole graph; only the
    --   fingerprint subtree is bounded.
  , optDirection        :: !Direction
    -- ^ Which graph direction drives both the WL refinement and the
    --   rooted subtree.  See 'Direction'.  Defaults to 'Incoming'; pass
    --   @--direction=outgoing@ for the forward view.
  , optTopN             :: !Int
    -- ^ Maximum clusters rendered (sorted size-desc).
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optWlK              = 2
  , optJaccardThreshold = 0.8
  , optMinSize          = 3
  , optWlDepth          = 0
  , optDirection        = Incoming
  , optTopN             = 20
  }

-- | Parse a @--direction@ value.  Accepts @outgoing@, @incoming@,
-- @both@; @bidirectional@ is a synonym for @both@.
readDirection :: String -> String -> Either String Direction
readDirection _ v = case v of
  "outgoing"      -> Right Outgoing
  "incoming"      -> Right Incoming
  "both"          -> Right Bidirectional
  "bidirectional" -> Right Bidirectional
  _               -> Left $
    "fingerprint: --direction: expected outgoing|incoming|both, got " <> v

-- | Declarative flag spec for the @fingerprint@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
--
-- @--direction@ is an enum flag parsed by 'readDirection', whose @Left@
-- already embeds the @fingerprint: --direction: …@ prefix, so the argv
-- side surfaces it verbatim ('EnumVerbatim'). 'readDirection' ignores
-- its first argument, so the same partial application serves both the
-- argv and YAML-overlay sides identically.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ DblFlag "jaccard" "--jaccard=F                          weighted-Jaccard threshold (default 0.8)"
      (\x o -> o { optJaccardThreshold = x })
  , IntFlag "min-size" "--min-size=N                         min candidate subtree size (default 3)"
      (\n o -> o { optMinSize = n })
  , IntFlag "wl-k" "--wl-k=N                             WL refinement depth (default 2)"
      (\n o -> o { optWlK = n })
  , IntFlag "wl-depth" "--wl-depth=N                         per-candidate subtree hop bound; 0 = unbounded (default)"
      (\n o -> o { optWlDepth = n })
  , EnumFlag "direction" "--direction=outgoing|incoming|both   which graph drives WL (default incoming)"
      (readDirection "direction") EnumVerbatim (\d o -> o { optDirection = d })
  , IntFlag "top-n" "--top-n=N                            clusters to keep (default 20)"
      (\n o -> o { optTopN = n })
  ]

-- | Hand-rolled CLI parser for the @fingerprint@ subcommand. See
-- 'AgdaOptimization.Motif.parseOptions' for the dispatch shape.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "fingerprint" flagSpecs

-- | Overlay the @fingerprint:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "fingerprint" flagSpecs obj o0

--------------------------------------------------------------------------------
-- WL adjacency for this analysis
--
-- Hashing, tags, refinement, fingerprints and union-find now live in
-- "AgdaGraph.WL" / "AgdaOptimization.UnionFind". Only the
-- direction-aware adjacency and rooted-subtree walk stay here.
--------------------------------------------------------------------------------

-- | Local neighbours of @i@ under the chosen direction.
neighboursOf :: Index -> Direction -> Int -> IS.IntSet
neighboursOf ix dir i = case dir of
  Outgoing      -> IM.findWithDefault IS.empty i (idxForward ix)
  Incoming      -> IM.findWithDefault IS.empty i (idxReverse ix)
  Bidirectional ->
    IS.union (IM.findWithDefault IS.empty i (idxForward ix))
             (IM.findWithDefault IS.empty i (idxReverse ix))

-- | Subtree limited to @maxDepth@ hops from @root@ under @dir@.
-- @maxDepth <= 0@ is treated as "unbounded" and falls through to the
-- library 'descendants' / 'ancestors' for the directional cases.  For
-- 'Bidirectional' we always BFS locally (the shared 'bfsUnbounded' /
-- 'bfsBoundedLayers').  The returned set always includes the root.
rootedSubtree :: Index -> Direction -> Int -> Int -> IS.IntSet
rootedSubtree ix dir maxDepth root
  | maxDepth <= 0 = case dir of
      Outgoing      -> IS.insert root (descendants ix (IS.singleton root))
      Incoming      -> IS.insert root (ancestors   ix (IS.singleton root))
      Bidirectional -> bfsUnbounded nbrs root
  | otherwise     = bfsBoundedLayers nbrs maxDepth root
  where
    nbrs = neighboursOf ix dir

-- | The per-candidate subtree hop bound actually used. Outgoing /
-- Incoming cones are bounded by the DAG, so an unbounded (0) depth is
-- fine. A 'Bidirectional' subtree closes over forward AND reverse edges,
-- so an unbounded walk reaches the whole weakly-connected component for
-- /every/ candidate — quadratic blow-up that made @--direction=both@
-- hang on real corpora. So a Bidirectional run with an unset (0)
-- wl-depth is auto-bounded to a local radius; an explicit @--wl-depth@
-- always wins.
effectiveWlDepth :: Options -> Int
effectiveWlDepth Options{..} = case optDirection of
  Bidirectional | optWlDepth <= 0 -> 1
  _                               -> optWlDepth

--------------------------------------------------------------------------------
-- Candidate selection
--------------------------------------------------------------------------------

-- | A candidate is a real (non-synthetic, non-KOther) node whose
-- rooted subtree is large enough.
data Cand = Cand
  { cId      :: !Int
  , cSubtree :: !IS.IntSet  -- includes root
  , cFp      :: !Fingerprint
  } -- not Show; we never print this whole thing.

instance NFData Cand where
  rnf (Cand i s f) = rnf i `seq` rnf s `seq` rnf f

candidates :: Index -> ColorVec -> Options -> [Cand]
candidates ix cols opts@Options{..} =
  let n   = idxNodeCount ix
      !effDepth = effectiveWlDepth opts
      mk i =
        let d = defAt ix i
        in if defKind d == KOther
             then Nothing
             else
               let !sub  = rootedSubtree ix optDirection effDepth i
                   !size = IS.size sub
               in if size < optMinSize
                    then Nothing
                    else
                      let !fp = fingerprintAt cols sub
                      in if IM.null fp
                           then Nothing
                           else Just (Cand i sub fp)
      -- Each candidate's rooted-subtree closure + fingerprint is an
      -- independent per-node computation; spark them (order-preserving
      -- parMap → identical candidate list and downstream numbering).
  in [ c | Just c <- parMap rdeepseq mk [0 .. n - 1] ]

--------------------------------------------------------------------------------
-- Owner extraction
--
-- The "owner" of a node is its containing top-level definition.  Pre-v3
-- a where-block helper inside @M.foo@ was given a qname like @M._.helper@
-- — note that the containing function name (@foo@) is /not/ in the
-- helper's qname, so a naive qname-strip can't recover it.
--
-- Insight: a where-helper @h@ is reverse-reachable only from its
-- containing top-level definition (and from its siblings, which are
-- themselves only reachable from that same containing def).  So we walk
-- the reverse-transitive closure and pick the candidate among the
-- non-@_@-segmented ancestors that shares the longest qname prefix.
--
-- Excluding same-owner pairs from cluster formation removes
-- where-helper noise without touching cross-owner duplicates.
--
-- As of producer @nodeKeyVersion@ 3 anonymous-module segments are lifted
-- away (@M._.helper@ ↦ @M.helper\@<line>@, re-homed to @M@), so a v3
-- helper has no @_@ segment and 'derivedOwner' self-owns it — the
-- noise-removal below is inert for v3 input (such helpers are ordinary
-- parent-module members), and still fires for any pre-v3 graph.
--------------------------------------------------------------------------------

-- | True when a qname has at least one dotted segment that is exactly
-- @_@ or starts with @_@.  Top-level defs are 'False'; where-block
-- helpers are 'True'.
hasUnderscoreSegment :: Text -> Bool
hasUnderscoreSegment q = any isUnderscoreSeg (T.splitOn "." q)
  where
    isUnderscoreSeg s = case T.uncons s of
      Just ('_', _) -> True            -- "_" itself, "_foo", etc.
      _             -> False

-- | Count the number of leading dot-segments shared by two qnames.
-- @sharedSegments "A.B.C" "A.B.D" == 2@; @sharedSegments "A.B" "X.Y" == 0@.
-- Used to break ties when several non-@_@ ancestors could plausibly own
-- a where-block helper.
sharedSegments :: Text -> Text -> Int
sharedSegments a b = go (T.splitOn "." a) (T.splitOn "." b) 0
  where
    go (x:xs) (y:ys) !n
      | x == y    = go xs ys (n + 1)
      | otherwise = n
    go _ _ !n     = n

-- | Qname-based fallback used only when the reverse-graph search finds
-- no non-@_@ ancestor (orphan helpers; should be vanishingly rare).
-- Strips trailing @_@-prefixed dot segments; if every segment is
-- dropped, returns the original name.
qnameFallbackOwner :: Text -> Text
qnameFallbackOwner q =
  let segs = T.splitOn "." q
      kept = reverse (dropWhile isUnderscoreSeg (reverse segs))
  in if null kept then q else T.intercalate "." kept
  where
    isUnderscoreSeg s = case T.uncons s of
      Just ('_', _) -> True
      _             -> False

-- | Owner /node id/ for candidate node @i@.  Returns @i@ for top-level
-- defs (fast path — no graph walk).  For where-block helpers, walks
-- 'ancestors' and picks the non-@_@-segmented ancestor sharing the
-- longest qname prefix with the helper (lex-asc tiebreak for
-- determinism).  Falls back to looking up 'qnameFallbackOwner' in the
-- name index if no such ancestor exists; if even that misses, returns
-- @i@ (self-own).
derivedOwner :: Index -> Int -> Int
derivedOwner ix i =
  let !nm = defName (defAt ix i)
  in if not (hasUnderscoreSegment nm)
       then i  -- top-level: own owner, skip the BFS entirely.
       else
         let !anc  = ancestors ix (IS.singleton i)
             -- Restrict to ancestors whose qname has no `_` segment —
             -- i.e. real top-level (or top-level-style) defs.
             !cands = [ (aId, defName (defAt ix aId))
                      | aId <- IS.toList anc
                      , let an = defName (defAt ix aId)
                      , not (hasUnderscoreSegment an) ]
         in case cands of
              [] -> qnameFallbackId ix nm i
              _  ->
                let -- longest-shared-prefix wins; tiebreak lex-asc on qname.
                    best (aId1, n1) (aId2, n2) =
                      let !s1 = sharedSegments nm n1
                          !s2 = sharedSegments nm n2
                      in case compare s1 s2 of
                           GT -> (aId1, n1)
                           LT -> (aId2, n2)
                           EQ -> if n1 <= n2 then (aId1, n1) else (aId2, n2)
                    (oid, _) = foldl1Strict best cands
                in oid

-- | Strict 'foldl1' over a non-empty list.
foldl1Strict :: (a -> a -> a) -> [a] -> a
foldl1Strict _ []     = error "foldl1Strict: empty list"
foldl1Strict f (x:xs) = foldl' f x xs

-- | Resolve a fallback-owner qname to a node id; if it can't be found
-- in the index (rare — would mean the stripped qname doesn't correspond
-- to any def), keep the helper as its own owner.
qnameFallbackId :: Index -> Text -> Int -> Int
qnameFallbackId ix nm self =
  case HM.lookup (qnameFallbackOwner nm) (idxNameToId ix) of
    Just o  -> o
    Nothing -> self

--------------------------------------------------------------------------------
-- Cluster construction
--------------------------------------------------------------------------------

-- | Result of pair scoring: the surviving similarity edges, plus the
-- count of pairs skipped because both endpoints share an owner.
data ScoreResult = ScoreResult
  { srEdges   :: ![SimEdge]
  , srSkipped :: !Int
  }

-- | Score all O(N^2 / 2) pairs of candidates, keeping only those at or
-- above the threshold.  Pairs where both endpoints share an owner are
-- excluded entirely (no similarity computed) — this drops the
-- where-block helper noise without touching the fingerprinting math.
-- N is the number of /candidates/, not nodes.
--
-- Owners are encoded as 'Int' node ids (see 'derivedOwner'); the
-- pair-skip is a single 'Int' comparison.
scorePairs :: Double -> Vector Cand -> V.Vector Int -> ScoreResult
scorePairs thr cs owners =
  let !n = V.length cs
      -- Per-i: walk j ∈ [i+1, n) and emit (skipCount_i, edges_i). The
      -- list of edges is force-deep'd by 'rdeepseq' below; the
      -- '(Int, [SimEdge])' tuple is strict in the Int and the list
      -- spine is finite, so deepseq fully evaluates each spark.
      perI :: Int -> (Int, [SimEdge])
      perI !i =
        let !oi = owners V.! i
            !ci = cs V.! i
            go !j !skipAcc !acc
              | j >= n    = (skipAcc, acc)
              | otherwise =
                  let !oj = owners V.! j
                  in if oi == oj
                       then go (j + 1) (skipAcc + 1) acc
                       else
                         let !cj = cs V.! j
                             !s  = weightedJaccard (cFp ci) (cFp cj)
                             !acc' = if s >= thr then (i, j, s) : acc else acc
                         in go (j + 1) skipAcc acc'
        in go (i + 1) 0 []
      chunks    = parMap rdeepseq perI [0 .. n - 1]
      !totSkip  = foldl' (\acc (k, _) -> acc + k) 0 chunks
      -- Edge order must be: i = n-2 first, then n-3, ..., then 0, with
      -- j descending within each i. Reversing the per-i chunk list
      -- preserves that order, which keeps union-find representative
      -- selection (and downstream cluster numbering) deterministic.
      !allEdges = concatMap snd (reverse chunks)
  in ScoreResult allEdges totSkip

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- | Run the analysis.  Loads nothing — the 'Index' is the caller's
-- responsibility — and emits either a human-readable report or a
-- compact JSON object depending on @gOutFormat gOpts@.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = do
  when (effectiveWlDepth opts /= optWlDepth) $
    hPutStrLn stderr $
      "[fingerprint] --direction=both with unbounded depth auto-bounded to "
        ++ "wl-depth=" ++ show (effectiveWlDepth opts)
        ++ " (an unbounded bidirectional subtree spans the whole component "
        ++ "per candidate); pass --wl-depth=N to override."
  let !c0        = initialColors ix (neighboursOf ix optDirection)
      !ck        = refine ix (neighboursOf ix optDirection) optWlK c0
      !candList  = candidates ix ck opts
      !candVec   = V.fromList candList
      !nCand     = V.length candVec
      -- Owner (node id) per candidate index.  Computed once; the
      -- pair-skip in 'scorePairs' is a single Int comparison.
      !ownerVec  = V.map (derivedOwner ix . cId) candVec
      !result    = scorePairs optJaccardThreshold candVec ownerVec
      !edges     = srEdges result
      !nSkipped  = srSkipped result
      !nTotal    = nCand * (nCand - 1) `div` 2
      !nPairs    = nTotal - nSkipped
      !nScored   = length edges
      !clusters  = clustersOfSize2 nCand edges
      !nClus     = length clusters
      !largest   = if null clusters then 0 else maximum (map length clusters)
      -- Sort clusters by size desc; cap at --top-n.
      !sortedClusters =
        take (max 0 optTopN) $ sortBy (comparing (Down . length)) clusters

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        fingerprintJson ix opts candVec edges
                        nCand nPairs nSkipped nScored nClus largest
                        sortedClusters
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      -- Direction and top-n always surface; wl-depth only when non-default.
      let !dirExtra   = ", direction=" ++ directionLabel optDirection
          !depthExtra =
            if optWlDepth == 0
              then ""
              else ", wl-depth=" ++ wlDepthLabel optWlDepth
      putStrLn $ "# ProofPrint — near-duplicate clusters "
              ++ "(k=" ++ show optWlK
              ++ ", jaccard>=" ++ printf "%.2f" optJaccardThreshold
              ++ ", min-size=" ++ show optMinSize
              ++ dirExtra
              ++ depthExtra
              ++ ", top-n=" ++ show optTopN
              ++ ")"
      putStrLn ""
      putStrLn $ "candidates considered    : " ++ show nCand
      putStrLn $ "pairs evaluated          : " ++ show nPairs
      putStrLn $ "pairs above threshold    : " ++ show nScored
      putStrLn $ "pairs skipped (same owner): " ++ show nSkipped
      putStrLn $ "clusters found           : " ++ show nClus
      putStrLn $ "largest cluster          : " ++ show largest
      putStrLn ""

      if null clusters
        then putStrLn "no near-duplicates above threshold."
        else do
          forM_ (zip [(1 :: Int) ..] sortedClusters) $ \(i, members) -> do
            let !avgSim = clusterAvgSim optJaccardThreshold edges members
            putStrLn $ "Cluster #" ++ show i
                    ++ " — " ++ show (length members) ++ " members"
                    ++ ", avg sim " ++ printf "%.3f" avgSim
            -- Sort members within a cluster by subtree size desc for a
            -- predictable, easy-to-eyeball printout.
            let sortedMembers =
                  sortOn (Down . IS.size . cSubtree . (candVec V.!)) members
            forM_ sortedMembers $ \memIdx -> do
              let c   = candVec V.! memIdx
                  d   = defAt ix (cId c)
                  sz  = IS.size (cSubtree c)
              putStrLn $ "  - " ++ T.unpack (defName d)
                      ++ " (" ++ T.unpack (defModule d) ++ ")"
                      ++ " [" ++ stateLabel (defState d) ++ "]"
                      ++ "  size=" ++ show sz
            when (length members >= 3) $
              putStrLn "    -> same shape; consider unifying / generalising"
            putStrLn ""

----------------------------------------------------------------------
-- JSON rendering. See the schema in 'AgdaOptimization.Report'.

fingerprintJson
  :: Index
  -> Options
  -> Vector Cand     -- ^ All candidates, indexed by candidate id.
  -> [SimEdge]       -- ^ Similarity edges (post-threshold).
  -> Int             -- ^ candidates considered
  -> Int             -- ^ pairs evaluated
  -> Int             -- ^ pairs skipped (same owner)
  -> Int             -- ^ pairs above threshold
  -> Int             -- ^ clusters found
  -> Int             -- ^ largest cluster
  -> [[Int]]         -- ^ Sorted clusters (size desc, capped).
  -> A.Value
fingerprintJson ix opts candVec edges
                nCand nPairs nSkipped nScored nClus largest sortedClusters =
  A.object
    [ "subcommand" .= ("fingerprint" :: Text)
    , "options"    .= fingerprintOptionsJson opts
    , "stats"      .= A.object
        [ "candidates_considered"  .= nCand
        , "pairs_evaluated"        .= nPairs
        , "pairs_skipped_same_owner" .= nSkipped
        , "pairs_above_threshold"  .= nScored
        , "clusters_found"         .= nClus
        , "largest_cluster"        .= largest
        ]
    , "clusters" .= A.toJSON
        (zipWith (clusterJson ix candVec edges (optJaccardThreshold opts))
                 [1 :: Int ..] sortedClusters)
    ]

fingerprintOptionsJson :: Options -> A.Value
fingerprintOptionsJson Options{..} = A.object
  [ "wl_k"               .= optWlK
  , "jaccard_threshold"  .= optJaccardThreshold
  , "min_size"           .= optMinSize
  , "direction"          .= directionLabel optDirection
  , "wl_depth"           .= optWlDepth
  , "top_n"              .= optTopN
  ]

-- | Lower-case wire label for 'Direction'.
directionLabel :: Direction -> String
directionLabel d = case d of
  Outgoing      -> "outgoing"
  Incoming      -> "incoming"
  Bidirectional -> "both"

-- | Human label for the @wl-depth@ field: @∞@ at the unbounded
-- sentinel, otherwise the integer.
wlDepthLabel :: Int -> String
wlDepthLabel n
  | n <= 0    = "∞"
  | otherwise = show n

clusterJson
  :: Index
  -> Vector Cand
  -> [SimEdge]
  -> Double
  -> Int
  -> [Int]
  -> A.Value
clusterJson ix candVec edges thr clusterRank members =
  let !avgSim = clusterAvgSim thr edges members
      sortedMembers =
        sortOn (Down . IS.size . cSubtree . (candVec V.!)) members
      memberJson memIdx =
        let c  = candVec V.! memIdx
            d  = defAt ix (cId c)
            sz = IS.size (cSubtree c)
        in A.object
             [ "qname"        .= defName d
             , "module"       .= defModule d
             , "state"        .= stateLabel (defState d)
             , "subtree_size" .= sz
             ]
  in A.object
       [ "cluster"        .= clusterRank
       , "size"           .= length members
       , "avg_similarity" .= avgSim
       , "members"        .= A.toJSON (map memberJson sortedMembers)
       ]

-- | Single-character label matching the producer's wire encoding.
stateLabel :: State -> String
stateLabel s = case s of
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"
