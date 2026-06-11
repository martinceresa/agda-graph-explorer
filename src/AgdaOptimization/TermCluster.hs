{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Cluster definitions by repeated canonical-form subterm hashes.
--
-- Reads the per-def @[Word64]@ array (@"definitionSubtermHashes"@)
-- that @agda-deps --with-term-hashes@ emits, and — when present — its
-- parallel @[Int]@ depth array (@"definitionSubtermDepths"@). For each
-- distinct hash, builds the multiset of @(defId, occurrence-count,
-- depth-sum)@ triples; ranks clusters by a composite score and
-- surfaces the top-N.
--
-- Composite score (with @--sort=score@, default):
--
-- @
--   score = size * meanDepth * (1 + diversity)
-- @
--
-- where
--
--   * @size@        = total occurrences across the project.
--   * @meanDepth@   = mean AST depth across occurrences (1 when the
--                     producer didn't emit depths).
--   * @diversity@   = Shannon entropy of the per-module
--                     occurrence distribution, normalised to [0, 1].
--                     0 when every occurrence is in one module;
--                     1 when uniformly spread across many modules.
--
-- Log-dampened ranking (with @--sort=log-score@):
--
-- @
--   logScore = log(max 1 size) * meanDepth * (1 + diversity)
-- @
--
-- Same factors, but replacing the raw @size@ multiplier with
-- @log(size)@ tames the orders-of-magnitude dominance of trivial
-- high-frequency shapes, giving small/deep/diverse clusters a fairer
-- shake. Use when the default ranking is buried under shallow
-- high-count noise.
--
-- Ranking by size alone is dominated by trivial high-frequency shapes;
-- the depth + diversity factors push the intended target (cross-file,
-- deeply-structured CSE candidates) to the top.
--
-- The hash itself is opaque (we don't carry the source 'Term' across
-- the JSON boundary); reports surface it as a 16-character hex
-- fingerprint so a human can grep for it.
module AgdaOptimization.TermCluster
  ( Options(..)
  , SortBy(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Control.Monad        ( guard, when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )
import           Data.Foldable        ( foldl' )
import qualified Data.IntMap.Strict   as IM
import           Data.IntMap.Strict   ( IntMap )
import qualified Data.IntSet          as IS
import           Data.IntSet          ( IntSet )
import           Data.List            ( sortBy )
import qualified Data.Map.Strict      as M
import           Data.Map.Strict      ( Map )
import           Data.Maybe           ( mapMaybe )
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Set             as S
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           Data.Word            ( Word64 )
import           Numeric              ( showHex )
import           System.IO            ( hPutStrLn, stderr )
import           Text.Printf          ( printf )
import           Text.Regex.TDFA      ( Regex, makeRegex, matchTest )

import           AgdaGraph.Index      ( Index(..), defAt )
import           AgdaGraph.Schema     ( Definition(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report   ( GlobalOpts(..), OutFormat(..)
                                           , renderTable, emitJsonReport
                                           , withHumanOutput )

-- ---------------------------------------------------------------------------
-- Options

-- | Ranking criterion for the cluster list. 'SortSize' ranks by total
-- occurrences. 'SortScore' (the default) uses
-- @size * meanDepth * (1 + diversity)@ to prioritise cross-file,
-- structurally deep clusters over high-frequency trivial ones.
-- 'SortLogScore' replaces @size@ with @log(size)@ to dampen the
-- orders-of-magnitude dominance of trivial high-frequency shapes.
data SortBy = SortSize | SortScore | SortLogScore
  deriving (Show, Eq)

-- | User-facing knobs.
data Options = Options
  { optMinCluster         :: !Int
    -- ^ Minimum @size@ (number of occurrences) for a cluster to be
    -- reported. Singletons (size 1) are never interesting; default 2.
  , optTopN               :: !Int
    -- ^ Maximum rows in the report.
  , optMaxDefs            :: !Int
    -- ^ Cap on the count of containing-def rows shown per cluster.
    -- Cosmetic — keeps the human report tight.
  , optSpanModules        :: !Int
    -- ^ Minimum distinct top-level modules a cluster's containing
    -- defs must span. Default 1 (no filtering). Higher values
    -- prioritise cross-file duplication.
  , optSortBy             :: !SortBy
    -- ^ Ranking criterion: 'SortScore' (default), 'SortLogScore', or 'SortSize'.
  , optMinMeanDepth       :: !Int
    -- ^ Minimum mean AST subterm depth (floor at the cluster level).
    -- Default 0 (no filter). Lets users drop shallow high-frequency
    -- clusters without resorting to @--span-modules@, which has
    -- false-negative behaviour for legitimate within-module CSE
    -- candidates.
  , optMinDiversity       :: !Double
    -- ^ Minimum Shannon-entropy module diversity for a cluster to be
    -- reported. Default 0.0 (no filter). Useful values: 0.3 drops
    -- the dominant within-one-module noise; 0.7 keeps only clusters
    -- whose occurrences are well-distributed across modules.
  , optExcludeModuleRegex :: !Text
    -- ^ POSIX-ERE on the declared module name (anonymous where-helper
    -- segments stripped before matching). Defs whose module matches
    -- are dropped from every cluster before counting. Empty string
    -- (the default) disables the filter. Useful for filtering
    -- standard-library traffic on real corpora.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optMinCluster         = 2
  , optTopN               = 50
  , optMaxDefs            = 3
  , optSpanModules        = 1
  , optSortBy             = SortScore
  , optMinMeanDepth       = 0
  , optMinDiversity       = 0.0
  , optExcludeModuleRegex = T.empty
  }

-- | Parse @--sort=size|score|log-score@.
parseSortBy :: String -> Either String SortBy
parseSortBy "size"      = Right SortSize
parseSortBy "score"     = Right SortScore
parseSortBy "log-score" = Right SortLogScore
parseSortBy s           =
  Left $ "expected one of: size, score, log-score (got " ++ show s ++ ")"

-- | Declarative flag table for the @term-cluster@ subcommand. Drives the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--sort@ is an 'EnumWrapped' enum (a rejected token is wrapped as
-- @term-cluster: --sort: …@). The declaration order matches the former
-- hand-rolled @applyConfig@ overlay sequence.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "min-cluster" "--min-cluster=N                 minimum occurrences for a cluster to be reported (default 2)"
      (\n o -> o { optMinCluster = n })
  , IntFlag "top-n" "--top-n=N                       rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , IntFlag "max-defs" "--max-defs=N                    top-defs shown per cluster row (default 3)"
      (\n o -> o { optMaxDefs = n })
  , IntFlag "span-modules" "--span-modules=N                minimum distinct modules a cluster's defs must span (default 1)"
      (\n o -> o { optSpanModules = n })
  , EnumFlag "sort" "--sort=score|log-score|size     ranking criterion (default score = size*meanDepth*(1+diversity);"
      parseSortBy EnumWrapped (\e o -> o { optSortBy = e })
  , IntFlag "min-mean-depth" "--min-mean-depth=N              minimum mean AST subterm depth for a cluster (default 0)"
      (\n o -> o { optMinMeanDepth = n })
  , DblFlag "min-diversity" "--min-diversity=F               minimum module-distribution Shannon entropy (default 0.0; try 0.7)"
      (\x o -> o { optMinDiversity = x })
  , TextFlag "exclude-module-regex" "--exclude-module-regex=PATTERN  POSIX-ERE on declared module; drop matching defs before counting"
      (\t o -> o { optExcludeModuleRegex = t })
  ]

parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "term-cluster" flagSpecs

-- | Overlay the @term-cluster:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "term-cluster" flagSpecs obj o0

-- ---------------------------------------------------------------------------
-- Analysis

-- | Per-cluster bucket built during occurrence scanning. Strict
-- everywhere so we can stream-fold without thunk build-up.
data BucketAcc = BucketAcc
  { baInner    :: !(IntMap Int)  -- ^ defId -> per-def occurrence count
  , baSumDepth :: !Int           -- ^ sum of depths over all occurrences
  , baCount    :: !Int           -- ^ total occurrences (= sum baInner)
  }

instance NFData BucketAcc where
  rnf (BucketAcc i d c) = rnf i `seq` rnf d `seq` rnf c

-- | One reported cluster row.
data Cluster = Cluster
  { cHash         :: !Word64
  , cSize         :: !Int
    -- ^ Total occurrences. Equals 'baCount' of the underlying bucket.
  , cDefCount     :: !Int
    -- ^ Number of distinct definitions containing >=1 occurrence.
  , cModuleCount  :: !Int
    -- ^ Number of distinct declared modules across @cDefCount@'s defs.
  , cMeanDepth    :: !Double
    -- ^ Mean AST depth across occurrences. 1.0 when the producer
    -- didn't emit depth data (acts as a no-op multiplier in scoring).
  , cDiversity    :: !Double
    -- ^ Shannon entropy of the per-declared-module occurrence
    -- distribution, normalised to [0, 1] by @log min(|modules|, 10)@.
    -- 0 when every occurrence is in one module; 1 when uniformly
    -- spread over many.
  , cScore        :: !Double
    -- ^ Composite ranking score, @size * meanDepth * (1 + diversity)@.
  , cLogScore     :: !Double
    -- ^ Log-dampened ranking score,
    -- @log(max 1 size) * meanDepth * (1 + diversity)@.
  , cTopDefs      :: ![(Int, Int)]
    -- ^ Top @optMaxDefs@ (defId, per-def occurrence count) pairs,
    -- biggest first.
  }

instance NFData Cluster where
  rnf (Cluster h s dc mc md d sc ls td) =
    rnf h `seq` rnf s `seq` rnf dc `seq` rnf mc `seq` rnf md
          `seq` rnf d `seq` rnf sc `seq` rnf ls `seq` rnf td

run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = case idxSubtermHashes ix of
  Nothing -> do
    hPutStrLn stderr
      "agda-optimization term-cluster: graph.json carries no \
      \'definitionSubtermHashes' field."
    hPutStrLn stderr
      "  Re-run agda-deps with --with-term-hashes to enable this analysis."
    case gOutFormat gOpts of
      OutJson  -> emitJsonReport (gOutPath gOpts) (emptyReportJson opts)
      OutHuman -> withHumanOutput (gOutPath gOpts) $
        putStrLn "# term-cluster — no data (producer ran without --with-term-hashes)"
  Just sthMap -> do
    let stdMap          = idxSubtermDepths ix  -- Maybe (IntMap [Int])
        hasDepths       = case stdMap of
                            Just m  -> not (IM.null m)
                            Nothing -> False
        !excluded       = excludedDefIds ix optExcludeModuleRegex
        !buckets        = buildBuckets ix sthMap stdMap excluded
        !totalHashes    = totalHashCount sthMap
        !distinctHashes = M.size buckets
        !ranked         = rankClusters ix opts buckets
        !shown          = take optTopN ranked
    when (not hasDepths) $ hPutStrLn stderr
      "agda-optimization term-cluster: note: graph.json has no \
      \'definitionSubtermDepths' field — meanDepth defaults to 1.0 \
      \and the --sort=score ranking collapses to size×(1+diversity). \
      \Re-run agda-deps for full P3-R1 ranking."
    case gOutFormat gOpts of
      OutJson  -> emitJsonReport (gOutPath gOpts)
                    (reportJson ix opts totalHashes distinctHashes
                                hasDepths (IS.size excluded) shown)
      OutHuman -> withHumanOutput (gOutPath gOpts) $
        emitHuman ix opts totalHashes distinctHashes
                  hasDepths (IS.size excluded) (length ranked) shown

-- | Sum every per-def hash list.
totalHashCount :: IntMap [Word64] -> Int
totalHashCount = IM.foldl' (\acc xs -> acc + length xs) 0

-- | Compute the set of def ids whose declared module matches the
-- exclusion regex. Empty pattern => empty set (filter disabled).
excludedDefIds :: Index -> Text -> IntSet
excludedDefIds ix pat
  | T.null pat = IS.empty
  | otherwise  =
      let !re = makeRegex (T.unpack pat) :: Regex
          test t = matchTest re (T.unpack t)
      in IS.fromList
           [ i
           | i <- [0 .. idxRealCount ix - 1]
           , test (declaredModuleName (defModule (defAt ix i)))
           ]

-- | Walk every (hash, depth) pair across every def in the index,
-- bucketing by hash. Skips occurrences from defs whose id is in the
-- @excluded@ set. When @depthMap@ is 'Nothing' we treat each
-- occurrence as having depth 1 (a no-op multiplier in scoring), so
-- old graph.json files (with hashes but no depths) still produce a
-- usable cluster ranking.
--
-- Parallelised: defs are split into ~64 chunks, each chunk folds into
-- a local @Map Word64 BucketAcc@ in parallel (@parMap rdeepseq@), and
-- the partials are merged with 'M.unionsWith' over the
-- associative-commutative 'mergeBucket'. Determinism: chunking is
-- defId-order-stable and the merge is associative-commutative, so the
-- result is byte-identical regardless of @+RTS -NK@.
buildBuckets
  :: Index
  -> IntMap [Word64]
  -> Maybe (IntMap [Int])
  -> IntSet
  -> Map Word64 BucketAcc
buildBuckets _ix sthMap stdMap excluded =
  let !entries =
        [ (defId, hs)
        | (defId, hs) <- IM.toAscList sthMap
        , not (IS.member defId excluded)
        ]
      !nEntries = length entries
      -- Target ~64 chunks but never finer than ~32 defs per chunk —
      -- small corpora degrade to a single chunk and skip spark
      -- overhead entirely.
      !nChunks  = max 1 (min 64 ((nEntries + 31) `div` 32))
      !chunkSz  = max 1 ((nEntries + nChunks - 1) `div` nChunks)
      !chunks   = chunksOf chunkSz entries
      !partials = parMap rdeepseq foldChunk chunks
  in M.unionsWith mergeBucket partials
  where
    foldChunk :: [(Int, [Word64])] -> Map Word64 BucketAcc
    foldChunk = foldl' addDef M.empty

    addDef :: Map Word64 BucketAcc -> (Int, [Word64]) -> Map Word64 BucketAcc
    addDef !outer (defId, hs) =
      let ds = case stdMap of
            Just m  -> IM.findWithDefault [] defId m
            Nothing -> []
          -- Walk hashes and depths in lock-step. If we somehow run
          -- out of depths (older JSON / producer mismatch), use 1
          -- as a no-op contribution to the depth statistics.
          pairs = zipPad hs ds
      in foldl' (addOne defId) outer pairs

    addOne :: Int -> Map Word64 BucketAcc -> (Word64, Int)
           -> Map Word64 BucketAcc
    addOne !defId !outer (h, d) =
      let bump (Just !b)  = Just $! BucketAcc
                                      (IM.insertWith (+) defId 1 (baInner b))
                                      (baSumDepth b + d)
                                      (baCount b + 1)
          bump Nothing    = Just $! BucketAcc (IM.singleton defId 1) d 1
      in M.alter bump h outer

-- | Associative-commutative bucket combiner: sum per-def counts,
-- depth sums, and total counts. Used to merge partial maps from
-- 'buildBuckets' chunks.
mergeBucket :: BucketAcc -> BucketAcc -> BucketAcc
mergeBucket (BucketAcc i1 d1 c1) (BucketAcc i2 d2 c2) =
  BucketAcc (IM.unionWith (+) i1 i2) (d1 + d2) (c1 + c2)

-- | Split a list into chunks of size @k@. @k <= 0@ is clamped to 1.
chunksOf :: Int -> [a] -> [[a]]
chunksOf k xs0
  | k <= 0    = chunksOf 1 xs0
  | otherwise = go xs0
  where
    go [] = []
    go xs = let (h, t) = splitAt k xs in h : go t

-- | Zip hashes with depths; when the depths list is shorter (or
-- empty), pad with @1@. Pairs are produced lazily and consumed once
-- by the accumulator fold.
zipPad :: [Word64] -> [Int] -> [(Word64, Int)]
zipPad = go
  where
    go []     _      = []
    go (h:hs) []     = (h, 1) : go hs []
    go (h:hs) (d:ds) = (h, d) : go hs ds

-- | Build & sort the cluster list. Filtered by 'optMinCluster' and
-- 'optSpanModules'; sorted descending by 'optSortBy'.
--
-- @cMeanDepth@ defaults to 1.0 when no depth data is in scope, so
-- the multiplicative @score = size * meanDepth * (1 + diversity)@
-- gracefully degrades to @size * (1 + diversity)@.
--
-- Parallelised: the cheap @optMinCluster@ filter runs sequentially
-- (most buckets are size 1–2 and fail it without spark overhead),
-- then survivors are chunked and 'parMap' computes ~64 chunks in
-- parallel. Coarse chunking avoids spark-pool overflow on corpora
-- where the survivor list runs into the tens of thousands. 'parMap'
-- preserves list order, so the final 'sortBy' (a stable sort on a
-- deterministic key) is byte-identical under any @+RTS -NK@.
rankClusters :: Index -> Options -> Map Word64 BucketAcc -> [Cluster]
rankClusters ix Options{..} buckets =
  let -- Cheap pre-filter: drop trivially-small buckets serially.
      !survivors =
        [ entry
        | entry@(_, BucketAcc _ _ total) <- M.toAscList buckets
        , total >= optMinCluster
        ]
      !nSurv    = length survivors
      !nChunks  = max 1 (min 64 ((nSurv + 31) `div` 32))
      !chunkSz  = max 1 ((nSurv + nChunks - 1) `div` nChunks)
      !chunks   = chunksOf chunkSz survivors
      mkBatch   = mapMaybe (mkCluster ix opts)
      !raw      = concat (parMap rdeepseq mkBatch chunks)
      cmp = case optSortBy of
        SortScore    -> comparing (\c -> (Down (cScore c),    Down (cSize c), cHash c))
        SortLogScore -> comparing (\c -> (Down (cLogScore c), Down (cSize c), cHash c))
        SortSize     -> comparing (\c -> (Down (cSize c),     Down (cDefCount c), cHash c))
  in sortBy cmp raw
  where
    opts = Options{..}

-- | Build a 'Cluster' from a bucket, applying every threshold beyond
-- the cheap @optMinCluster@ size guard. Returns 'Nothing' if any
-- threshold (span-modules, min-mean-depth, min-diversity) fails. Pure
-- and self-contained — safe to drive from 'parMap'.
mkCluster :: Index -> Options -> (Word64, BucketAcc) -> Maybe Cluster
mkCluster ix Options{..} (h, BucketAcc inner sumDepth total) = do
  let !modCount = moduleCountOf ix inner
  guard (modCount >= optSpanModules)
  let !meanDepth = if total > 0 && sumDepth > 0
                     then fromIntegral sumDepth / fromIntegral total
                     else 1.0
  guard (meanDepth >= fromIntegral optMinMeanDepth)
  let !diversity = moduleDiversity ix inner
  guard (diversity >= optMinDiversity)
  pure $! Cluster
    { cHash        = h
    , cSize        = total
    , cDefCount    = IM.size inner
    , cModuleCount = modCount
    , cMeanDepth   = meanDepth
    , cDiversity   = diversity
    , cScore       = fromIntegral total * meanDepth * (1 + diversity)
    , cLogScore    = log (fromIntegral (max 1 total) :: Double)
                     * meanDepth * (1 + diversity)
    , cTopDefs     = take optMaxDefs $
                       sortBy (comparing (Down . snd)) (IM.toList inner)
    }

-- | Number of distinct /declared/ top-level module names among the
-- given def ids. See 'declaredModuleName' for the @_@-stripping rule.
moduleCountOf :: Index -> IntMap Int -> Int
moduleCountOf ix inner =
  S.size $ foldl'
    (\ !acc defId ->
       S.insert (declaredModuleName (defModule (defAt ix defId))) acc)
    S.empty
    (IM.keys inner)

-- | Shannon entropy of the per-module occurrence distribution,
-- normalised to [0, 1].
--
-- Computed as @H = -sum p_i log p_i@ where @p_i@ is module @i@'s
-- share of total occurrences (each def's per-def count contributes).
-- Then normalised by @log min(k, 10)@ where @k@ is the module
-- count, so a uniformly-spread cluster across 10+ modules scores
-- close to 1.0. Returns 0 when total <= 0 or k <= 1 (deterministic
-- floor, avoids @log 0@).
moduleDiversity :: Index -> IntMap Int -> Double
moduleDiversity ix inner =
  let perMod :: Map Text Int
      !perMod = IM.foldlWithKey'
        (\ !acc defId cnt ->
           let m = declaredModuleName (defModule (defAt ix defId))
           in M.insertWith (+) m cnt acc)
        M.empty inner
      !total = M.foldl' (+) 0 perMod
      !k     = M.size perMod
  in if total <= 0 || k <= 1
       then 0
       else
         let !h = M.foldl'
                    (\ !acc cnt ->
                       if cnt <= 0
                         then acc
                         else
                           let p = fromIntegral cnt / fromIntegral total :: Double
                           in acc - p * log p)
                    0 perMod
             !kCap  = min k 10
             !denom = log (fromIntegral kCap :: Double)
         in if denom <= 0 then 0 else h / denom

-- | Strip Agda's anonymous-where-helper @_@ suffix segments from a
-- module name. The literal segment @"_"@ (and only that) is the
-- compiler-generated marker — segments like @"_≡_"@ or @"_∧_"@ are
-- legitimate user-defined names and are preserved.
declaredModuleName :: Text -> Text
declaredModuleName m =
  let parts = T.splitOn "." m
      kept  = reverse (dropWhile (== T.pack "_") (reverse parts))
  in T.intercalate "." kept

-- ---------------------------------------------------------------------------
-- Human output

emitHuman
  :: Index -> Options -> Int -> Int
  -> Bool       -- ^ depth data present
  -> Int        -- ^ excluded def count
  -> Int -> [Cluster] -> IO ()
emitHuman ix Options{..} totalHashes distinctHashes hasDepths nExcluded nRanked shown = do
  putStrLn $ "# term-cluster — top " ++ show optTopN
          ++ " (sort=" ++ sortTag
          ++ ", min-cluster=" ++ show optMinCluster
          ++ ", span-modules=" ++ show optSpanModules
          ++ ", min-mean-depth=" ++ show optMinMeanDepth ++ ")"
  putStrLn $ "  total subterm hashes        : " ++ show totalHashes
  putStrLn $ "  distinct hashes             : " ++ show distinctHashes
  putStrLn $ "  clusters surviving filters  : " ++ show nRanked
  when (nExcluded > 0) $
    putStrLn $ "  defs filtered (regex)       : " ++ show nExcluded
  when (not hasDepths) $
    putStrLn   "  (no depth data — meanDepth defaults to 1.0)"
  putStrLn ""
  case shown of
    [] -> putStrLn "no clusters at these thresholds"
    _  -> do
      let scoreOf c = case optSortBy of
            SortLogScore -> cLogScore c
            _            -> cScore c
          renderRow rank c =
            [ show rank
            , hexHash16 (cHash c)
            , show (cSize c)
            , show (cDefCount c)
            , show (cModuleCount c)
            , printf "%.2f" (cMeanDepth c)
            , printf "%.3f" (cDiversity c)
            , printf "%.2f" (scoreOf c)
            , showTopDefs ix (cTopDefs c)
            ]
          header = ["Rank","Hash","Size","|defs|","|mods|","MeanD","Div",scoreHeader,"TopDefs"]
          rows   = zipWith renderRow [(1::Int)..] shown
      putStr (renderTable header rows)
  when (not (null shown) && all (\c -> cSize c == optMinCluster) shown) $
    putStrLn "  (every shown cluster is at --min-cluster; try a higher threshold to surface large shapes)"
  where
    sortTag = case optSortBy of
      SortScore    -> "score"
      SortLogScore -> "log-score"
      SortSize     -> "size"
    scoreHeader = case optSortBy of
      SortLogScore -> "LogScore"
      _            -> "Score"

-- | Render the top-defs list inline: @qname×count, qname×count, …@.
showTopDefs :: Index -> [(Int, Int)] -> String
showTopDefs ix = T.unpack . T.intercalate ", " . map one
  where
    one (defId, k) =
      let d = defAt ix defId
      in defName d <> T.pack ("\x00D7" ++ show k)

-- | 16-character zero-padded hex of a 'Word64' fingerprint.
hexHash16 :: Word64 -> String
hexHash16 w =
  let s = showHex w ""
  in replicate (max 0 (16 - length s)) '0' ++ s

-- ---------------------------------------------------------------------------
-- JSON output

reportJson
  :: Index -> Options -> Int -> Int
  -> Bool   -- ^ depth data present
  -> Int    -- ^ excluded def count
  -> [Cluster] -> A.Value
reportJson ix opts totalHashes distinctHashes hasDepths nExcluded shown =
  A.object
    [ "subcommand" .= ("term-cluster" :: Text)
    , "options"    .= optionsJson opts
    , "stats"      .= A.object
        [ "total_subterm_hashes" .= totalHashes
        , "distinct_hashes"      .= distinctHashes
        , "clusters_shown"       .= length shown
        , "depth_data_present"   .= hasDepths
        , "excluded_def_count"   .= nExcluded
        ]
    , "rows" .= A.toJSON (zipWith (clusterJson ix) [1 :: Int ..] shown)
    ]

emptyReportJson :: Options -> A.Value
emptyReportJson opts =
  A.object
    [ "subcommand" .= ("term-cluster" :: Text)
    , "options"    .= optionsJson opts
    , "stats"      .= A.object
        [ "total_subterm_hashes" .= (0 :: Int)
        , "distinct_hashes"      .= (0 :: Int)
        , "clusters_shown"       .= (0 :: Int)
        , "reason"               .= ("no definitionSubtermHashes in graph.json" :: Text)
        ]
    , "rows" .= ([] :: [A.Value])
    ]

optionsJson :: Options -> A.Value
optionsJson Options{..} = A.object
  [ "min_cluster"          .= optMinCluster
  , "top_n"                .= optTopN
  , "max_defs"             .= optMaxDefs
  , "span_modules"         .= optSpanModules
  , "sort"                 .= sortTag optSortBy
  , "min_mean_depth"       .= optMinMeanDepth
  , "min_diversity"        .= optMinDiversity
  , "exclude_module_regex" .= optExcludeModuleRegex
  ]
  where
    sortTag :: SortBy -> Text
    sortTag SortScore    = "score"
    sortTag SortLogScore = "log-score"
    sortTag SortSize     = "size"

clusterJson :: Index -> Int -> Cluster -> A.Value
clusterJson ix rank Cluster{..} = A.object
  [ "rank"         .= rank
  , "hash"         .= hexHash16 cHash
  , "size"         .= cSize
  , "def_count"    .= cDefCount
  , "module_count" .= cModuleCount
  , "mean_depth"   .= cMeanDepth
  , "diversity"    .= cDiversity
  , "score"        .= cScore
  , "log_score"    .= cLogScore
  , "top_defs"     .= A.toJSON (map (defPair ix) cTopDefs)
  ]

defPair :: Index -> (Int, Int) -> A.Value
defPair ix (defId, k) =
  let d = defAt ix defId
  in A.object
       [ "qname"  .= defName d
       , "module" .= defModule d
       , "count"  .= k
       ]
