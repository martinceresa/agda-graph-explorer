{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Chokepoint analysis: node-capacitated min-cut + articulation points
-- on the SCC condensation of the dependency graph.
--
-- Where 'AgdaOptimization.LoadBearing' ranks /frequency/ — popular nodes
-- on many critical paths — this analysis ranks /non-redundancy/: nodes
-- that sit on a /funnel of width 1/ between an exported-theorem cluster
-- and a postulate-axiom cluster. A node may sit on few critical paths
-- yet be the only connector between top and bottom; betweenness misses
-- that, min-cut catches it.
--
-- Algorithm summary (operates on the SCC condensation):
--
--   1. Pick a source set @S@ (exported theorems) and a sink set @T@
--      (postulates / axioms / stdlib leaves). Map each set up to the
--      enclosing SCCs.
--   2. Build a node-capacitated flow network:
--        * for every SCC @v@: split into @v_in -> v_out@ with capacity
--          @1 / (LOC + 1)@ — cheap-to-delete nodes float, expensive
--          ones are unlikely cuts.
--        * for every condensation edge @u -> v@: @u_out -> v_in@ with
--          infinite capacity.
--        * super-source -> every source SCC's @_in@ (infinite); every
--          sink SCC's @_out@ -> super-sink (infinite).
--   3. Run Edmonds–Karp (BFS-based max-flow) on it.
--   4. Min-cut extraction: BFS from the super-source on the /residual/
--      graph; SCCs whose @v_in@ is reachable and @v_out@ is not are
--      min-cut nodes.
--   5. Independently run Tarjan articulation points on the symmetrised
--      condensation as a corroborating "single-bridge" signal.
--   6. Score each candidate by
--      @cutMultiplicity * |ancestors(v)| * |descendants(v)|@. We
--      approximate @cutMultiplicity@ as 1 for any node in the min-cut
--      and 0 otherwise (true min-cut multiplicity is hard; deferred).
--      Articulation points get a 1.5x bonus.
--
-- Capacity scaler note: the LOC weight is a /capacity/, not an LOC
-- count. We default to 1.0 when 'defLine' is 'Nothing' and to
-- @1 / (defLine + 1)@ otherwise. The number itself is not LOC — it's
-- a unitless preference signal that biases the cut toward shallow
-- nodes. Document this on the user-facing surface so it isn't
-- mistaken for a line count.
module AgdaOptimization.Chokepoint
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq           ( NFData(..) )
import           Control.Monad             ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           AgdaOptimization.Condense ( Condensation(..), buildCondensation )
import qualified Data.IntMap.Strict        as IM
import qualified Data.IntSet               as IS
import           Data.List                 ( sortBy )
import           Data.Maybe                ( isNothing )
import           Data.Ord                  ( Down(..), comparing )
import qualified Data.Sequence             as Seq
import           Data.Sequence             ( Seq, ViewL(..) )
import           Data.Text                 ( Text )
import qualified Data.Text                 as T
import qualified Data.Vector               as V
import           System.Exit               ( exitFailure )
import           System.IO                 ( hPutStrLn, stderr )

import qualified Data.Aeson                as A
import           Data.Aeson                ( (.=) )

import           AgdaGraph.Index           ( Index(..), ancestors, defAt
                                           , descendants )
import           AgdaGraph.Schema          ( Access(..), Definition(..)
                                           , Kind(..), State(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Common ( computeExcludedSet, isFoundationalModule, terminals )
import           AgdaOptimization.Report   ( GlobalOpts(..), OutFormat(..)
                                           , emitJsonReport, renderTable
                                           , showD3, withHumanReport )

------------------------------------------------------------------------
-- Public surface
------------------------------------------------------------------------

-- | How to pick the source set @S@. Constructor 'AllPublic' is
-- spelled @public@ on the CLI; the longer Haskell name avoids
-- shadowing 'AgdaGraph.Schema.Access.Public'.
data SrcMode
  = ExportedTheorems
    -- ^ Public defs with @defKind /= KOther@ that are not in
    -- @Agda.Builtin.*@/@Agda.Primitive.*@. Default.
  | AllPublic
    -- ^ All public defs, without the prelude filter. CLI: @public@.
  | Terminals
    -- ^ Nodes with no /inbound/ edge (no users — true API tops).
  deriving (Show, Eq)

-- | How to pick the sink set @T@.
data SinkMode
  = PostulatesAxioms
    -- ^ Defs with @defState = Postulate@. Default.
  | TerminalLeaves
    -- ^ Nodes with no /outbound/ edge in the condensation (true sinks
    -- of the dep DAG — they don't depend on anything else visible).
  deriving (Show, Eq)

data Options = Options
  { optTopN             :: !Int
  , optSources          :: !SrcMode
  , optSinks            :: !(Maybe SinkMode)
    -- ^ 'Nothing' = user didn't pass @--sinks@; resolves to
    -- 'PostulatesAxioms' by default but is eligible for the empty-set
    -- fallback to 'TerminalLeaves'. 'Just m' = explicit user choice;
    -- no fallback fires.
  , optExcludeNameRegex :: !Text
    -- ^ POSIX-ERE applied to each def's /unqualified/ name (last
    -- dot-component). Matching nodes are dropped from the candidate
    -- pool before ranking. Empty string disables.
  } deriving (Show)

-- | Resolved default sink mode when the user didn't specify one.
defaultSinkMode :: SinkMode
defaultSinkMode = PostulatesAxioms

-- | Resolve 'optSinks' to a concrete 'SinkMode' for reporting and
-- selection. 'Nothing' becomes 'defaultSinkMode'.
resolvedSinkMode :: Options -> SinkMode
resolvedSinkMode = maybe defaultSinkMode id . optSinks

defaultOptions :: Options
defaultOptions = Options
  { optTopN             = 50
  , optSources          = ExportedTheorems
  , optSinks            = Nothing
  , optExcludeNameRegex = T.empty
  }

parseSrc :: String -> Either String SrcMode
parseSrc "exported"  = Right ExportedTheorems
parseSrc "public"    = Right AllPublic
parseSrc "terminals" = Right Terminals
parseSrc v           = Left $
  "expected one of exported|public|terminals, got " <> show v

parseSink :: String -> Either String SinkMode
parseSink "postulates-axioms" = Right PostulatesAxioms
parseSink "terminal-leaves"   = Right TerminalLeaves
parseSink v                   = Left $
  "expected one of postulates-axioms|terminal-leaves, got " <> show v

-- | Declarative flag spec for the @chokepoint@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
--
-- @--sources@ / @--sinks@ are enum flags whose parser @Left@ is a bare
-- @"expected one of …"@, surfaced verbatim on the argv side
-- ('EnumVerbatim'). A YAML-provided @sinks@ sets 'optSinks' to
-- @Just _@, matching the "user explicitly chose" semantics — the
-- empty-set fallback to 'TerminalLeaves' is suppressed.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "top-n" "--top-n=N                                    rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , EnumFlag "sources" "--sources=exported|public|terminals          source-set selector (default exported)"
      parseSrc EnumVerbatim (\r o -> o { optSources = r })
  , EnumFlag "sinks" "--sinks=postulates-axioms|terminal-leaves    sink-set selector (default postulates-axioms)"
      parseSink EnumVerbatim (\r o -> o { optSinks = Just r })
  , TextFlag "exclude-name-regex" "--exclude-name-regex=PATTERN                 POSIX-ERE on unqualified name"
      (\p o -> o { optExcludeNameRegex = p })
  ]

-- | Hand-rolled CLI parser for the @chokepoint@ subcommand.
--
-- Flags:
--
--   * @--top-n=N@                   — rank cutoff (default 50)
--   * @--sources=exported|public|terminals@ (default @exported@)
--   * @--sinks=postulates-axioms|terminal-leaves@ (default
--     @postulates-axioms@)
--   * @--exclude-name-regex=PATTERN@ — POSIX-ERE excludes by short
--     name; empty disables.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "chokepoint" flagSpecs

-- | Overlay the @chokepoint:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "chokepoint" flagSpecs obj o0

------------------------------------------------------------------------
-- Source / sink selection
------------------------------------------------------------------------

-- | Compute the source set (in /original/ node ids). See 'SrcMode'.
pickSources :: Index -> SrcMode -> IS.IntSet
pickSources !ix = \case
  ExportedTheorems ->
    V.ifoldl' addExp IS.empty (idxDefs ix)
    where
      addExp !acc i d
        | defAccess d == Public
        , defKind d /= KOther
        , not (isFoundationalModule (defModule d))
        = IS.insert i acc
        | otherwise = acc
  AllPublic ->
    V.ifoldl' addPub IS.empty (idxDefs ix)
    where
      addPub !acc i d
        | defAccess d == Public = IS.insert i acc
        | otherwise             = acc
  Terminals ->
    terminals ix

-- | Compute the sink set (in /original/ node ids). See 'SinkMode'.
pickSinks :: Index -> Condensation -> SinkMode -> IS.IntSet
pickSinks !ix !cond = \case
  PostulatesAxioms ->
    V.ifoldl' addP IS.empty (idxDefs ix)
    where
      addP !acc i d
        | defState d == Postulate = IS.insert i acc
        | otherwise               = acc
  TerminalLeaves ->
    -- Sinks of the /condensation/: SCCs with no forward edges. Members
    -- of those SCCs (mapped back to original ids) form the sink set.
    let outSCCs =
          IS.fromList
            [ scc
            | scc <- IM.keys (cdMembers cond)
            , IS.null (IM.findWithDefault IS.empty scc (cdForward cond))
            ]
    in IS.unions
         [ IM.findWithDefault IS.empty s (cdMembers cond)
         | s <- IS.toList outSCCs
         ]

------------------------------------------------------------------------
-- Max-flow / min-cut over the condensation
------------------------------------------------------------------------

-- | A node-split flow network over the condensation.
--
-- We assign two flow-network node ids to each SCC:
--
-- @
--   v_in  = 2 * v
--   v_out = 2 * v + 1
-- @
--
-- The two extra ids @2*N@ (super-source) and @2*N + 1@ (super-sink)
-- bracket the network; @flowNodeCount = 2*N + 2@.
data Flow = Flow
  { flowN          :: !Int
    -- ^ Number of /condensation/ SCCs.
  , flowSuper      :: !Int
    -- ^ Super-source flow id (= @2 * flowN@).
  , flowSink       :: !Int
    -- ^ Super-sink flow id (= @2 * flowN + 1@).
  , flowCap        :: !(IM.IntMap (IM.IntMap Double))
    -- ^ Residual capacities. Entry @(u, v) -> c@ means @c@ units can
    -- still flow from @u@ to @v@. Both directions present for every
    -- edge so backward augmentation works.
  }

inFlowId, outFlowId :: Int -> Int
inFlowId  v = 2 * v
outFlowId v = 2 * v + 1

-- | Sentinel "infinite" capacity. A large finite value keeps the
-- residual-graph arithmetic free of NaNs from @inf - inf@.
infCap :: Double
infCap = 1e18

-- | Build the flow network from the condensation + chosen source/sink
-- SCC sets + a per-SCC node-capacity function.
buildFlow
  :: Condensation
  -> IS.IntSet                    -- ^ source SCC ids
  -> IS.IntSet                    -- ^ sink   SCC ids
  -> (Int -> Double)              -- ^ per-SCC capacity (@v_in -> v_out@)
  -> Flow
buildFlow !cond !srcSccs !sinkSccs !capOf =
  let n     = cdCount cond
      super = 2 * n
      sink  = 2 * n + 1

      addEdge :: IM.IntMap (IM.IntMap Double) -> Int -> Int -> Double
              -> IM.IntMap (IM.IntMap Double)
      addEdge !m u v !c =
        let -- forward
            !m1 = IM.insertWith (IM.unionWith (+)) u
                    (IM.singleton v c) m
            -- reverse arc with zero capacity, only if missing
            insZero mm =
              IM.insertWith (\_ old -> old) v
                (IM.singleton u 0) mm
            !m2 = insZero m1
        in m2

      -- 1. Node-capacity edges v_in -> v_out.
      step1 = foldl' (\acc v -> addEdge acc (inFlowId v) (outFlowId v) (capOf v))
                     IM.empty
                     [0 .. n - 1]

      -- 2. Condensation edges u -> v become u_out -> v_in with
      --    infinite capacity (no node-cap on the edge itself).
      step2 = IM.foldlWithKey'
                (\acc u tgts ->
                   IS.foldl' (\m v -> addEdge m (outFlowId u) (inFlowId v) infCap)
                             acc tgts)
                step1 (cdForward cond)

      -- 3. Super-source -> every source SCC's v_in.
      step3 = IS.foldl' (\acc v -> addEdge acc super (inFlowId v) infCap)
                        step2 srcSccs

      -- 4. Every sink SCC's v_out -> super-sink.
      step4 = IS.foldl' (\acc v -> addEdge acc (outFlowId v) sink infCap)
                        step3 sinkSccs

  in Flow { flowN     = n
          , flowSuper = super
          , flowSink  = sink
          , flowCap   = step4
          }

-- | Edmonds–Karp: BFS for augmenting paths until none exist. Returns
-- the final residual graph and the max-flow value.
--
-- Tolerance on path-bottleneck: stop pushing if the bottleneck falls
-- below 'epsCap' — otherwise tiny residuals from floating-point
-- subtraction would keep us pushing forever.
edmondsKarp :: Flow -> (IM.IntMap (IM.IntMap Double), Double)
edmondsKarp !flow0 = loop (flowCap flow0) 0
  where
    src = flowSuper flow0
    snk = flowSink  flow0

    loop !cap !acc = case bfsPath cap src snk of
      Nothing                  -> (cap, acc)
      Just (path, bottleneck)
        | bottleneck <= epsCap -> (cap, acc)
        | otherwise            ->
            let !cap' = applyAugment cap path bottleneck
                !acc' = acc + bottleneck
            in loop cap' acc'

-- | Below this residual we treat the edge as saturated. Picked
-- conservatively low so legitimate small-capacity edges (e.g. 1/1001
-- ~ 1e-3) survive but FP cruft doesn't.
epsCap :: Double
epsCap = 1e-12

-- | BFS for the shortest (in hops) augmenting path. Returns the path
-- as a list of nodes from source to sink plus the bottleneck capacity.
bfsPath
  :: IM.IntMap (IM.IntMap Double)
  -> Int                        -- ^ source
  -> Int                        -- ^ sink
  -> Maybe ([Int], Double)
bfsPath !cap !src !snk = go (Seq.singleton src) (IM.singleton src (-1))
  where
    go :: Seq Int -> IM.IntMap Int -> Maybe ([Int], Double)
    go q !parent = case Seq.viewl q of
      EmptyL    -> Nothing
      cur :< qs
        | cur == snk -> Just (reconstruct parent, bottleneckOf cap parent snk)
        | otherwise  ->
            let nbrs = IM.findWithDefault IM.empty cur cap
                (q', parent') =
                  IM.foldlWithKey' (visit cur) (qs, parent) nbrs
            in go q' parent'

    visit !cur (!q, !p) !nxt !c
      | c > epsCap
      , not (IM.member nxt p) = (q Seq.|> nxt, IM.insert nxt cur p)
      | otherwise             = (q, p)

    reconstruct parent = walk snk []
      where
        walk !n acc =
          let par = IM.findWithDefault (-1) n parent
          in if par < 0 then n : acc else walk par (n : acc)

-- | Bottleneck along the parent-pointer path from source to sink.
bottleneckOf
  :: IM.IntMap (IM.IntMap Double)
  -> IM.IntMap Int
  -> Int
  -> Double
bottleneckOf cap parent !snk = walk snk infCap
  where
    walk !n !b =
      let par = IM.findWithDefault (-1) n parent
      in if par < 0
           then b
           else
             let !e = IM.findWithDefault 0 n (IM.findWithDefault IM.empty par cap)
                 !b' = min b e
             in walk par b'

-- | Subtract the augmenting flow along every edge on the path and add
-- it back along each reverse edge.
applyAugment
  :: IM.IntMap (IM.IntMap Double)
  -> [Int]
  -> Double
  -> IM.IntMap (IM.IntMap Double)
applyAugment cap0 (a:b:rest) f =
  let !cap' = bump cap0 a b (negate f)
      !cap'' = bump cap' b a f
  in applyAugment cap'' (b:rest) f
applyAugment cap0 _ _ = cap0

-- | @bump cap u v d@ updates residual @cap[u][v] += d@. Creates
-- missing entries as needed.
bump :: IM.IntMap (IM.IntMap Double) -> Int -> Int -> Double
     -> IM.IntMap (IM.IntMap Double)
bump !cap !u !v !d =
  IM.insertWith (IM.unionWith (+)) u (IM.singleton v d) cap

------------------------------------------------------------------------
-- Min-cut extraction
------------------------------------------------------------------------

-- | After max-flow, BFS from super-source on the /residual/ graph
-- (edges with positive remaining capacity). Returns the set of flow
-- nodes reachable from the source — that's the S-side of the min-cut.
sSideNodes :: IM.IntMap (IM.IntMap Double) -> Int -> IS.IntSet
sSideNodes !cap !src = go (Seq.singleton src) (IS.singleton src)
  where
    go :: Seq Int -> IS.IntSet -> IS.IntSet
    go q !seen = case Seq.viewl q of
      EmptyL    -> seen
      cur :< qs ->
        let nbrs = IM.findWithDefault IM.empty cur cap
            (!q', !seen') = IM.foldlWithKey' (step cur) (qs, seen) nbrs
        in go q' seen'

    step _cur (!q, !s) !nxt !c
      | c > epsCap, not (IS.member nxt s) = (q Seq.|> nxt, IS.insert nxt s)
      | otherwise                         = (q, s)

-- | A condensation SCC @v@ is in the min-cut iff its @v_in@ is on the
-- S-side and its @v_out@ is on the T-side (i.e. the only saturated
-- edge crossed by the cut is the internal node-capacity edge).
minCutSCCs :: Flow -> IS.IntSet -> IS.IntSet
minCutSCCs !flow !sSide =
  let n = flowN flow
      go !acc v
        | v >= n = acc
        | otherwise =
            let vi = inFlowId v
                vo = outFlowId v
            in if IS.member vi sSide && not (IS.member vo sSide)
                 then go (IS.insert v acc) (v + 1)
                 else go acc (v + 1)
  in go IS.empty 0

------------------------------------------------------------------------
-- Tarjan articulation points (on the symmetrised condensation)
------------------------------------------------------------------------

-- | Symmetrise the condensation: combine forward + reverse adjacency
-- into one undirected map.
symmetrise :: Condensation -> IM.IntMap IS.IntSet
symmetrise !cond =
  let fwd = cdForward cond
      rev = cdReverse cond
  in IM.unionWith IS.union fwd rev

-- | Tarjan articulation points on an undirected graph (here the
-- symmetrised SCC condensation). Recursive DFS with threaded state.
--
-- An undirected node @v@ is articulation iff:
--
--   * it's a DFS root with at least 2 DFS-tree children, OR
--   * it's a non-root with some child @c@ such that
--     @low[c] >= disc[v]@.
--
-- Threaded state:
--
--   * @time@: monotonic timestamp counter
--   * @disc@: discovery time per node
--   * @low@:  low-link per node
--   * @parent@: DFS parent (or @-1@ for a root)
--   * @aps@: articulation-point set being accumulated
articulationPoints' :: Int -> IM.IntMap IS.IntSet -> IS.IntSet
articulationPoints' !n !adj =
  let go !time !disc !low !parent !aps !node
        | IM.member node disc = (time, disc, low, parent, aps)
        | otherwise =
            let !disc1 = IM.insert node time disc
                !low1  = IM.insert node time low
                !time1 = time + 1
                nbrs   = IS.toList (IM.findWithDefault IS.empty node adj)
                (!time', !disc', !low', !parent', !aps', !childCount) =
                  foldl' (visit node) (time1, disc1, low1, parent, aps, 0 :: Int) nbrs
                par = IM.findWithDefault (-1) node parent'
                -- Articulation conditions:
                --   * root with ≥ 2 children
                --   * non-root with some child c where low[c] >= disc[node]
                --
                -- The non-root branch is handled inside 'visit' (we add
                -- the node to 'aps' there as soon as we find such a
                -- child). Here we only handle the root case.
                aps''
                  | par == -1 && childCount >= 2 = IS.insert node aps'
                  | otherwise                    = aps'
            in (time', disc', low', parent', aps'')

      visit cur (!t, !d, !l, !p, !a, !cc) !nb
        | IM.member nb d =
            -- Back edge: update low[cur] = min(low[cur], disc[nb])
            -- but only when nb isn't the DFS parent.
            if IM.findWithDefault (-1) cur p == nb
              then (t, d, l, p, a, cc)
              else
                let !lCur = IM.findWithDefault t cur l
                    !lNb  = IM.findWithDefault t nb d
                    !l'   = IM.insert cur (min lCur lNb) l
                in (t, d, l', p, a, cc)
        | otherwise =
            -- Tree edge: recurse, then post-process.
            let !p1 = IM.insert nb cur p
                (!t2, !d2, !l2, !p2, !a2) = go t d l p1 a nb
                !lCur  = IM.findWithDefault t2 cur l2
                !lNb   = IM.findWithDefault t2 nb l2
                !l3    = IM.insert cur (min lCur lNb) l2
                discCur = IM.findWithDefault t2 cur d2
                a3
                  | IM.findWithDefault (-1) cur p2 /= -1
                  , lNb >= discCur
                  = IS.insert cur a2
                  | otherwise
                  = a2
            in (t2, d2, l3, p2, a3, cc + 1)

      stepRoot (!time, !disc, !low, !parent, !aps) !v
        | IM.member v disc = (time, disc, low, parent, aps)
        | otherwise =
            let !parent1 = IM.insert v (-1) parent
                (!t', !d', !l', !p', !a') =
                  go time disc low parent1 aps v
            in (t', d', l', p', a')

      (_, _, _, _, !result) =
        foldl' stepRoot (0 :: Int, IM.empty, IM.empty, IM.empty, IS.empty)
               [0 .. n - 1]
  in result

------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------

-- | Entry point. Compiles the source/sink sets, runs max-flow once,
-- extracts the min-cut, runs articulation independently, scores and
-- ranks.
run :: Index -> GlobalOpts -> Options -> IO ()
run !ix !gOpts !opts = do
  let !defs       = idxDefs ix
      !srcSet     = pickSources ix (optSources opts)
      !cond       = buildCondensation ix
      !primaryMode = resolvedSinkMode opts
      !sinkSetTry  = pickSinks ix cond primaryMode
      !excluded   = computeExcludedSet ix (optExcludeNameRegex opts)
      !sccOf      = cdSccOf cond
      !members    = cdMembers cond

      sccsOf s    = IS.fromList [ IM.findWithDefault (-1) v sccOf | v <- IS.toList s ]
      !srcSccs0   = sccsOf srcSet

      -- The default 'postulates-axioms' sink set is "unusable" when it is
      -- empty (symptomatic of 'agda-deps --no-externals' having stripped
      -- the @Agda.Builtin.*@/@Agda.Primitive.*@ axioms) OR when its SCCs
      -- are fully swallowed by the source SCCs (the only postulates are
      -- themselves exported, so there is nothing downstream to cut — the
      -- common shape on a --no-externals project graph). Either way we
      -- silently fall back to 'terminal-leaves' so the run yields a cut
      -- instead of exiting 1. The fallback fires only when the user did
      -- NOT pass --sinks explicitly; an explicit '--sinks=postulates-axioms'
      -- is honoured as-is and the downstream empty/overlap diagnostics fire.
      !primaryUnusable = IS.null sinkSetTry
                      || IS.null (IS.difference (sccsOf sinkSetTry) srcSccs0)
      !fallbackEligible = isNothing (optSinks opts)
                       && primaryMode == PostulatesAxioms
                       && primaryUnusable
      !usedMode
        | fallbackEligible = TerminalLeaves
        | otherwise        = primaryMode
      !sinkSet
        | fallbackEligible = pickSinks ix cond TerminalLeaves
        | otherwise        = sinkSetTry

  -- Abort on empty source set (no useful fallback — Debt-style diagnostic).
  when (IS.null srcSet) $ do
    hPutStrLn stderr $
      "[chokepoint] error: empty source set (mode=" ++ srcModeTag (optSources opts)
        ++ "). Try a different --sources."
    exitFailure

  -- Announce the sink fallback before any downstream stderr noise.
  when fallbackEligible $
    hPutStrLn stderr $
         "[chokepoint] note: --sinks=postulates-axioms resolved to empty or "
      ++ "fully overlapped the sources\n"
      ++ "             (likely --no-externals upstream); falling back to "
      ++ "--sinks=terminal-leaves.\n"
      ++ "             Pass --sinks=postulates-axioms explicitly to error instead."

  when (IS.null sinkSet) $ do
    -- Even the fallback came up empty (or the user explicitly asked
    -- for postulates-axioms and there are none). This is a real
    -- "no axiom sinks anywhere" state; exit 1.
    hPutStrLn stderr $
      "[chokepoint] error: empty sink set (mode=" ++ sinkModeTag usedMode
        ++ "). Try a different --sinks."
    exitFailure
  when (not (IS.null excluded)) $
    hPutStrLn stderr $
      "[chokepoint] excluded " ++ show (IS.size excluded)
        ++ " definitions matching " ++ T.unpack (optExcludeNameRegex opts) ++ "."

  -- Lift to SCC ids. A source/sink SCC contains at least one
  -- source/sink original node.
  let srcSccSet  = srcSccs0
      sinkSccSet = IS.fromList
                     [ IM.findWithDefault (-1) v sccOf | v <- IS.toList sinkSet ]
      -- Disjointness: if a source SCC is also a sink SCC, drop it from
      -- the sink set so flow has somewhere to go. Without this the
      -- super-source -> v_in -> v_out -> super-sink path is always
      -- saturable with infinite capacity on its bracketing edges.
      sinkSccs   = IS.difference sinkSccSet srcSccSet
      n          = cdCount cond
      capOf v    = sccCapacity ix members v

  when (IS.null sinkSccs) $ do
    -- Rather than a generic "try a different combo", probe every
    -- --sources/--sinks pairing and name the ones that would actually
    -- yield a non-empty disjoint sink SCC set on THIS graph.
    let disjointN sm km =
          IS.size (IS.difference (sccsOf (pickSinks ix cond km)) (sccsOf (pickSources ix sm)))
        combos      = [ (sm, km) | sm <- [ExportedTheorems, AllPublic, Terminals]
                                 , km <- [PostulatesAxioms, TerminalLeaves] ]
        working     = [ (sm, km, c) | (sm, km) <- combos, let c = disjointN sm km, c > 0 ]
    hPutStrLn stderr
      "[chokepoint] error: source and sink SCC sets overlap completely; nothing to cut."
    if null working
      then hPutStrLn stderr $
             "             No --sources/--sinks combination yields disjoint sets on this\n"
          ++ "             graph. This is typical of a graph built with `agda-deps\n"
          ++ "             --no-externals`, which strips the Agda.Builtin.*/Primitive axiom\n"
          ++ "             layer that the theorems->axioms cut needs as sinks. Re-run\n"
          ++ "             chokepoint on the full graph (without --no-externals)."
      else do
        hPutStrLn stderr
          "             Combinations that WOULD yield a cut (disjoint sink SCCs in parens):"
        mapM_ (\(sm, km, c) -> hPutStrLn stderr $
                 "               --sources=" ++ srcModeTag sm
                   ++ " --sinks=" ++ sinkModeTag km ++ "  (" ++ show c ++ ")") working
    exitFailure

  hPutStrLn stderr $
    "[chokepoint] |V|=" ++ show (V.length defs)
      ++ ", |SCC|=" ++ show n
      ++ ", |S|="   ++ show (IS.size srcSet)
      ++ ", |T|="   ++ show (IS.size sinkSet)
      ++ ", |srcSCC|=" ++ show (IS.size srcSccSet)
      ++ ", |sinkSCC|=" ++ show (IS.size sinkSccs)

  let !flow0           = buildFlow cond srcSccSet sinkSccs capOf
      (!residual, !mf) = edmondsKarp flow0
      !sSide           = sSideNodes residual (flowSuper flow0)
      !cutSCCs         = minCutSCCs flow0 sSide

      -- Articulation on the symmetrised condensation.
      !undir   = symmetrise cond
      !artSCCs = articulationPoints' n undir

  hPutStrLn stderr $
    "[chokepoint] max-flow="    ++ showFixed6 mf
      ++ ", |cut SCCs|="        ++ show (IS.size cutSCCs)
      ++ ", |articulation SCCs|=" ++ show (IS.size artSCCs)

  -- Candidates: SCCs that participate in either the cut or the
  -- articulation set. For each, pick one representative original-node
  -- id (the smallest in the SCC) so we can show a name in the table.
  let candidateSccs = IS.toList (IS.union cutSCCs artSCCs)
      candidates :: [Candidate]
      !candidates =
        parMap rdeepseq
          (mkCandidate ix cond cutSCCs artSCCs)
          candidateSccs

      -- Drop excluded.
      filteredCandidates =
        [ c | c <- candidates
            , not (IS.member (canRepId c) excluded) ]

      -- Sort by score desc, tie-break by name.
      !ranked = sortBy
        (comparing (\c -> Down ( canScore c
                               , canCut c
                               , canArt c
                               , canDownstream c
                               , canUpstream c
                               )))
        filteredCandidates

      !topN = take (optTopN opts) ranked

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        chokepointJson ix opts usedMode cond srcSet sinkSet excluded mf
                       cutSCCs artSCCs topN
    OutHuman -> withHumanReport gOpts "chokepoint" $ do
      putStrLn $ "# Chokepoint — top " ++ show (optTopN opts)
              ++ " (sources=" ++ srcModeTag (optSources opts)
              ++ ", sinks="   ++ sinkModeTag usedMode ++ ")"
      putStrLn $ "|V|=" ++ show (V.length defs)
              ++ ", |SCC|=" ++ show n
              ++ ", |S|="   ++ show (IS.size srcSet)
              ++ ", |T|="   ++ show (IS.size sinkSet)
              ++ ", max-flow=" ++ showFixed6 mf
              ++ ", |cut|=" ++ show (IS.size cutSCCs)
              ++ ", |art|=" ++ show (IS.size artSCCs)
      putStrLn ""
      putStrLn "## Candidates"
      let header = ["Rank","QName","Module","State","Role","Score",
                    "up(S)","down(T)"]
          rows   =
            [ [ show r
              , T.unpack (defName d)
              , T.unpack (defModule d)
              , stateTag (defState d)
              , roleLabel (canCut c) (canArt c)
              , showD3 (canScore c)
              , show (canUpstream c)
              , show (canDownstream c)
              ]
            | (r, c) <- zip [1::Int ..] topN
            , let !d = defAt ix (canRepId c)
            ]
      putStr (renderTable header rows)
      when (null rows) $
        putStrLn "  (no candidates — empty cut / articulation sets)"

------------------------------------------------------------------------
-- Candidate scoring
------------------------------------------------------------------------

-- | One ranked candidate. Stored at the /original-node/ level via a
-- per-SCC representative so we can show a QName in the human table.
data Candidate = Candidate
  { canRepId       :: !Int          -- ^ Representative original-node id.
  , canScc         :: !Int          -- ^ Containing SCC id.
  , canCut         :: !Bool         -- ^ In the min-cut?
  , canArt         :: !Bool         -- ^ Articulation point?
  , canUpstream    :: !Int          -- ^ @|ancestors(rep)|@.
  , canDownstream  :: !Int          -- ^ @|descendants(rep)|@.
  , canScore       :: !Double       -- ^ Composite ranking score.
  }

instance NFData Candidate where
  rnf (Candidate a b c d e f g) =
        rnf a `seq` rnf b `seq` rnf c `seq` rnf d
    `seq` rnf e `seq` rnf f `seq` rnf g

mkCandidate
  :: Index
  -> Condensation
  -> IS.IntSet         -- ^ cut SCCs
  -> IS.IntSet         -- ^ articulation SCCs
  -> Int               -- ^ SCC id
  -> Candidate
mkCandidate !ix !cond !cutSCCs !artSCCs !scc =
  let mems   = IM.findWithDefault IS.empty scc (cdMembers cond)
      rep    = case IS.minView mems of
                 Just (r, _) -> r
                 Nothing     -> -1
      isCut  = IS.member scc cutSCCs
      isArt  = IS.member scc artSCCs
      !up    = IS.size (ancestors ix (IS.singleton rep))
      !down  = IS.size (descendants ix (IS.singleton rep))
      -- cutMultiplicity approximation: 1 if in any min-cut, 0
      -- otherwise. True multiplicity = number of distinct min-cut sets
      -- containing the node — exact computation is #P-hard in general
      -- and we don't enumerate min-cuts here. Deferred.
      cutMult :: Double
      cutMult = if isCut then 1.0 else 0.0
      base   = cutMult * fromIntegral up * fromIntegral down :: Double
      !score = if isArt then base * 1.5 else base
  in Candidate
       { canRepId      = rep
       , canScc        = scc
       , canCut        = isCut
       , canArt        = isArt
       , canUpstream   = up
       , canDownstream = down
       , canScore      = score
       }

-- | Per-SCC node-capacity scaler @1 / (LOC + 1)@. Caveat: this is a
-- /capacity preference/, not a line count.  When 'defLine' is
-- 'Nothing' (synthetic nodes, edge-only QNames) we default to 1.0 so
-- such nodes don't artificially attract or repel the cut.
sccCapacity :: Index -> IM.IntMap IS.IntSet -> Int -> Double
sccCapacity !ix !members !scc =
  let mems = IM.findWithDefault IS.empty scc members
      -- Use the smallest-id member as a representative for the
      -- capacity. Singleton SCCs are the common case — this is just
      -- "pick one"; for multi-node SCCs we deliberately collapse to
      -- one capacity since cutting one node in a cycle has no useful
      -- min-cut interpretation anyway.
      rep  = case IS.minView mems of
               Just (r, _) -> r
               Nothing     -> -1
  in case fmap defLine (lookupDefAt ix rep) of
       Just (Just l) -> 1.0 / fromIntegral (l + 1)
       _             -> 1.0

-- | Safe variant of 'defAt' returning 'Nothing' on out-of-range.
lookupDefAt :: Index -> Int -> Maybe Definition
lookupDefAt !ix !i
  | i < 0 || i >= idxNodeCount ix = Nothing
  | otherwise                     = Just (defAt ix i)

------------------------------------------------------------------------
-- JSON / display helpers
------------------------------------------------------------------------

chokepointJson
  :: Index
  -> Options
  -> SinkMode         -- ^ resolved sink mode actually used (post-fallback)
  -> Condensation
  -> IS.IntSet        -- ^ source set (original ids)
  -> IS.IntSet        -- ^ sink set
  -> IS.IntSet        -- ^ excluded
  -> Double           -- ^ max-flow value
  -> IS.IntSet        -- ^ cut SCCs
  -> IS.IntSet        -- ^ articulation SCCs
  -> [Candidate]      -- ^ ranked top-N
  -> A.Value
chokepointJson ix opts usedMode cond srcSet sinkSet excluded mf cutSCCs artSCCs topN =
  A.object
    [ "subcommand" .= ("chokepoint" :: Text)
    , "options"    .= chokepointOptionsJson opts usedMode
    , "stats"      .= A.object
        [ "n_nodes"          .= idxNodeCount ix
        , "n_scc"            .= cdCount cond
        , "n_sources"        .= IS.size srcSet
        , "n_sinks"          .= IS.size sinkSet
        , "max_flow"         .= mf
        , "n_cut_scc"        .= IS.size cutSCCs
        , "n_articulation_scc" .= IS.size artSCCs
        , "excluded_by_regex" .= IS.size excluded
        ]
    , "rows"  .= A.toJSON (zipWith (rowJson ix) [1 :: Int ..] topN)
    ]

-- | JSON view of the options. @sinks@ reflects the mode that was
-- actually used (post-fallback), so consumers can tell when the
-- @postulates-axioms@ -> @terminal-leaves@ fallback fired by
-- comparing against the user's CLI invocation.
chokepointOptionsJson :: Options -> SinkMode -> A.Value
chokepointOptionsJson Options{..} usedSinks = A.object
  [ "top_n"              .= optTopN
  , "sources"            .= srcModeTag optSources
  , "sinks"              .= sinkModeTag usedSinks
  , "exclude_name_regex" .= optExcludeNameRegex
  ]

rowJson :: Index -> Int -> Candidate -> A.Value
rowJson ix rank c =
  let d = defAt ix (canRepId c)
  in A.object
       [ "rank"          .= rank
       , "qname"         .= defName d
       , "module"        .= defModule d
       , "state"         .= stateTag (defState d)
       , "role"          .= roleLabel (canCut c) (canArt c)
       , "in_min_cut"    .= canCut c
       , "articulation"  .= canArt c
       , "upstream"      .= canUpstream c
       , "downstream"    .= canDownstream c
       , "score"         .= canScore c
       , "scc"           .= canScc c
       ]

srcModeTag :: SrcMode -> String
srcModeTag = \case
  ExportedTheorems -> "exported"
  AllPublic        -> "public"
  Terminals        -> "terminals"

sinkModeTag :: SinkMode -> String
sinkModeTag = \case
  PostulatesAxioms -> "postulates-axioms"
  TerminalLeaves   -> "terminal-leaves"

stateTag :: State -> String
stateTag = \case
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"

roleLabel :: Bool -> Bool -> String
roleLabel True  True  = "cut+art"
roleLabel True  False = "cut"
roleLabel False True  = "articulation"
roleLabel False False = "-"

-- | 6-fractional-digit double, for the max-flow value (small after
-- division by LOC).
showFixed6 :: Double -> String
showFixed6 !x =
  let n      = (round (x * 1000000) :: Int)
      (q, r) = divMod (abs n) 1000000
      sign   = if n < 0 then "-" else ""
      pad6 v = let s = show v in replicate (6 - length s) '0' ++ s
  in sign ++ show q ++ "." ++ pad6 r
