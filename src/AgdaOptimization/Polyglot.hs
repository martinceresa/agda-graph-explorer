{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Polyglot — cross-context generalization candidates.
--
-- For each node @v@ with at least 'optMinUses' consumers (ancestors in
-- the dep graph), we classify the consumers into communities found by
-- a from-scratch Louvain run on the /undirected/ projection of the
-- dependency graph (forward ∪ reverse). The diversity score is the
-- Shannon entropy of the consumer-to-community distribution, normalised
-- by @log(min(|C_v|, K))@ with @K = 10@.
--
-- A consumer that lives in a re-exporting module ('rxFrom' of any
-- re-export carrying @v@) has its contribution halved — a single hop of
-- "re-export discount". This is a deliberate simplification; multi-hop
-- chains are not folded in further. See the comment on
-- 'reExportDiscount' for the rationale.
--
-- Everything below is pure; 'run' is the only IO action.
module AgdaOptimization.Polyglot
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Control.Monad        ( unless, when )
import           Control.Parallel.Strategies ( parListChunk, rdeepseq, withStrategy )
import           Data.Foldable        ( foldl' )
import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.IntSet          ( IntSet )
import           Data.IntMap.Strict   ( IntMap )
import           Data.List            ( sortBy )
import           Data.Maybe           ( isJust )
import           Data.Ord             ( Down(..), comparing )
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           System.IO            ( hPutStrLn, stderr )
import           Text.Printf          ( printf )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), ancestors, defAt )
import           AgdaGraph.Schema     ( Definition(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , withHumanOutput )

-- ---------------------------------------------------------------------------
-- Options

-- | User-facing knobs. See module header for the semantics.
data Options = Options
  { optMinUses            :: !Int
    -- ^ Minimum |consumers(v)| to qualify. Below this we don't even
    -- compute the diversity score.
  , optDiversityThreshold :: !Double
    -- ^ Lower bound on the diversity score; printed in the header.
  , optTopN               :: !Int
    -- ^ Maximum number of rows in the report table.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optMinUses            = 5
  , optDiversityThreshold = 0.5
  , optTopN               = 50
  }

-- | Modularity Q below this threshold means the community partition is
-- statistically meaningless. We still print scores in that case but
-- emit a stderr warning and suppress the [god?] tag, which depends
-- structurally on the community assignment being trustworthy.
lowQThreshold :: Double
lowQThreshold = 0.1

-- | Declarative flag spec for the @polyglot@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "min-uses" "--min-uses=N    minimum consumer count to consider (default 2)"
      (\n o -> o { optMinUses = n })
  , DblFlag "threshold" "--threshold=F   entropy threshold (default 1.5)"
      (\x o -> o { optDiversityThreshold = x })
  , IntFlag "top-n" "--top-n=N       rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  ]

-- | Hand-rolled CLI parser for the @polyglot@ subcommand. See
-- 'AgdaOptimization.Motif.parseOptions' for the dispatch shape.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "polyglot" flagSpecs

-- | Overlay the @polyglot:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "polyglot" flagSpecs obj o0

-- ---------------------------------------------------------------------------
-- Public entry

-- | Compute communities, score every qualifying node, and print the
-- report to stdout.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = do
  let !nNodes    = idxNodeCount ix
      -- Undirected adjacency: forward ∪ reverse (and we make sure every
      -- node appears as a key, even with empty neighbourhood, so the
      -- Louvain seed loop sees it).
      !undir     = undirectedAdj ix

      -- Run Louvain (single pass + one collapse level — see 'louvain').
      LouvainResult{..} = louvain undir nNodes

      -- For each node v, build the multiset of (community-of-consumer)
      -- with the re-export discount applied. See 'reExportDiscount' for
      -- the precise definition.
      reDiscount = reExportDiscount ix

      -- Per-node analysis: only nodes with enough consumers.
      (scored, totalConsidered, droppedByMin) =
        scoreAll ix opts louvainNodeComm reDiscount

      qCount = countCommunities louvainNodeComm

  -- Low-Q warning: the partition is too weak to trust [god?] tagging.
  -- Emitted to stderr so stdout (the table) stays machine-parseable.
  let lowQ = louvainModularity < lowQThreshold
  when lowQ $ do
    hPutStrLn stderr $ "[polyglot] WARNING: modularity Q = "
                    ++ printf "%.4f" louvainModularity
                    ++ " is very low (< " ++ printf "%.1f" lowQThreshold ++ ")."
    hPutStrLn stderr   "[polyglot] Community structure is weak; diversity scores are approximate."
    hPutStrLn stderr   "[polyglot] The [god?] tag is suppressed at this Q."

  let topRows   = take optTopN
                $ sortBy (comparing (Down . sDiversity)) scored
      godSet
        | lowQ      = IS.empty
        | otherwise = IS.fromList
                    $ map sNodeId
                    $ take 10
                    $ filter (\s -> isShortProofUnknown ix (sNodeId s))
                    $ sortBy (comparing (Down . sDiversity)) scored
      recs = recommendationStrings ix topRows

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        polyglotJson ix opts totalConsidered droppedByMin qCount
                     louvainModularity lowQ topRows godSet recs
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      -- Header & stats
      putStrLn $ "# Polyglot — top " ++ show optTopN
              ++ " (min-uses=" ++ show optMinUses
              ++ ", threshold=" ++ printf "%.4f" optDiversityThreshold ++ ")"
      putStrLn $ "  nodes considered     : " ++ show totalConsidered
      putStrLn $ "  dropped (min-uses)   : " ++ show droppedByMin
      putStrLn $ "  communities found    : " ++ show qCount
      putStrLn $ "  modularity Q         : " ++ printf "%.4f" louvainModularity
      putStrLn ""

      case scored of
        [] -> putStrLn "no polyglot candidates at this threshold"
        _  -> do
          let renderRow rank s =
                let d  = defAt ix (sNodeId s)
                    tg = goldilocks opts s
                    gd = if IS.member (sNodeId s) godSet then " [god?]" else ""
                in [ show rank
                   , T.unpack tg ++ gd
                   , T.unpack (defName d)
                   , T.unpack (defModule d)
                   , show (sConsumerCount s)
                   , show (sClusterCount s)
                   , printf "%.4f" (sDiversity s)
                   , showTopClusters (sTopClusters s)
                   ]
              header = ["Rank","Tag","QName","Module","|cons|","|clu|","D","topClusters"]
              rows   = zipWith renderRow [(1::Int)..] topRows
          putStr (renderTable header rows)

          -- Recommendations.
          putStrLn ""
          emitRecommendationsHuman recs

-- ---------------------------------------------------------------------------
-- Undirected projection

-- | Symmetrise the dep graph: every directed edge contributes 1.0 in
-- /both/ directions; multiple edges (forward + reverse) coalesce as
-- they share the same node set. Self-loops are dropped (they don't add
-- information for modularity).
--
-- Returns an 'IntMap' keyed by every node id in @[0, n)@ so the
-- Louvain seed phase doesn't need to special-case empty rows.
undirectedAdj :: Index -> IntMap (IntMap Double)
undirectedAdj Index{..} =
  let -- Step 1: insert each forward edge in both directions.
      step1 :: IntMap (IntMap Double)
      !step1 = foldl' addPair IM.empty
        [ (s, t)
        | (s, ts) <- IM.toAscList idxForward
        , t       <- IS.toList ts
        , s /= t
        ]

      -- Reverse is redundant for symmetry given we ran step1, but
      -- we still process it to be defensive against any unidirectional
      -- entries the Index might somehow hold.
      !step2 = foldl' addPair step1
        [ (s, t)
        | (t, ss) <- IM.toAscList idxReverse
        , s       <- IS.toList ss
        , s /= t
        ]

      -- Ensure every node is a key (even isolated ones).
      !final = foldl'
        (\m i -> if IM.member i m then m else IM.insert i IM.empty m)
        step2
        [0 .. idxNodeCount - 1]
  in final
  where
    addPair :: IntMap (IntMap Double) -> (Int,Int)
            -> IntMap (IntMap Double)
    addPair !m (a, b) =
      let !m1 = IM.insertWith (IM.unionWith (+)) a (IM.singleton b 1.0) m
          !m2 = IM.insertWith (IM.unionWith (+)) b (IM.singleton a 1.0) m1
      in m2

-- ---------------------------------------------------------------------------
-- Louvain

-- | Result of a Louvain run: the final node→community assignment and
-- the modularity Q achieved.
data LouvainResult = LouvainResult
  { louvainNodeComm   :: !(IntMap Int)
  , louvainModularity :: !Double
  }

-- | Single-pass Louvain plus one collapse-and-redo level. Good enough
-- for first-cut analysis on graphs up to ~100k nodes.
louvain :: IntMap (IntMap Double) -> Int -> LouvainResult
louvain adj0 _n =
  let -- Level 1.
      (asg1, _) = louvainPass adj0 (initAssignment adj0)
      -- Collapse and run a second pass.
      (collapsedAdj, _label2new) = collapseByCommunity adj0 asg1
      (asg2, _)                  = louvainPass collapsedAdj
                                              (initAssignment collapsedAdj)
      -- Lift level-2 assignment back to original node ids.
      finalAsg = liftAssignment asg1 asg2
      qFinal   = modularity adj0 finalAsg
  in LouvainResult { louvainNodeComm   = finalAsg
                   , louvainModularity = qFinal }

-- | Initial assignment: every node is its own community (id == node id).
initAssignment :: IntMap (IntMap Double) -> IntMap Int
initAssignment adj = IM.fromDistinctAscList
  [ (n, n) | n <- IM.keys adj ]

-- | One Louvain pass: repeatedly move each node to the neighbouring
-- community that maximises modularity gain. Stops when an entire sweep
-- yields no move. Returns the new assignment and the number of sweeps
-- it took (only used for diagnostics).
louvainPass
  :: IntMap (IntMap Double)
  -> IntMap Int
  -> (IntMap Int, Int)
louvainPass adj asg0 =
  let m2 = totalWeight adj  -- 2m: sum of all edge weights (each counted twice in undirected sum)
      -- Σ_tot for every community: sum of degrees of nodes in it.
      degree :: IntMap Double
      !degree = IM.map (sum . IM.elems) adj

      sigmaTot0 :: IntMap Double
      !sigmaTot0 =
        IM.foldlWithKey'
          (\m n c ->
              let !d = IM.findWithDefault 0 n degree
              in IM.insertWith (+) c d m)
          IM.empty
          asg0

      sweep !asg !st =
        let (asg', st', changed) =
              IM.foldlWithKey'
                (\(!a, !s, !ch) n _ ->
                    case bestMove adj degree m2 a s n of
                      Just (_newC, newAsg, newSt) ->
                        (newAsg, newSt, True)
                      Nothing -> (a, s, ch))
                (asg, st, False)
                asg
        in if changed
             then sweep asg' st'
             else (asg', st')

      (asgFinal, _) = sweep asg0 sigmaTot0
      -- Sweep count is opaque; we don't surface it.
  in (asgFinal, 1)

-- | For node @n@, find the neighbouring community offering the biggest
-- positive modularity gain. If no positive-gain move exists, returns
-- 'Nothing' and the node stays in its current community.
bestMove
  :: IntMap (IntMap Double)        -- ^ adj
  -> IntMap Double                 -- ^ degree
  -> Double                        -- ^ 2m
  -> IntMap Int                    -- ^ current assignment
  -> IntMap Double                 -- ^ Σ_tot per community
  -> Int                           -- ^ node n
  -> Maybe (Int, IntMap Int, IntMap Double)
bestMove adj degree m2 asg sigmaTot n
  | m2 <= 0 = Nothing
  | otherwise =
      let oldC = IM.findWithDefault n n asg
          nbrs = IM.findWithDefault IM.empty n adj
          kN   = IM.findWithDefault 0 n degree
          -- k_{n, C}: sum of weights from n to nodes currently in community C.
          kNToComm :: IntMap Double
          !kNToComm = IM.foldlWithKey'
            (\m nb w ->
               let c = IM.findWithDefault nb nb asg
               in IM.insertWith (+) c w m)
            IM.empty
            nbrs
          kNToOld  = IM.findWithDefault 0 oldC kNToComm
          sigmaOld = IM.findWithDefault 0 oldC sigmaTot
          -- Modularity gain of MOVING n from oldC to newC:
          --   ΔQ = (k_{n,new} - k_{n,old}) / m
          --      - kN * (Σ_tot(new) - Σ_tot(old) + kN) / (2m^2)
          -- (the standard simplification; constant factor 2m vs m
          --  factored consistently throughout — see scoreCandidate).
          --
          -- We pick the community with the maximum gain; break ties by
          -- preferring the smallest community-id for determinism.
          scoreCandidate :: Int -> Double -> Double
          scoreCandidate c kNToC
            | c == oldC = 0  -- staying put is the baseline
            | otherwise =
                let sigmaNew = IM.findWithDefault 0 c sigmaTot
                    deltaQ   = (kNToC - kNToOld) / m2
                             - kN * (sigmaNew - sigmaOld + kN) / (2 * m2 * m2)
                in deltaQ

          best :: Maybe (Int, Double, Double)
          !best = IM.foldlWithKey'
            (\acc c kNToC ->
               let dq = scoreCandidate c kNToC
               in case acc of
                    Just (_, bestDq, _) | dq <= bestDq -> acc
                    _                                  -> Just (c, dq, kNToC))
            Nothing
            kNToComm

      in case best of
           Just (newC, dq, _)
             | newC /= oldC && dq > 1e-12 ->
                 let !asg'    = IM.insert n newC asg
                     !sigmaNew     = IM.findWithDefault 0 newC sigmaTot
                     !sigmaOld'    = sigmaOld - kN
                     !sigmaNew'    = sigmaNew + kN
                     !sigmaTot1    = IM.insert oldC sigmaOld' sigmaTot
                     !sigmaTot2    = IM.insert newC sigmaNew' sigmaTot1
                 in Just (newC, asg', sigmaTot2)
           _ -> Nothing

-- | 2m for an undirected graph stored with each edge in both
-- directions: sum of all neighbour-weights.
totalWeight :: IntMap (IntMap Double) -> Double
totalWeight = IM.foldl' (\acc nbrs -> acc + sum (IM.elems nbrs)) 0

-- | Compute modularity Q = sum_c [ (in_c / 2m) - (tot_c / 2m)^2 ].
modularity :: IntMap (IntMap Double) -> IntMap Int -> Double
modularity adj asg =
  let m2 = totalWeight adj
  in if m2 <= 0
       then 0
       else
         let -- For each pair, count intra-community weight (in undirected
             -- "both ways" form so consistent with 2m).
             stats :: IntMap (Double, Double) -- community -> (in_c (sum w_ij over i,j in c, both dirs), tot_c)
             !stats = IM.foldlWithKey'
               (\acc n nbrs ->
                  let cN = IM.findWithDefault n n asg
                      (accIn, accTot) =
                        IM.foldlWithKey'
                          (\(!iIn, !iTot) nb w ->
                             let cNb = IM.findWithDefault nb nb asg
                                 !iTot' = iTot + w
                                 !iIn'  = if cN == cNb then iIn + w else iIn
                             in (iIn', iTot'))
                          (0, 0)
                          nbrs
                      !accNew = IM.insertWith addPair cN (accIn, accTot) acc
                  in accNew)
               IM.empty
               adj
         in IM.foldl' (\q (!ic, !tc) ->
                         q + (ic / m2) - (tc / m2) ** 2)
                      0
                      stats
  where
    addPair (a,b) (a',b') = (a+a', b+b')

-- | Collapse an assignment: every community becomes a super-node, with
-- inter-community weights summed. Returns the collapsed graph and a
-- @oldCommunityId -> newNodeId@ relabelling (we relabel to a compact
-- @[0..k)@ range so the inner pass works on dense ids).
collapseByCommunity
  :: IntMap (IntMap Double)
  -> IntMap Int
  -> (IntMap (IntMap Double), IntMap Int)
collapseByCommunity adj asg =
  let -- Compact relabel: original community id -> dense id.
      compactCmap :: IntMap Int
      !compactCmap = snd $
        IM.foldl' (\(!nx, !m) c ->
                     if IM.member c m
                       then (nx, m)
                       else (nx + 1, IM.insert c nx m))
                  (0, IM.empty)
                  asg
      compactC :: Int -> Int
      compactC c = IM.findWithDefault (-1) c compactCmap

      collapsed :: IntMap (IntMap Double)
      !collapsed = IM.foldlWithKey'
        (\acc n nbrs ->
           let cN = compactC (IM.findWithDefault n n asg)
           in IM.foldlWithKey'
                (\inner nb w ->
                   let cNb = compactC (IM.findWithDefault nb nb asg)
                       bump m =
                         IM.insertWith (IM.unionWith (+)) cN
                           (IM.singleton cNb w) m
                   in bump inner)
                acc
                nbrs)
        IM.empty
        adj
      -- Ensure every collapsed-community key is present.
      kRange = IM.elems compactCmap
      collapsed' = foldl' (\m k -> if IM.member k m then m else IM.insert k IM.empty m) collapsed kRange
  in (collapsed', compactCmap)

-- | After a level-2 pass, lift the (level-1-community → level-2-community)
-- assignment back down to (node → level-2-community).
--
-- Trace: for node @n@, @level1[n] = origC@; that origC was relabelled
-- to a compact id via the same fold order used in 'collapseByCommunity';
-- @level2[compactId]@ gives the final level-2 community.
liftAssignment :: IntMap Int -> IntMap Int -> IntMap Int
liftAssignment level1 level2 =
  IM.map
    (\origC ->
       let compactId = IM.findWithDefault origC origC level1Compact
       in IM.findWithDefault compactId compactId level2)
    level1
  where
    -- Rebuild the compact relabel deterministically (matches the fold
    -- order in 'collapseByCommunity').
    level1Compact :: IntMap Int
    !level1Compact = snd $
      IM.foldl' (\(!nx, !m) c ->
                   if IM.member c m
                     then (nx, m)
                     else (nx + 1, IM.insert c nx m))
                (0, IM.empty)
                level1

-- ---------------------------------------------------------------------------
-- Scoring

-- | Per-node analysis result.
data Score = Score
  { sNodeId        :: !Int
  , sConsumerCount :: !Int
    -- ^ |consumers(v)| (after re-export discount).
  , sClusterCount  :: !Int
    -- ^ Number of distinct communities containing at least one consumer.
  , sDiversity     :: !Double
    -- ^ D(v) in [0, 1+ε].
  , sTopClusters   :: ![(Int, Double)]
    -- ^ Top-3 (community-id, weighted-count) pairs, biggest first.
  }

-- | Needed so parallel-sparked 'Score' values fully evaluate before
-- joining the result list. All fields are strict; we just descend into
-- the tiny @sTopClusters@ list spine.
instance NFData Score where
  rnf (Score a b c d e) = a `seq` b `seq` c `seq` d `seq` rnf e

-- | Filter nodes by 'optMinUses' and compute scores for the survivors.
-- Per-node work (the 'ancestors' BFS + the entropy compute) is sparked
-- across nodes via 'parListChunk'; the final reduction (counting +
-- list assembly) is sequential and order-preserving.
scoreAll
  :: Index
  -> Options
  -> IntMap Int           -- ^ node -> community
  -> IntSet               -- ^ "discount this consumer" set (per spec)
  -> ([Score], Int, Int)  -- ^ (scored, totalConsidered, droppedByMinUses)
scoreAll ix Options{..} nodeComm discountSet =
  let n = idxNodeCount ix
      -- Per-node: Nothing if filtered by min-uses; Just !Score otherwise.
      perNode :: Int -> Maybe Score
      perNode !i =
        let consSet = ancestors ix (IS.singleton i)
            count   = IS.size consSet
        in if count < optMinUses
             then Nothing
             else Just $! computeScore nodeComm discountSet i consSet
      -- Sparked list of results in ascending i order.
      sparked :: [Maybe Score]
      sparked = withStrategy (parListChunk 64 rdeepseq)
                             (map perNode [0 .. n - 1])
      -- Sequential reduction. Cons-prepend to preserve the original
      -- descending-i ordering of the returned [Score].
      go !rows !nConsidered !nDropped []         =
        (rows, nConsidered, nDropped)
      go !rows !nConsidered !nDropped (mx : xs') = case mx of
        Nothing -> go rows         (nConsidered + 1) (nDropped + 1) xs'
        Just s  -> go (s : rows)   (nConsidered + 1) nDropped       xs'
  in go [] 0 0 sparked

-- | Compute the Score record for one node from its consumer set.
computeScore
  :: IntMap Int     -- ^ node -> community
  -> IntSet         -- ^ discount set
  -> Int            -- ^ node id v
  -> IntSet         -- ^ consumers(v)
  -> Score
computeScore nodeComm discountSet v consSet =
  let -- Weighted count per community.
      perComm :: IntMap Double
      !perComm = IS.foldl'
        (\m c ->
           let comm = IM.findWithDefault c c nodeComm
               !w   = if IS.member c discountSet then 0.5 else 1.0
           in IM.insertWith (+) comm w m)
        IM.empty
        consSet
      !total = sum (IM.elems perComm)
      !cCount = IM.size perComm
      -- Shannon entropy in nats.
      entropyH
        | total <= 0 = 0
        | otherwise  = IM.foldl'
            (\acc w ->
               if w <= 0
                 then acc
                 else let p = w / total
                      in acc - p * log p)
            0
            perComm
      kCap  = 10 :: Int
      denom = log (fromIntegral (min cCount kCap) :: Double)
      diversity
        | cCount <= 1 = 0  -- avoid log(1) = 0 blowup
        | denom <= 0  = 0
        | otherwise   = entropyH / denom
      topClusters =
        take 3
        $ sortBy (comparing (Down . snd))
        $ IM.toList perComm
      -- "count" we display is the original |consumers|; the discount
      -- only affects scoring weight, not the reported headcount.
  in Score
       { sNodeId        = v
       , sConsumerCount = IS.size consSet
       , sClusterCount  = cCount
       , sDiversity     = diversity
       , sTopClusters   = topClusters
       }

-- | Re-export discount set: consumers reached via a re-export get their
-- contribution halved. The 'Index' does not carry re-export rows
-- (@egReExports@ is dropped on the consumer side), so this is a no-op
-- returning 'IS.empty'; the report header documents the limit.
reExportDiscount :: Index -> IntSet
reExportDiscount _ = IS.empty

-- ---------------------------------------------------------------------------
-- Tagging & helpers

countCommunities :: IntMap Int -> Int
countCommunities = IS.size . IS.fromList . IM.elems

-- | Map a Score to one of the four Goldilocks tags. Order matters: we
-- check from most-stringent to least.
goldilocks :: Options -> Score -> Text
goldilocks Options{..} Score{..}
  | sConsumerCount >= 30 && sDiversity >= 0.8           = T.singleton '\x2605' -- ★
  | sConsumerCount >= 10 && sDiversity >= 0.6           = T.singleton '\x25C6' -- ◆
  | sConsumerCount >= optMinUses && sDiversity <  0.3   = T.singleton '\x00B7' -- ·
  | otherwise                                           = " "

-- | True when we can't make any judgment about whether the definition
-- is a "short proof" because we have no line/source-size signal.
isShortProofUnknown :: Index -> Int -> Bool
isShortProofUnknown ix i =
  case defLine (defAt ix i) of
    Nothing -> True   -- no signal: caller will tag [god?] in top-10.
    Just _  -> False  -- producer gave us a line; we conservatively skip.

showTopClusters :: [(Int, Double)] -> String
showTopClusters = T.unpack . T.intercalate "/" . map (T.pack . show . roundInt . snd)
  where roundInt x = (round x :: Int)

-- | The two heuristic one-liners (\"promote\" / \"split\"), pre-formatted
-- as user-facing strings. Each is 'Nothing' when no candidate satisfies
-- the heuristic.
data Recommendations = Recommendations
  { recPromote :: !(Maybe String)
  , recSplit   :: !(Maybe String)
  }

-- | Pure compute for the recommendations panel. Picks:
--   * /promote/ — highest D among ≥ 10 consumers AND many clusters.
--   * /split/   — high D with a top-1 cluster ≥ 40% AND second cluster
--                 ≥ 25%, suggesting two distinct user-bases.
recommendationStrings :: Index -> [Score] -> Recommendations
recommendationStrings ix rows =
  let promoteCands =
        sortBy (comparing (Down . sDiversity))
          [ s | s <- rows
              , sConsumerCount s >= 10
              , sClusterCount s >= 3
              , sDiversity s >= 0.6
          ]
      splitCands =
        let bumpy s =
              case sTopClusters s of
                ((_, w1) : (_, w2) : _) ->
                  let tot = sum (map snd (sTopClusters s))
                  in tot > 0 && w1 / tot >= 0.4 && w2 / tot >= 0.25
                _ -> False
        in sortBy (comparing (Down . sDiversity))
             [ s | s <- rows, sDiversity s >= 0.5, bumpy s ]
      mPromote = case promoteCands of
        (s:_) -> Just $ "promote: " ++ describe ix s
                     ++ " — high entropy across many clusters; consider abstracting (e.g. typeclass)."
        []    -> Nothing
      mSplit   = case splitCands of
        (s:_) -> Just $ "split  : " ++ describe ix s
                     ++ " — two/three concentrated user-bases; consider splitting the name."
        []    -> Nothing
  in Recommendations { recPromote = mPromote, recSplit = mSplit }

-- | Emit the (already computed) recommendation strings to stdout.
emitRecommendationsHuman :: Recommendations -> IO ()
emitRecommendationsHuman Recommendations{..} = do
  mapM_ putStrLn recPromote
  mapM_ putStrLn recSplit
  unless (isJust recPromote || isJust recSplit) $
    putStrLn "(no promote/split heuristics fired)"

describe :: Index -> Score -> String
describe ix s =
  let d = defAt ix (sNodeId s)
  in T.unpack (defName d)
       ++ "  [|cons|=" ++ show (sConsumerCount s)
       ++ ", D=" ++ printf "%.3f" (sDiversity s)
       ++ ", clusters=" ++ show (sClusterCount s) ++ "]"

----------------------------------------------------------------------
-- JSON rendering. See the schema in 'AgdaOptimization.Report'.

polyglotJson
  :: Index
  -> Options
  -> Int                -- ^ Total considered (= nNodes).
  -> Int                -- ^ Dropped by min-uses.
  -> Int                -- ^ Communities found.
  -> Double             -- ^ Modularity Q.
  -> Bool               -- ^ Low-Q warning.
  -> [Score]            -- ^ Top rows (already sorted).
  -> IntSet             -- ^ God-suspect set.
  -> Recommendations
  -> A.Value
polyglotJson ix opts totalConsidered droppedByMin qCount qVal lowQ
             topRows godSet recs =
  A.object
    [ "subcommand" .= ("polyglot" :: Text)
    , "options"    .= polyglotOptionsJson opts
    , "stats"      .= A.object
        [ "nodes_considered"   .= totalConsidered
        , "dropped_by_min_uses" .= droppedByMin
        , "communities"        .= qCount
        , "modularity_q"       .= qVal
        , "q_warning"          .= lowQ
        ]
    , "rows"      .= A.toJSON (zipWith (polyglotRowJson ix opts godSet)
                                       [1 :: Int ..] topRows)
    , "recommendations" .= A.object
        [ "promote" .= recPromote recs
        , "split"   .= recSplit   recs
        ]
    ]

polyglotOptionsJson :: Options -> A.Value
polyglotOptionsJson Options{..} = A.object
  [ "min_uses"            .= optMinUses
  , "diversity_threshold" .= optDiversityThreshold
  , "top_n"               .= optTopN
  ]

polyglotRowJson :: Index -> Options -> IntSet -> Int -> Score -> A.Value
polyglotRowJson ix opts godSet rank s =
  let d  = defAt ix (sNodeId s)
      tg = goldilocks opts s
  in A.object
       [ "rank"          .= rank
       , "tag"           .= tg
       , "god_suspect"   .= IS.member (sNodeId s) godSet
       , "qname"         .= defName d
       , "module"        .= defModule d
       , "consumers"     .= sConsumerCount s
       , "clusters"      .= sClusterCount s
       , "diversity"     .= sDiversity s
       , "top_clusters"  .= A.toJSON (map pairToArr (sTopClusters s))
       ]
  where
    -- (community_id, weighted_count) — represented as a 2-element array
    -- per the schema; weights are rounded to ints for compactness, matching
    -- the human renderer's @roundInt@.
    pairToArr :: (Int, Double) -> A.Value
    pairToArr (c, w) = A.toJSON [c, (round w :: Int)]
