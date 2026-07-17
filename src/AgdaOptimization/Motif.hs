{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
-- | Frequent labeled-subgraph mining over the per-def dependency DAG.
--
-- The implementation is a pragmatic variant of gSpan:
--
--   * Motif = connected, induced labeled subgraph of the host DAG.
--     Node label = @(Kind, State)@; QName identity is NOT part of the
--     label. Edges are directed, unlabeled.
--   * Enumeration = bounded BFS over connected subgraphs by adding one
--     /weakly-adjacent/ neighbour at a time (i.e. either in- or
--     out-neighbour). For 'optMaxSize' = 5 this is tractable on
--     1k–100k node graphs; we cap fan-out per node deterministically
--     to bound the worst case.
--   * Canonicalization = compute a Weisfeiler-Lehman-style refinement
--     of node labels within the embedding (init = node label; refine
--     = sorted multiset of neighbour labels + edge directions) until
--     stable, then sort edges by the WL labels of their endpoints.
--     This collapses isomorphic embeddings into one motif key with
--     high probability for the small (≤ 5) sizes we mine.
--   * Support = MNI (Minimum Image-based support): for each motif
--     node v, count distinct host images of v; take the min. MNI is
--     anti-monotone — a parent's MNI bounds every child's.
--
-- Pitfalls suppressed:
--   * Pure label-uniform paths of length ≤ 3 dropped.
--   * @optPerModule = False@ requires ≥ 2 distinct host modules
--     (hard default; not yet user-tunable).
--   * Top-K% degree nodes excluded when @optExcludeHubPct > 0@.
module AgdaOptimization.Motif
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq     ( NFData(..) )
import           Control.Monad       ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.Aeson          as A
import           Data.Aeson          ( (.=) )
import           Data.IORef          ( IORef, newIORef, readIORef, writeIORef )
import qualified Data.IntMap.Strict  as IM
import qualified Data.IntSet         as IS
import           Data.List           ( sort, sortOn )
import qualified Data.Map.Strict     as Map
import           Data.Map.Strict     ( Map )
import qualified Data.Set            as Set
import           Data.Set            ( Set )
import           Data.Text           ( Text )
import qualified Data.Text           as T
import           Data.Ord            ( Down(..) )
import qualified Data.Vector         as V
import           System.IO           ( hPutStrLn, stderr )

import           AgdaGraph.Index     ( Index(..), defAt )
import           AgdaGraph.Schema    ( Definition(..), Kind, State )
import           AgdaOptimization.Common ( chunksOf, withReaper )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , withHumanOutput )

-- | Options for the motif analysis.
data Options = Options
  { optMinSupport     :: !Int
    -- ^ Minimum number of distinct hosts a motif must appear in.
  , optMinSize        :: !Int
    -- ^ Minimum number of nodes in a candidate motif.
  , optMaxSize        :: !Int
    -- ^ Maximum number of nodes in a candidate motif.
  , optPerModule      :: !Bool
    -- ^ @True@: per-module mining; @False@: global.
  , optExcludeHubPct  :: !Double
    -- ^ Drop the top-K% most-connected nodes from the search to avoid
    -- the search exploding on hubs. 0 disables.
  , optTopN           :: !Int
    -- ^ Cap on the number of motifs printed. Default 50.
  , optMaxFanOut      :: !Int
    -- ^ Hard cap on per-node out+in neighbours considered during
    -- extension, for worst-case bound. Default 32.
  , optBudgetSecs     :: !Double
    -- ^ Wall-clock budget for mining, in seconds. 0 (the default)
    -- disables the budget; mining runs to completion. When > 0 a
    -- reaper thread flips a deadline 'IORef' once the budget is up;
    -- the seed loop checks it between seeds and stops cleanly with
    -- whatever motifs were collected.
  , optMinLabelDistinct :: !Int
    -- ^ Drop motifs whose node set carries fewer than this many
    -- distinct @(Kind, State)@ labels. Default 2 — trims the
    -- @Function:D x N@ chains that swamp the top of the table with
    -- no structural novelty. Set to 1 to opt back in to single-label
    -- motifs (genuine all-@Constructor@, all-@Postulate@ etc).
  } deriving (Show)

-- | Defaults.
--
-- @optMaxSize@ is 3 because the 5-deep enumeration is O(|V| · maxFanOut⁴)
-- and is infeasible at production scale. Users can opt back in via
-- @--max-size=5@.
defaultOptions :: Options
defaultOptions = Options
  { optMinSupport       = 3
  , optMinSize          = 2
  , optMaxSize          = 3
  , optPerModule        = False
  , optExcludeHubPct    = 0.0
  , optTopN             = 50
  , optMaxFanOut        = 32
  , optBudgetSecs       = 0.0
  , optMinLabelDistinct = 2
  }

-- | Declarative flag spec for the @motif@ subcommand. Drives both the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--per-module@ is a 'SwitchPreGuard' switch: matched against the raw
-- token before 'splitFlag', so @--per-module=x@ falls through to the
-- unknown-flag path.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "min-support" "--min-support=N         minimum embedding count (default 3)"
      (\n o -> o { optMinSupport = n })
  , IntFlag "min-size" "--min-size=N            minimum motif size in nodes (default 2)"
      (\n o -> o { optMinSize = n })
  , IntFlag "max-size" "--max-size=N            maximum motif size in nodes (default 3)"
      (\n o -> o { optMaxSize = n })
  , SwitchFlag "per-module" "--per-module            mine per-module (currently warns + falls back to global)"
      SwitchPreGuard (\o -> o { optPerModule = True })
      (Just "per-module") (\v o -> o { optPerModule = v })
  , DblFlag "exclude-hub-pct" "--exclude-hub-pct=F     drop top-pct% hub nodes by fan-in"
      (\x o -> o { optExcludeHubPct = x })
  , IntFlag "top-n" "--top-n=N               rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , IntFlag "max-fan-out" "--max-fan-out=N         skip seeds whose fan-out exceeds N"
      (\n o -> o { optMaxFanOut = n })
  , DblFlag "budget" "--budget=F              wall-clock seconds; 0 = unlimited (default)"
      (\x o -> o { optBudgetSecs = x })
  , IntFlag "min-label-distinct" "--min-label-distinct=N  require >= N distinct (kind, state) labels (default 2)"
      (\n o -> o { optMinLabelDistinct = n })
  ]

-- | Hand-rolled CLI parser for the @motif@ subcommand.
--
-- Accepts both @--flag=value@ and @--flag value@ forms. Boolean flags
-- (e.g. @--per-module@) carry no value. Unknown flags produce a
-- @Left@ with a per-subcommand error message. Folds over the argv
-- with a strict accumulator.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "motif" flagSpecs

-- | Overlay the @motif:@ YAML section onto a seed 'Options'. Each key
-- mirrors the kebab-case CLI flag minus the @--@ prefix.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "motif" flagSpecs obj o0

-- | The node label drives both isomorphism and motif-key.
type Label = (Kind, State)

-- | A motif key is the canonical representation we use to bucket
-- embeddings by /which motif/ they belong to. We build it from a
-- 1-step Weisfeiler-Lehman refinement over the embedding's induced
-- adjacency, then a sorted edge tuple list keyed by WL labels.
--
-- Two isomorphic embeddings will produce the same 'MotifKey'; the
-- converse holds in the limit of WL refinement (we run up to 4
-- iterations, sufficient for size ≤ 5 motifs in practice).
newtype MotifKey = MotifKey [(Int, Int)]
  -- ^ Sorted list of @(wlLabelSrc, wlLabelDst)@ pairs together with
  -- the multiset of WL labels at the motif's nodes (encoded as edges
  -- @(label, -1)@ so the constructor stays uniform).
  deriving (Eq, Ord, Show)

-- | Needed so sparked '[(MotifKey, Embedding)]' values can be forced
-- to NF before being shipped to the main thread.
instance NFData MotifKey where
  rnf (MotifKey xs) = rnf xs

-- | One embedding of a motif: the host node ids in some canonical
-- order. The order is significant because we use it to map "motif
-- node v" -> "host image of v" when computing MNI support.
type Embedding = V.Vector Int

-- | Internal record per motif bucket while mining.
data Motif = Motif
  { mKey         :: !MotifKey
  , mEmbeddings  :: ![Embedding]
    -- ^ Reverse-insertion order; we don't care which.
  , mSize        :: !Int
  } deriving (Show)

----------------------------------------------------------------------
-- Entry point.

run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts0 = do
  let opts        = sanitizeOptions opts0
      hostMods    = collectHostModules ix
      excluded    = excludeHubs ix opts
      activeNodes = IS.difference (allNodes ix) excluded
      labelOf i   = let d = defAt ix i in (defKind d, defState d)
      seeds       = IS.toAscList activeNodes
      totalSeeds  = length seeds
      -- Aim for ~20 progress lines; never spam.
      progressEvery = max 1 (totalSeeds `div` 20)

  -- Subgraph enumeration is O(|V| · maxFanOut^(maxSize-1)); past the
  -- default size 3 on a non-trivial graph it gets infeasible fast (size 4
  -- already times out on a ~6k-node corpus). Warn rather than silently
  -- hang, and point at the escape hatches.
  when (optMaxSize opts >= 4 && totalSeeds > 2000) $
    hPutStrLn stderr $
      "agda-optimization motif: --max-size=" ++ show (optMaxSize opts)
        ++ " on " ++ show totalSeeds ++ " seed node(s) — enumeration is "
        ++ "O(|V|·maxFanOut^(max-size-1)) and may be very slow or exhaust "
        ++ "memory. Bound the per-seed cost with --max-fan-out=N (the most "
        ++ "effective knob), lower --max-size, or exclude hubs with "
        ++ "--exclude-hub-pct. (--budget only checks between seeds, so it "
        ++ "won't interrupt a single expensive seed.)"

  -- Deadline plumbing. When the budget is 0 (default) we still allocate
  -- the IORef but never spawn a reaper, so 'readIORef' is always False.
  deadlineRef <- newIORef False

  -- Bracket the reaper so it gets killed in every exit path
  -- (completion, exception, GHC-level interrupt).
  withReaper (optBudgetSecs opts) deadlineRef $ do

    -- Running bucket map: motif key -> reverse-insertion list of
    -- embeddings. Strict at the spine.
    bucketsRef    <- newIORef (Map.empty :: Map MotifKey [Embedding])
    foundRef      <- newIORef (0 :: Int)
    tripRef       <- newIORef False   -- did the deadline fire?
    processedRef  <- newIORef (0 :: Int)

    -- Chunked seed loop. Each chunk's per-seed embeddings are produced
    -- in parallel via 'parMap rdeepseq', then folded into the running
    -- bucket map sequentially. Deadline check is per-chunk; chunk size
    -- 64 keeps it responsive.
    let chunkSize = 64 :: Int
        loop :: [[Int]] -> IO ()
        loop []           = pure ()
        loop (chunk:rest) = do
          stop <- readIORef deadlineRef
          if stop
            then writeIORef tripRef True
            else do
              let !chunkEmbs =
                    concat (parMap rdeepseq
                              (enumerateFrom ix opts labelOf activeNodes)
                              chunk)
              mapM_ (insertEmbedding bucketsRef foundRef) chunkEmbs
              prev <- readIORef processedRef
              let !done = prev + length chunk
              writeIORef processedRef done
              -- Periodic progress + top-so-far score for the user.
              -- Trigger when we crossed a progressEvery boundary in
              -- this chunk, or on the final chunk.
              let crossedBoundary =
                    done `div` progressEvery > prev `div` progressEvery
              when (crossedBoundary || done == totalSeeds) $ do
                bk <- readIORef bucketsRef
                nFound <- readIORef foundRef
                let !topScore = currentTopScore opts bk
                hPutStrLn stderr $
                  "[motif] seeds=" ++ show done ++ "/" ++ show totalSeeds
                  ++ ", motifs-found=" ++ show nFound
                  ++ ", running top score=" ++ show topScore
              loop rest

    loop (chunksOf chunkSize seeds)

    tripped <- readIORef tripRef
    bucketsFinal <- readIORef bucketsRef

    let buckets  = materializeBuckets bucketsFinal
        filtered = postFilter ix opts buckets
        ranked   = rankMotifs filtered
        header   = [ "Rank", "Score", "Support", "Size", "Labels", "ExampleSite" ]
        shown    = take (optTopN opts) ranked

    when tripped $
      hPutStrLn stderr $
        "[motif] budget exhausted after " ++ show (optBudgetSecs opts)
        ++ "s; emitting partial results (" ++ show (length buckets)
        ++ " motifs found)."

    case gOutFormat gOpts of
      OutJson ->
        emitJsonReport (gOutPath gOpts) $
          motifJson ix opts hostMods excluded buckets ranked tripped shown
      OutHuman -> withHumanOutput (gOutPath gOpts) $ do
        putStrLn (headerLine opts)
        when (not (null shown)) $
          putStr $ renderTable header (zipWith (renderRow ix) [1..] shown)
        when (null shown) $
          putStrLn $ "no motifs found at this threshold (min-support="
                  ++ show (optMinSupport opts)
                  ++ ", size=[" ++ show (optMinSize opts)
                  ++ "," ++ show (optMaxSize opts) ++ "])."
        putStrLn $ "# considered=" ++ show (length buckets)
                ++ " kept=" ++ show (length ranked)
                ++ " hosts=" ++ show (Set.size hostMods)
                ++ " hub-excluded=" ++ show (IS.size excluded)
    -- --per-module not implemented in either format; warn unconditionally.
    when (optPerModule opts) $
      hPutStrLn stderr "motif: --per-module not yet implemented; ran in global mode."

-- | Fold one @(key, embedding)@ pair into the running bucket map.
-- Strict in the spine of the @[Embedding]@ value so we don't pile up
-- thunks across thousands of seeds.
insertEmbedding
  :: IORef (Map MotifKey [Embedding])
  -> IORef Int
  -> (MotifKey, Embedding)
  -> IO ()
insertEmbedding bucketsRef foundRef (k, e) = do
  m <- readIORef bucketsRef
  -- One traversal: insert (prepending @e@) and learn whether the key was
  -- already present in the same step.
  let (mOld, !m') = Map.insertLookupWithKey (\_ new old -> new ++ old) k [e] m
  writeIORef bucketsRef m'
  -- @foundRef@ tracks distinct motif buckets, not embeddings.
  case mOld of
    Nothing -> do n <- readIORef foundRef
                  writeIORef foundRef $! n + 1
    Just _  -> pure ()

-- | Materialize the bucket map into the list of 'Motif' records the
-- rest of the pipeline expects.
materializeBuckets :: Map MotifKey [Embedding] -> [Motif]
materializeBuckets bk =
  [ Motif { mKey = k
          , mEmbeddings = es
          , mSize = case es of
                      (e:_) -> V.length e
                      []    -> 0
          }
  | (k, es) <- Map.toList bk ]

-- | Best @support * (size - 2)@ score across the running bucket map.
-- Used only for periodic progress reporting; not authoritative.
-- O(|buckets| * total embeddings) — acceptable at progress frequency.
currentTopScore :: Options -> Map MotifKey [Embedding] -> Int
currentTopScore opts bk =
  let scoreOne es =
        case es of
          (e:_) -> let sz   = V.length e
                       mni  = mniSupport sz es
                   in if mni >= optMinSupport opts
                        then mni * max 0 (sz - 2)
                        else 0
          []    -> 0
  in Map.foldl' (\acc es -> max acc (scoreOne es)) 0 bk

-- | Clamp / sanity-check the options so downstream code can rely on
-- @minSize <= maxSize@, both ≥ 1, etc.
sanitizeOptions :: Options -> Options
sanitizeOptions o = o
  { optMinSize    = max 1 (optMinSize o)
  , optMaxSize    = max (optMinSize o) (optMaxSize o)
  , optMinSupport = max 1 (optMinSupport o)
  , optTopN       = max 1 (optTopN o)
  , optMaxFanOut  = max 1 (optMaxFanOut o)
  }

-- | Header banner.
headerLine :: Options -> String
headerLine Options{..} =
     "# ProofMotif — top " ++ show optTopN
  ++ " motifs (support ≥ " ++ show optMinSupport
  ++ ", size ∈ [" ++ show optMinSize ++ ", " ++ show optMaxSize ++ "]"
  ++ ", hub-excl pct=" ++ show optExcludeHubPct
  ++ ", min-label-distinct=" ++ show optMinLabelDistinct
  ++ ")"

----------------------------------------------------------------------
-- Hub exclusion + module collection.

-- | All node ids in the index, as an IntSet.
allNodes :: Index -> IS.IntSet
allNodes Index{..} = IS.fromDistinctAscList [0 .. idxNodeCount - 1]

-- | Set of distinct module names in the host (purely informational
-- for the footer).
collectHostModules :: Index -> Set Text
collectHostModules Index{..} =
  V.foldl' (\acc d -> Set.insert (defModule d) acc) Set.empty idxDefs

-- | Compute the set of node ids to exclude based on
-- @optExcludeHubPct@. 0 returns an empty set.
excludeHubs :: Index -> Options -> IS.IntSet
excludeHubs ix Options{..}
  | optExcludeHubPct <= 0 = IS.empty
  | otherwise =
      let n    = idxNodeCount ix
          degs = [ (i, degreeOf ix i) | i <- [0 .. n - 1] ]
          k    = floor (optExcludeHubPct / 100.0 * fromIntegral n)
          topK = map fst (take k (sortOn (Down . snd) degs))
      in IS.fromList topK

-- | Combined in+out degree of node @i@.
degreeOf :: Index -> Int -> Int
degreeOf Index{..} i =
  let outs = IM.findWithDefault IS.empty i idxForward
      ins  = IM.findWithDefault IS.empty i idxReverse
  in IS.size outs + IS.size ins

----------------------------------------------------------------------
-- Mining: enumerate connected induced subgraphs up to size optMaxSize.
--
-- We grow a /set/ of host node ids starting from each "seed" node,
-- and at each step add one neighbour (forward or reverse) of any
-- node already in the set. We dedupe subgraphs across different
-- enumeration paths by using @IS.IntSet@ as the canonical
-- representation for a given embedding's vertex set, and we drop
-- "lex-larger" enumerations: we require the seed to be the smallest
-- id in the embedding so each subgraph is grown from exactly one
-- starting point.

-- (Mining is driven seed-by-seed in 'run' so we can interleave a
-- wall-clock budget check + progress reporting; see the IO loop
-- there. 'enumerateFrom' below is the pure per-seed primitive it
-- calls.)

-- | Enumerate every connected induced subgraph whose smallest-id
-- vertex is @seed@ and whose size is in @[1, optMaxSize]@, returning
-- @(motifKey, embedding)@ for each one that passes @minSize@.
--
-- Implementation: BFS over the lattice of vertex sets, using a stack
-- of @(currentSet, frontier)@ pairs where @frontier@ is the set of
-- candidate next vertices.
enumerateFrom :: Index -> Options -> (Int -> Label) -> IS.IntSet -> Int
              -> [(MotifKey, Embedding)]
enumerateFrom ix Options{..} labelOf active seed =
  let go :: IS.IntSet -> IS.IntSet -> [(MotifKey, Embedding)]
      go !subset !frontier =
        let !sz = IS.size subset
            emitHere
              | sz >= optMinSize =
                  let emb = embeddingOf subset
                      key = canonicalize ix labelOf emb
                  in [(key, emb)]
              | otherwise = []
            grown
              | sz >= optMaxSize = []
              | otherwise =
                  let cands = IS.toAscList frontier
                      take' = take optMaxFanOut cands
                  in concatMap (extendOne subset frontier) take'
        in emitHere ++ grown

      extendOne :: IS.IntSet -> IS.IntSet -> Int
                -> [(MotifKey, Embedding)]
      extendOne subset frontier v =
        let !subset'   = IS.insert v subset
            -- New neighbours brought in by @v@, restricted to active
            -- and to ids > seed (so we don't grow a subset whose
            -- smallest id is below @seed@ — that prevents double-count
            -- because that same subset will be enumerated from the
            -- /smaller/ seed instead).
            nbrs       = neighbours ix v
            newFront0  = IS.difference (IS.intersection nbrs active) subset'
            newFront   = IS.filter (> seed) newFront0
            !frontier' = IS.union (IS.delete v frontier) newFront
            -- Note: v > seed is guaranteed because @frontier@ is
            -- already filtered to ids > seed.
        in go subset' frontier'

      embeddingOf :: IS.IntSet -> Embedding
      embeddingOf s = V.fromListN (IS.size s) (IS.toAscList s)

      seedFrontier =
        let nbrs = neighbours ix seed
        in IS.filter (> seed) (IS.intersection nbrs active)

  in if IS.member seed active
       then go (IS.singleton seed) seedFrontier
       else []

-- | Undirected neighbour set: out- ∪ in-neighbours.
neighbours :: Index -> Int -> IS.IntSet
neighbours Index{..} v =
  let outs = IM.findWithDefault IS.empty v idxForward
      ins  = IM.findWithDefault IS.empty v idxReverse
  in IS.union outs ins

----------------------------------------------------------------------
-- Canonicalization.
--
-- Given an embedding (an ordered vector of host node ids), produce a
-- 'MotifKey' that is invariant under any relabeling of the host nodes
-- that preserves the induced labeled subgraph isomorphism class.
--
-- Strategy: Weisfeiler-Lehman colour refinement.
--   Round 0: each motif node gets a colour = its label hash.
--   Round k+1: colour(v) = hash (colour(v), sorted [(dir, colour(u))]
--              for each motif-internal edge (v, u) or (u, v)).
-- Iterate until stable or 4 rounds (whichever first).
-- Then emit edges as @(colourSrc, colourDst)@ sorted.
-- We also include the multiset of node colours encoded as edges
-- @(colour, -1)@ so size-1 motifs and disconnected-by-label motifs
-- still get a distinct key.

canonicalize :: Index -> (Int -> Label) -> Embedding -> MotifKey
canonicalize ix labelOf emb =
  let n     = V.length emb

      labelHash :: Int -> Int
      labelHash i =
        let (k, s) = labelOf (emb V.! i)
        in hashLabel k s

      -- Induced edges, as motif-local indices, paired with direction.
      -- direction = 1 for "src -> dst"; we still emit them in
      -- (src, dst) order, so direction is implicit.
      inducedEdges :: [(Int, Int)]
      !inducedEdges = concat
        [ [ (i, j)
          | let outs = IM.findWithDefault IS.empty (emb V.! i)
                       (idxForward ix)
          , j <- [0 .. n - 1]
          , i /= j
          , IS.member (emb V.! j) outs
          ]
        | i <- [0 .. n - 1]
        ]

      -- Neighbour lists for the WL step: each entry is
      -- @(direction, otherMotifIdx)@ where direction = 1 (outgoing,
      -- this -> other) or -1 (incoming, other -> this).
      nbrLists :: V.Vector [(Int, Int)]
      !nbrLists = V.generate n $ \i ->
        let out = [ ( 1, j) | (s, j) <- inducedEdges, s == i ]
            inn = [ (-1, s) | (s, j) <- inducedEdges, j == i ]
        in out ++ inn

      initial :: V.Vector Int
      !initial = V.generate n labelHash

      step :: V.Vector Int -> V.Vector Int
      step cur =
        V.generate n $ \i ->
          let mine = cur V.! i
              nbrs = sort [ (d, cur V.! j) | (d, j) <- nbrLists V.! i ]
          in hashCombine mine nbrs

      stabilize :: Int -> V.Vector Int -> V.Vector Int
      stabilize 0 c = c
      stabilize !k c =
        let c' = step c
        in if c == c'
             then c'
             else stabilize (k - 1) c'

      !final = stabilize 4 initial

      -- Edge multiset, sorted, using final colours.
      edgeKey = sort [ (final V.! s, final V.! t)
                     | (s, t) <- inducedEdges ]
      -- Node multiset, as sentinel edges (-1, colour).
      nodeKey = sort [ (-1, c) | c <- V.toList final ]
  in MotifKey (nodeKey ++ edgeKey)

-- | Cheap commutative-but-position-aware hash. We avoid bringing in
-- @hashable@ for label hashing because the kind/state values have a
-- bounded enum range.
hashLabel :: Kind -> State -> Int
hashLabel k s = fromEnumKind k * 17 + fromEnumState s

-- | Combine a self-colour with a sorted neighbour-colour list.
hashCombine :: Int -> [(Int, Int)] -> Int
hashCombine self ns =
  foldl' (\acc (d, c) -> acc * 1000003 + d * 31 + c) (self * 2654435761) ns

-- | Local enum-to-Int for 'Kind'. We don't rely on derived 'Enum'
-- because the 'Kind' enum in 'AgdaGraph.Schema' doesn't derive it.
-- Hashing @show@ is robust to enum order changes.
fromEnumKind :: Kind -> Int
fromEnumKind = hashShow . show

-- | Local enum-to-Int for 'State'.
fromEnumState :: State -> Int
fromEnumState = hashShow . show

-- | Tiny FNV-ish hash for the @show@ output of a small enum.
hashShow :: String -> Int
hashShow = foldl' (\acc c -> acc * 131 + fromEnum c) 0

----------------------------------------------------------------------
-- Post-filter + ranking.

-- | Apply the post-filters:
--   * minSupport (MNI) ≥ threshold;
--   * if not per-module, at least 2 distinct host modules;
--   * drop pure paths of length ≤ 3 unless ≥ 2 distinct labels.
postFilter :: Index -> Options -> [Motif]
           -> [(Motif, Int, [Embedding])]
           -- ^ (motif, MNI, embeddings) — kept.
postFilter ix Options{..} = foldr step []
  where
    step m acc =
      let embs = mEmbeddings m
          mni  = mniSupport (mSize m) embs
          modCount = distinctModuleCount ix embs
          keep =
                mni >= optMinSupport
             && (optPerModule || modCount >= 2)
             && passesShapeFilter m
             && passesLabelFilter ix optMinLabelDistinct embs
      in if keep then (m, mni, embs) : acc else acc

-- | Reject motifs whose distinct @(Kind, State)@ label count over
-- their node set is below @threshold@. All embeddings of a given
-- motif share the same label multiset by construction (that's what
-- the WL canonicalization buys us), so it's safe to read the labels
-- off the /first/ embedding.
--
-- The label set is at most @optMaxSize@ elements (≤ 5 at the cap),
-- so 'Set.fromList' over a tiny list is the right tool here.
passesLabelFilter :: Index -> Int -> [Embedding] -> Bool
passesLabelFilter _  threshold _        | threshold <= 1 = True
passesLabelFilter _  _         []       = False
passesLabelFilter ix threshold (e0:_)   =
  let labels = [ (defKind d, defState d)
               | v <- V.toList e0
               , let d = defAt ix v
               ]
      !distinct = Set.size (Set.fromList labels)
  in distinct >= threshold

-- | MNI support: for each motif node v ∈ [0..size), count distinct
-- host ids that v maps to across embeddings; take the minimum.
-- O(size · embeddings).
mniSupport :: Int -> [Embedding] -> Int
mniSupport sz embs
  | null embs || sz <= 0 = 0
  | otherwise =
      let perNode :: V.Vector IS.IntSet
          !perNode = foldl' addOne
                       (V.replicate sz IS.empty)
                       embs
          addOne !v emb =
            V.imap (\i s -> IS.insert (emb V.! i) s) v
      in V.foldl' (\acc s -> min acc (IS.size s)) maxBound perNode

-- | Number of distinct host /modules/ that contribute at least one
-- node to /any/ embedding of the motif. This is a soft check — we
-- want the motif to not be a single-module artefact.
distinctModuleCount :: Index -> [Embedding] -> Int
distinctModuleCount ix embs =
  let allModules :: Set Text
      allModules = foldl' addEmb Set.empty embs
      addEmb !acc emb = V.foldl' (\a v -> Set.insert (defModule (defAt ix v)) a)
                                 acc emb
  in Set.size allModules

-- | "Shape filter": drop motifs that are uninteresting structurally.
-- Currently: pure paths (chains) of length ≤ 3 with ≤ 1 distinct
-- label.
passesShapeFilter :: Motif -> Bool
passesShapeFilter m =
  let MotifKey entries = mKey m
      -- Edge entries are (a, b) with a /= -1, b /= -1.
      edges = [ (a, b) | (a, b) <- entries, a /= -1, b /= -1 ]
      nodeColours = [ c | (a, c) <- entries, a == -1 ]
      distinctLabels = Set.size (Set.fromList nodeColours)
      sz = mSize m
      -- A "chain" has exactly sz-1 edges and every node has in+out
      -- degree at most 2.
      isChain =
           length edges == sz - 1
        && all (\c -> degIn c edges + degOut c edges <= 2) nodeColours
      degIn  c = length . filter (\(_, b) -> b == c)
      degOut c = length . filter (\(a, _) -> a == c)
  in not (sz <= 3 && isChain && distinctLabels <= 1)

-- | Rank motifs by @support * (size - 2)@, descending. Size-2 motifs
-- get a flat 0; size-1 are negative so they sort last (and are
-- filtered upstream by minSize >= 2 in @defaultOptions@).
rankMotifs :: [(Motif, Int, [Embedding])]
           -> [(Motif, Int, [Embedding])]
rankMotifs = sortOn (Down . score)
  where
    score (m, sup, _) = sup * max 0 (mSize m - 2)

----------------------------------------------------------------------
-- Rendering.

renderRow :: Index -> Int -> (Motif, Int, [Embedding]) -> [String]
renderRow ix rank (m, sup, embs) =
  let sz = mSize m
      sc = sup * max 0 (sz - 2)
      labels = labelsSummary ix embs sz
      site   = exampleSite ix embs
  in [ show rank
     , show sc
     , show sup
     , show sz
     , labels
     , site
     ]

-- | A compact summary of the motif's label multiset, taken from the
-- /first/ embedding (all embeddings share the same label multiset by
-- construction).
labelsSummary :: Index -> [Embedding] -> Int -> String
labelsSummary _  []      _ = "(empty)"
labelsSummary ix (e0:_)  _ =
  let labels = [ summariseLabel (defAt ix v) | v <- V.toList e0 ]
      counted = countOccur labels
      parts   = sortOn (Down . snd) (Map.toList counted)
      one (lbl, n) = T.unpack lbl <> " x" <> show n
  in case parts of
       []     -> "(empty)"
       (p:ps) -> foldl' (\acc x -> acc <> ", " <> one x) (one p) ps

summariseLabel :: Definition -> Text
summariseLabel d =
  let k = T.pack (showKindShort (defKind d))
      s = T.pack (showStateShort (defState d))
  in k <> ":" <> s

countOccur :: Ord a => [a] -> Map a Int
countOccur = foldl' (\m x -> Map.insertWith (+) x 1 m) Map.empty

showKindShort :: Kind -> String
showKindShort = drop 1 . show  -- drop leading 'K'

showStateShort :: State -> String
showStateShort = take 1 . show

-- | Pick one host QName from one embedding, just to ground the user.
-- We emit the fully-qualified name; the table column is wide enough.
exampleSite :: Index -> [Embedding] -> String
exampleSite _  []     = "(none)"
exampleSite ix (e0:_)
  | V.null e0 = "(empty)"
  | otherwise = T.unpack (defName (defAt ix (V.head e0)))

----------------------------------------------------------------------
-- JSON rendering. See the schema documented in 'AgdaOptimization.Report'.

-- | Build the top-level JSON value for one @motif@ invocation. Mirrors
-- the human-text fields one-to-one but in @snake_case@; the @motifs@
-- array follows the ranked order.
motifJson
  :: Index
  -> Options
  -> Set Text       -- ^ Host modules.
  -> IS.IntSet      -- ^ Hub-excluded node ids.
  -> [Motif]        -- ^ All considered buckets (post mining).
  -> [(Motif, Int, [Embedding])]
                    -- ^ Ranked + kept motifs.
  -> Bool           -- ^ Whether the wall-clock budget tripped.
  -> [(Motif, Int, [Embedding])]
                    -- ^ Top-N slice (what we emit).
  -> A.Value
motifJson ix opts hostMods excluded buckets ranked tripped shown =
  A.object
    [ "subcommand" .= ("motif" :: Text)
    , "options"    .= motifOptionsJson opts
    , "stats"      .= A.object
        [ "buckets_considered" .= length buckets
        , "buckets_kept"       .= length ranked
        , "hosts"              .= Set.size hostMods
        , "hub_excluded"       .= IS.size excluded
        , "budget_seconds"     .= optBudgetSecs opts
        , "budget_exhausted"   .= tripped
        ]
    , "motifs"     .= A.toJSON (zipWith (motifRowJson ix) [1..] shown)
    ]

motifOptionsJson :: Options -> A.Value
motifOptionsJson Options{..} = A.object
  [ "min_support"      .= optMinSupport
  , "min_size"         .= optMinSize
  , "max_size"         .= optMaxSize
  , "per_module"       .= optPerModule
  , "exclude_hub_pct"  .= optExcludeHubPct
  , "top_n"            .= optTopN
  , "max_fan_out"      .= optMaxFanOut
  , "budget_seconds"   .= optBudgetSecs
  ]

motifRowJson :: Index -> Int -> (Motif, Int, [Embedding]) -> A.Value
motifRowJson ix rank (m, sup, embs) =
  let sz = mSize m
      sc = sup * max 0 (sz - 2)
  in A.object
       [ "rank"         .= rank
       , "score"        .= sc
       , "support"      .= sup
       , "size"         .= sz
       , "labels"       .= labelsSummary ix embs sz
       , "example_site" .= exampleSite ix embs
       ]

