{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | ConceptBundle — frequent-itemset mining over each definition's
-- /signature-provenance/ edges.
--
-- Where 'AgdaOptimization.Basket' mines all out-edges (body + with +
-- where + signature), ConceptBundle restricts to the **signature**
-- subgraph: every edge whose 'idxEdgeProvenance' tag is
-- 'ProvSignature'. The intuition is that two lemmas whose /type
-- signatures/ converge on the same vocabulary of helper qnames are
-- candidates for a shared record / named bundle, even when their
-- /bodies/ are entirely different.
--
-- This catches @DeliveryGuarantee@-style bundles: every lemma whose
-- statement bundles the same set of tokens (e.g. @{honest, receives,
-- GST, Δ}@) wants to share a record, but if those tokens never appear
-- as a body-AST clone, 'AgdaOptimization.Fingerprint' and the
-- term-cluster pass both miss it. The signature-only view exposes the
-- bundle.
--
-- Pipeline:
--
--   1. Build per-def signature baskets: items are real defs reached
--      via a 'ProvSignature' edge. Empty baskets are dropped; baskets
--      of size 1 contribute to L1 counts but never to L2+.
--   2. Apriori (k ≤ 'optKMax', default 3) over baskets: L1, L2, L3
--      (L4 opt-in via @--k-max=4@). Anti-monotone prune at every
--      level. Configurable @--min-support=N@ as an absolute count
--      (proof corpora are small; fractional support misses the long
--      tail). Baskets above @--max-basket-size@ (default 64) are
--      dropped before counting — without this cap a single 4000-item
--      signature on large-scale corpora explodes L2.
--   3. Score each frequent itemset of size ≥ 2 by:
--        * @support@: number of baskets containing it,
--        * @lift@: support / (product of unigram supports / N^{k-1}),
--        * @moduleSpan@: number of distinct modules whose defs
--          contribute to the itemset's support; ≥ 3 is the "real
--          cross-cutting bundle" gate (otherwise the itemset is a
--          single module's private idiom).
--   4. Sort by @specificity = support * lift * log moduleSpan@,
--      take @--top-n@.
--
-- The implementation mirrors 'AgdaOptimization.Basket' deliberately:
-- same chunk-fold pattern, same anti-monotone prune. Different
-- feature space, same machinery.
module AgdaOptimization.ConceptBundle
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq         ( NFData, rnf )
import           Control.Exception       ( evaluate )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.IntMap.Strict      as IM
import           Data.IntMap.Strict      ( IntMap )
import qualified Data.IntSet             as IS
import           Data.IntSet             ( IntSet )
import           Data.List               ( sortOn, sort )
import qualified Data.Map.Strict         as Map
import           Data.Map.Strict         ( Map )
import           Data.Ord                ( Down(..) )
import qualified Data.Set                as Set
import           Data.Set                ( Set )
import qualified Data.Text               as T

import qualified Data.Aeson              as A
import           Data.Aeson              ( (.=) )

import           AgdaGraph.Index         ( Index(..), defAt )
import           AgdaGraph.Schema        ( Definition(..), Provenance(..) )
import           AgdaOptimization.Common ( shortName, showD
                                         , orderPair, orderTriple
                                         , chunksOf, computeTopFreqItems )
import           AgdaOptimization.FamilyFilter ( isForcedByFamily )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , showD3, withHumanOutput )

----------------------------------------------------------------------
-- Options.

data Options = Options
  { optMinSupport   :: !Int
    -- ^ Minimum number of baskets an itemset must appear in. Absolute
    -- count, not fraction (proof corpora are small; 3-5 typical).
  , optMinLift      :: !Double
    -- ^ Itemset lift threshold: @support / expected@. Default 2.0.
  , optMinSpan      :: !Int
    -- ^ Itemset must span ≥ this many distinct modules to count as a
    -- cross-cutting bundle. Default 3. @1@ disables the filter.
  , optTopN         :: !Int
    -- ^ Cap on the number of itemsets retained after sorting.
  , optKMax         :: !Int
    -- ^ Maximum itemset size. Default 3. L4 enumeration explodes on
    -- real corpora (trillions of candidate quad-incidences without a
    -- basket cap; even capped, the L4 count map can exceed several GiB
    -- of heap). Opt into k=4 explicitly with a tight 'optMaxBasketSize'
    -- on small corpora.
  , optExcludeTopFreq :: !Double
    -- ^ Drop itemsets whose items include the top @P%@ most-frequent
    -- single items. Mirrors Basket's filter to suppress universal
    -- primitives (@Set@, @ℕ@, @_≡_@). Range [0, 100]; default 5.
  , optForcedSuppress :: !Bool
    -- ^ Forced-by-elaborator suppressor. When 'True' (default), drop
    -- bundles dominated by a per-case-unfold family (items matching
    -- @^(stem)-(\\d+)$@ with ≥ 2 same-stem members). See
    -- 'AgdaOptimization.FamilyFilter' for the detector. Disable with
    -- @--no-forced-suppress@.
  , optForcedFraction :: !Double
    -- ^ Fraction-of-bundle gate for 'optForcedSuppress'. A bundle is
    -- suppressed when ≥ this fraction of its items belong to one
    -- family. Default 0.5.
  , optMaxBasketSize  :: !Int
    -- ^ Drop baskets whose qualifying-item count exceeds this cap
    -- before L2+ counting. Prevents combinatorial blow-up on huge
    -- signatures: a basket of @b@ items yields @C(b, k)@ tuples, so a
    -- few-thousand-item signature can exhaust RAM at k=2. @0@ disables
    -- the cap. Default 64.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optMinSupport     = 3
  , optMinLift        = 2.0
  , optMinSpan        = 3
  , optTopN           = 50
  , optKMax           = 3
  , optExcludeTopFreq = 5.0
  , optForcedSuppress = True
  , optForcedFraction = 0.5
  , optMaxBasketSize  = 64
  }

-- | Declarative flag table for the @concept-bundle@ subcommand. Drives
-- the argv parser ('parseOptions') and the YAML overlay ('applyConfig'),
-- and is the single source of truth the help-derivation stage reads.
-- Each help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--forced-suppress@ / @--no-forced-suppress@ are 'SwitchIgnoreValue'
-- switches (an attached @=value@ is ignored). They share a single YAML
-- key (@forced-suppress@), carried by the @--forced-suppress@ entry; the
-- @--no-forced-suppress@ entry takes no part in the overlay ('Nothing').
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "min-support" "--min-support=N                 absolute support count (default 3)"
      (\x o -> o { optMinSupport = x })
  , DblFlag "min-lift" "--min-lift=F                    lift threshold (default 2.0)"
      (\x o -> o { optMinLift = x })
  , IntFlag "min-span" "--min-span=N                    min distinct modules a bundle must span (default 3)"
      (\x o -> o { optMinSpan = x })
  , IntFlag "top-n" "--top-n=N                       rows to keep (default 50)"
      (\x o -> o { optTopN = x })
  , IntFlag "k-max" "--k-max=N                       max itemset size; 2-4 (default 4)"
      (\x o -> o { optKMax = x })
  , DblFlag "exclude-top-frequency" "--exclude-top-frequency=F       drop bundles with top-pct% items; 0 = disabled (default 5.0)"
      (\x o -> o { optExcludeTopFreq = x })
  , SwitchFlag "no-forced-suppress" "--no-forced-suppress            disable the per-case-unfold-family suppressor"
      SwitchIgnoreValue (\o -> o { optForcedSuppress = False })
      Nothing (\_ o -> o)
  , SwitchFlag "forced-suppress" "--forced-suppress               re-enable the suppressor (default on)"
      SwitchIgnoreValue (\o -> o { optForcedSuppress = True })
      (Just "forced-suppress") (\v o -> o { optForcedSuppress = v })
  , DblFlag "forced-fraction" "--forced-fraction=F             bundle-fraction gate for the suppressor (default 0.5)"
      (\x o -> o { optForcedFraction = x })
  , IntFlag "max-basket-size" "--max-basket-size=N             drop baskets exceeding N items before counting; 0 = disabled (default 64)"
      (\x o -> o { optMaxBasketSize = x })
  ]

parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "concept-bundle" flagSpecs

applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "concept-bundle" flagSpecs obj o0

----------------------------------------------------------------------
-- Internal types.

-- | One basket: an owner def id + the set of signature-provenance
-- items, as a sorted item list (for cheap pair-walking) + an IntSet
-- (for membership tests).
data Basket = Basket
  { bkOwner   :: !Int
  , bkItems   :: ![Int]
  , bkItemSet :: !IntSet
  } deriving (Show)

-- | A frequent itemset of size k ≥ 2, with all the metrics we'll sort
-- on.
data Bundle = Bundle
  { bunItems    :: ![Int]
  , bunSupport  :: !Int
  , bunLift     :: !Double
  , bunSpan     :: !Int      -- number of distinct modules covered
  , bunOwners   :: ![Int]    -- def ids whose basket contained the itemset
                              -- (truncated to ≤ 10 for the report)
  } deriving (Show)

data Stats = Stats
  { sTotalTx        :: !Int
  , sQualifyingTx   :: !Int
  , sCappedTx       :: !Int
    -- ^ Baskets that passed @length ≥ 2@ but were dropped from L2+
    -- counting because they exceeded 'optMaxBasketSize'. Surfaces in
    -- the stats line so the user can spot when the cap is doing real
    -- work (and consider relaxing it).
  , sL1Count        :: !Int
  , sL2Count        :: !Int
  , sL3Count        :: !Int
  , sL4Count        :: !Int
  , sTopFreqExcluded :: !Int
  , sBundlesKept    :: !Int
  , sForcedSuppressed :: !Int
    -- ^ Bundles dropped by the per-case-unfold-family suppressor before
    -- sorting.
  , sFallbackMode   :: !Bool
    -- ^ True iff the JSON had no @definitionEdgesProvenance@ field,
    -- so we degraded to all-edges. Surfaces in the header as
    -- "(provenance: missing — falling back to all edges)".
  } deriving (Show)

----------------------------------------------------------------------
-- Entry point.

run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let (!txsAll, !fallback) = buildBaskets ix
      !txsQual = qualifying txsAll
      (!txs, !nCapped) = capLargeBaskets (optMaxBasketSize opts) txsQual
      !n     = length txs

      -- Item -> count of baskets containing it.
      itemCounts :: IntMap Int
      !itemCounts = foldl' countBk IM.empty txs
        where
          countBk !acc (Basket _ _ s) =
            IS.foldl' (\m i -> IM.insertWith (+) i 1 m) acc s

      !minSup    = max 1 (optMinSupport opts)
      -- L1: singletons above support.
      !l1 = IS.fromList
              [ i | (i, c) <- IM.toList itemCounts, c >= minSup ]

      !topFreqItems = computeTopFreqItems (optExcludeTopFreq opts) itemCounts

      supOf :: Int -> Int
      supOf i = IM.findWithDefault 0 i itemCounts

  -- L2 — count-only Map (mirrors Basket). Owner lists are NOT stored
  -- here: that would accumulate millions of pair-incidences as cons
  -- cells before any support prune fires. Owners are collected in a
  -- second post-prune pass ('collectInfo').
  let l2 :: Map (Int, Int) Int
      !l2 = Map.filter (>= minSup) (countPairs txs l1)

  -- L3 — only if k-max ≥ 3.
  let l3 :: Map (Int, Int, Int) Int
      !l3 = if optKMax opts < 3
              then Map.empty
              else Map.filter (>= minSup) (countTriples txs l1 l2)

  -- L4 — only if k-max ≥ 4.
  let l4 :: Map (Int, Int, Int, Int) Int
      !l4 = if optKMax opts < 4
              then Map.empty
              else Map.filter (>= minSup) (countQuads txs l1 l3)

  _ <- evaluate (rnf l4)

  -- Second pass over baskets to collect owner samples + module sets,
  -- but only for surviving frequent itemsets. Allocations are bounded
  -- by |frequent itemsets| × 10 (sample cap), not by total incidences.
  let (!info2, !info3, !info4) = collectInfo ix l2 l3 l4 txs

  let -- Build bundles from L2/L3/L4, score by lift + span.
      l2bundles =
        [ mkBundle [a, b] supC info n supOf
        | ((a, b), supC) <- Map.toList l2
        , let info = Map.findWithDefault emptyInfo (a, b) info2
        ]
      l3bundles =
        [ mkBundle [a, b, c] supC info n supOf
        | ((a, b, c), supC) <- Map.toList l3
        , let info = Map.findWithDefault emptyInfo (a, b, c) info3
        ]
      l4bundles =
        [ mkBundle [a, b, c, d] supC info n supOf
        | ((a, b, c, d), supC) <- Map.toList l4
        , let info = Map.findWithDefault emptyInfo (a, b, c, d) info4
        ]

      candidates :: [Bundle]
      candidates = l2bundles ++ l3bundles ++ l4bundles

      excludeIds = topFreqItems

      passes :: Bundle -> Bool
      passes b =
           bunLift b    >= optMinLift opts
        && bunSpan b    >= optMinSpan opts
        && not (any (`IS.member` excludeIds) (bunItems b))

      filtered = filter passes candidates

      -- Forced-suppression. Drops bundles dominated by one
      -- per-case-unfold family. See 'AgdaOptimization.FamilyFilter'.
      (!afterForced, !forcedDropped) =
        if optForcedSuppress opts
          then partitionForced ix (optForcedFraction opts) filtered
          else (filtered, 0)

      ranked = sortOn (Down . specificity) afterForced

      !cap       = max 0 (optTopN opts)
      !keptBundles = take cap ranked

      !stats = Stats
        { sTotalTx        = length txsAll
        , sQualifyingTx   = n
        , sCappedTx       = nCapped
        , sL1Count        = IS.size l1
        , sL2Count        = Map.size l2
        , sL3Count        = Map.size l3
        , sL4Count        = Map.size l4
        , sTopFreqExcluded = IS.size topFreqItems
        , sBundlesKept    = length keptBundles
        , sForcedSuppressed = forcedDropped
        , sFallbackMode   = fallback
        }

  case gOutFormat gOpts of
    OutJson -> emitJsonReport (gOutPath gOpts) $
      bundleJson ix opts stats keptBundles
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn (headerLine opts fallback)
      putStrLn (statsLine stats)
      if null keptBundles
        then putStrLn $
               "no bundles above thresholds at these parameters "
            ++ "(min-support ≥ " ++ show minSup
            ++ ", min-lift ≥ " ++ show (optMinLift opts)
            ++ ", min-span ≥ " ++ show (optMinSpan opts) ++ ")."
        else do
          putStr (renderBundlesTable ix (zip [1..] keptBundles))
          putStrLn ""

-- | Specificity = support * lift * log(span+1). The log bend keeps a
-- bundle that spans 30 modules from dominating one that spans 5 by
-- a factor of 6 — those should be close in priority.
specificity :: Bundle -> Double
specificity b =
  fromIntegral (bunSupport b)
    * bunLift b
    * log (fromIntegral (max 1 (bunSpan b)) + 1)

mkBundle :: [Int] -> Int -> BundleInfo -> Int -> (Int -> Int) -> Bundle
mkBundle items supC info n supOf =
  let k       = length items
      -- Expected count under independence:
      --   ∏ supOf(i) / N^{k-1}
      expectedF :: Double
      expectedF = case items of
        [] -> 1.0
        _  ->
          let prodSup = foldl' (\acc i -> acc * fromIntegral (supOf i)) (1.0 :: Double) items
              denom   = fromIntegral n ^^ (k - 1)
          in if denom == 0 then 1.0 else prodSup / denom
      !lift =
        if expectedF <= 0
          then 0
          else fromIntegral supC / expectedF
  in Bundle
       { bunItems   = items
       , bunSupport = supC
       , bunLift    = lift
       , bunSpan    = Set.size (biModules info)
       , bunOwners  = sort (biSample info)
       }

----------------------------------------------------------------------
-- Baskets.

-- | Build one basket per real definition, restricted to
-- 'ProvSignature'-tagged edges. Returns (baskets, fallback) where
-- 'fallback' is True iff the JSON had no provenance data at all, in
-- which case we use all out-edges (lossy but lets the analysis still
-- produce output).
buildBaskets :: Index -> ([Basket], Bool)
buildBaskets ix =
  let nReal = idxRealCount ix
      mProv = idxEdgeProvenance ix
      fallback = case mProv of
        Nothing -> True
        Just _  -> False

      sigItemsFor :: Int -> IntSet
      sigItemsFor src = case mProv of
        Nothing  ->
          -- No provenance data: use all out-edges.
          IM.findWithDefault IS.empty src (idxForward ix)
        Just prov ->
          let inner = IM.findWithDefault IM.empty src prov
              !sigs = IM.foldlWithKey'
                        (\acc tgt p -> if p == ProvSignature
                                         then IS.insert tgt acc
                                         else acc)
                        IS.empty
                        inner
          in sigs

      mkBk d =
        let oid     = defId d
            !items0 = sigItemsFor oid
            items   = IS.filter (isQualifyingItem ix) items0
            !sorted = IS.toAscList items
        in Basket
             { bkOwner   = oid
             , bkItems   = sorted
             , bkItemSet = items
             }
  in ( [ mkBk (defAt ix i) | i <- [0 .. nReal - 1] ]
     , fallback
     )

-- | An item is qualifying iff it's a real def (not a synthetic
-- edge-only node) and not itself the owner. Owner-self-loops would
-- inflate every L1 count without contributing signal.
isQualifyingItem :: Index -> Int -> Bool
isQualifyingItem ix i = i < idxRealCount ix

qualifying :: [Basket] -> [Basket]
qualifying = filter (\b -> length (bkItems b) >= 2)

-- | Apply 'optMaxBasketSize' to a list of qualifying baskets, returning
-- @(kept, droppedCount)@. A cap of @0@ disables the filter.
--
-- The cap is mandatory in practice: signatures on real corpora reach
-- into the low thousands of helper references, and the resulting
-- @C(b, k)@ tuple enumeration explodes the count maps past available
-- RAM on the uncapped path.
capLargeBaskets :: Int -> [Basket] -> ([Basket], Int)
capLargeBaskets capN bs
  | capN <= 0 = (bs, 0)
  | otherwise = foldr step ([], 0) bs
  where
    step b (!keep, !dropped)
      | length (bkItems b) > capN = (keep, dropped + 1)
      | otherwise                 = (b : keep, dropped)

----------------------------------------------------------------------
-- BundleInfo: per-itemset metadata collected in a second pass over the
-- baskets, *after* L2/L3/L4 have been pruned by support. Allocations
-- here are bounded by |frequent itemsets| × (sample cap + |modules|),
-- not by the total pair/triple/quad incidences across all baskets.

data BundleInfo = BundleInfo
  { biSample  :: ![Int]
    -- ^ Up to 'sampleCap' owner def-ids that contained this itemset
    -- (insertion order, head = most recently seen). Used for the
    -- per-bundle "examples" column in the report.
  , biSampleN :: !Int
    -- ^ @length biSample@ (≤ 'sampleCap'). Tracked explicitly so we
    -- don't traverse the list on every bump.
  , biModules :: !(Set T.Text)
    -- ^ Distinct modules of contributing owners; 'bunSpan' = 'Set.size'.
  } deriving (Show)

sampleCap :: Int
sampleCap = 10

emptyInfo :: BundleInfo
emptyInfo = BundleInfo [] 0 Set.empty

bumpInfo :: Int -> T.Text -> BundleInfo -> BundleInfo
bumpInfo !o !m !bi =
  let !s'  = if biSampleN bi >= sampleCap
               then biSample bi
               else o : biSample bi
      !sn' = if biSampleN bi >= sampleCap
               then biSampleN bi
               else biSampleN bi + 1
      !ms' = Set.insert m (biModules bi)
  in BundleInfo s' sn' ms'

-- | Walk the baskets once and collect 'BundleInfo' for every frequent
-- itemset in L2/L3/L4. Looks up each enumerated k-tuple in the
-- corresponding frequent map; only allocates a 'BundleInfo' for keys
-- that survived the support prune.
collectInfo
  :: Index
  -> Map (Int, Int) Int
  -> Map (Int, Int, Int) Int
  -> Map (Int, Int, Int, Int) Int
  -> [Basket]
  -> ( Map (Int, Int) BundleInfo
     , Map (Int, Int, Int) BundleInfo
     , Map (Int, Int, Int, Int) BundleInfo
     )
collectInfo ix l2 l3 l4 = foldl' step (Map.empty, Map.empty, Map.empty)
  where
    !haveL3 = not (Map.null l3)
    !haveL4 = not (Map.null l4)

    step (!a2, !a3, !a4) (Basket o items _) =
      let !modN = defModule (defAt ix o)
          !a2'  = walk2 modN o a2 items
          !a3'  = if haveL3 then walk3 modN o a3 items else a3
          !a4'  = if haveL4 then walk4 modN o a4 items else a4
      in (a2', a3', a4')

    -- L2: every ordered pair of basket items.
    walk2 !m !o !acc xs = case xs of
      []     -> acc
      x:rest ->
        let !acc' = foldl' (\a y -> bump2 m o (orderPair x y) a) acc rest
        in walk2 m o acc' rest

    -- L3: every ordered triple.
    walk3 !m !o !acc xs = case xs of
      []   -> acc
      x:r1 -> case r1 of
        [] -> acc
        _  -> let !acc' = goPair3 m o acc x r1
              in walk3 m o acc' r1
    goPair3 !m !o !acc x rest = case rest of
      []   -> acc
      y:r2 -> let !acc1 = foldl' (\a z -> bump3 m o (orderTriple x y z) a) acc r2
              in goPair3 m o acc1 x r2

    -- L4: every ordered quad.
    walk4 !m !o !acc xs = case xs of
      []   -> acc
      x:r1 -> case r1 of
        []  -> acc
        _:_ -> let !acc' = goTriple4 m o acc x r1
               in walk4 m o acc' r1
    goTriple4 !m !o !acc x rest = case rest of
      []   -> acc
      y:r2 -> case r2 of
        []  -> acc
        _:_ -> let !acc1 = goPair4 m o acc x y r2
               in goTriple4 m o acc1 x r2
    goPair4 !m !o !acc x y rest = case rest of
      []   -> acc
      z:r3 -> let !acc1 = foldl' (\a w -> bump4 m o (orderQuad x y z w) a) acc r3
              in goPair4 m o acc1 x y r3

    bump2 !m !o !k !acc
      | Map.member k l2 = Map.alter (alterBump o m) k acc
      | otherwise       = acc
    bump3 !m !o !k !acc
      | Map.member k l3 = Map.alter (alterBump o m) k acc
      | otherwise       = acc
    bump4 !m !o !k !acc
      | Map.member k l4 = Map.alter (alterBump o m) k acc
      | otherwise       = acc

    alterBump !o !m Nothing   = Just $! bumpInfo o m emptyInfo
    alterBump !o !m (Just bi) = Just $! bumpInfo o m bi

----------------------------------------------------------------------
-- Apriori counting. Mirrors 'AgdaOptimization.Basket': 'Map _ Int',
-- not 'Map _ [Int]' — owners are collected post-prune in 'collectInfo'.

-- | Canonical ascending @(w, x, y, z)@ via the optimal 5-comparator
-- sorting network for 4 inputs — no list, no 'sort' allocation, run once
-- per candidate quad in the Apriori counting loop.
orderQuad :: Int -> Int -> Int -> Int -> (Int, Int, Int, Int)
orderQuad a b c d =
  let (a1, b1) = orderPair a  b
      (c1, d1) = orderPair c  d
      (a2, c2) = orderPair a1 c1
      (b2, d2) = orderPair b1 d1
      (b3, c3) = orderPair b2 c2
  in (a2, b3, c3, d2)

-- | Baskets per parallel chunk for the counting passes. Sum is
-- associative + commutative, so 'Map.unionsWith (+)' over the per-chunk
-- partials is byte-identical regardless of chunk/spark order.
bundleChunk :: Int
bundleChunk = 64

-- | Chunked parallel count: fold each basket chunk into a per-chunk count
-- map and sum the partials. Shared by the L2/L3/L4 counters, which differ
-- only in their per-basket accumulator.
countChunked :: (NFData k, NFData v, Num v, Ord k)
             => (Map k v -> Basket -> Map k v) -> [Basket] -> Map k v
countChunked addBk txs =
  Map.unionsWith (+)
    (parMap rdeepseq (foldl' addBk Map.empty) (chunksOf bundleChunk txs))

-- | Count occurrences of every 2-subset across baskets.
countPairs :: [Basket] -> IntSet -> Map (Int, Int) Int
countPairs txs l1 = countChunked addBk txs
  where
    addBk !acc (Basket _ is _) =
      let !filtered = filter (`IS.member` l1) is
      in pairsAcc acc filtered
    pairsAcc !acc xs = case xs of
      []     -> acc
      x:rest -> let !acc' = foldl' (\m y -> Map.insertWith (+) (orderPair x y) 1 m) acc rest
                in pairsAcc acc' rest

countTriples :: [Basket] -> IntSet -> Map (Int, Int) Int
             -> Map (Int, Int, Int) Int
countTriples txs l1 l2sup = countChunked addBk txs
  where
    addBk !acc (Basket _ is _) =
      let !filtered = filter (`IS.member` l1) is
      in triplesAcc acc filtered
    triplesAcc !acc xs = case xs of
      []     -> acc
      x:r1   -> case r1 of
        [] -> acc
        _  -> let !acc' = goPair acc x r1
              in triplesAcc acc' r1
    goPair !acc x rest = case rest of
      []   -> acc
      y:r2 -> let !acc1 = goSingle acc x y r2
              in goPair acc1 x r2
    goSingle !acc x y zs =
      foldl' (step x y) acc zs
    step x y !m z =
      let p1 = orderPair x y
          p2 = orderPair x z
          p3 = orderPair y z
      in if Map.member p1 l2sup && Map.member p2 l2sup && Map.member p3 l2sup
           then Map.insertWith (+) (orderTriple x y z) 1 m
           else m

countQuads :: [Basket] -> IntSet -> Map (Int, Int, Int) Int
           -> Map (Int, Int, Int, Int) Int
countQuads txs l1 l3sup = countChunked addBk txs
  where
    addBk !acc (Basket _ is _) =
      let !filtered = filter (`IS.member` l1) is
      in quadsAcc acc filtered
    quadsAcc !acc xs = case xs of
      []     -> acc
      x:r1   -> case r1 of
        []     -> acc
        _:_    -> let !acc' = goTriple acc x r1
                  in quadsAcc acc' r1
    goTriple !acc x rest = case rest of
      []     -> acc
      y:r2   -> case r2 of
        []   -> acc
        _:_  -> let !acc1 = goPair acc x y r2
                in goTriple acc1 x r2
    goPair !acc x y rest = case rest of
      []   -> acc
      z:r3 -> let !acc1 = goSingle acc x y z r3
              in goPair acc1 x y r3
    goSingle !acc x y z ws =
      foldl' (step x y z) acc ws
    step x y z !m w =
      -- All four 3-subsets must be frequent.
      let t1 = orderTriple x y z
          t2 = orderTriple x y w
          t3 = orderTriple x z w
          t4 = orderTriple y z w
      in if Map.member t1 l3sup
            && Map.member t2 l3sup
            && Map.member t3 l3sup
            && Map.member t4 l3sup
           then Map.insertWith (+) (orderQuad x y z w) 1 m
           else m

----------------------------------------------------------------------
-- Forced-by-elaborator suppression.

-- | Split a bundle list into @(kept, droppedCount)@ using
-- 'isForcedByFamily' over each bundle's item set. Strict count;
-- preserves order of the kept list.
partitionForced :: Index -> Double -> [Bundle] -> ([Bundle], Int)
partitionForced ix fraction = foldr step ([], 0)
  where
    step b (!keep, !dropped)
      | isForcedByFamily ix fraction (bunItems b) =
          (keep, dropped + 1)
      | otherwise =
          (b : keep, dropped)

----------------------------------------------------------------------
-- Rendering.

headerLine :: Options -> Bool -> String
headerLine Options{..} fb =
     "# ConceptBundle — signature-provenance itemsets (sup≥"
  ++ show optMinSupport
  ++ ", lift≥" ++ showD optMinLift
  ++ ", span≥" ++ show optMinSpan
  ++ ", k-max=" ++ show optKMax
  ++ ", excl-top-freq=" ++ showD optExcludeTopFreq ++ "%"
  ++ ", top-n=" ++ show optTopN
  ++ (if optForcedSuppress
        then ", forced-suppress@" ++ showD optForcedFraction
        else ", forced-suppress=off")
  ++ (if optMaxBasketSize > 0
        then ", max-basket-size=" ++ show optMaxBasketSize
        else ", max-basket-size=off")
  ++ ")"
  ++ (if fb
        then "\n# WARNING: definitionEdgesProvenance absent in JSON; \
             \falling back to all-edges (results match Basket's feature space)."
        else "")

statsLine :: Stats -> String
statsLine Stats{..} =
     "# tx=" ++ show sTotalTx
  ++ " qualifying=" ++ show sQualifyingTx
  ++ (if sCappedTx > 0
        then " capped=" ++ show sCappedTx
        else "")
  ++ " L1=" ++ show sL1Count
  ++ " L2=" ++ show sL2Count
  ++ " L3=" ++ show sL3Count
  ++ " L4=" ++ show sL4Count
  ++ " top-freq-excluded=" ++ show sTopFreqExcluded
  ++ (if sForcedSuppressed > 0
        then " forced-suppressed=" ++ show sForcedSuppressed
        else "")
  ++ " kept=" ++ show sBundlesKept

renderBundlesTable :: Index -> [(Int, Bundle)] -> String
renderBundlesTable ix ranked =
  let header = [ "Rank", "Items", "Sup", "Lift", "Span", "Spec" ]
      rows   = map (renderBundleRow ix) ranked
  in renderTable header rows

renderBundleRow :: Index -> (Int, Bundle) -> [String]
renderBundleRow ix (rank, b) =
  [ show rank
  , T.unpack (T.intercalate "," (map (shortName ix) (bunItems b)))
  , show (bunSupport b)
  , showD3 (bunLift b)
  , show (bunSpan b)
  , showD3 (specificity b)
  ]


----------------------------------------------------------------------
-- JSON output.

bundleJson
  :: Index
  -> Options
  -> Stats
  -> [Bundle]
  -> A.Value
bundleJson ix opts stats keptBundles =
  A.object
    [ "subcommand" .= ("concept-bundle" :: T.Text)
    , "options"    .= optionsJson opts
    , "stats"      .= A.object
        [ "tx"               .= sTotalTx stats
        , "qualifying"       .= sQualifyingTx stats
        , "capped"           .= sCappedTx stats
        , "l1"               .= sL1Count stats
        , "l2"               .= sL2Count stats
        , "l3"               .= sL3Count stats
        , "l4"               .= sL4Count stats
        , "top_freq_excluded" .= sTopFreqExcluded stats
        , "bundles_kept"     .= sBundlesKept stats
        , "forced_suppressed" .= sForcedSuppressed stats
        , "fallback_no_provenance" .= sFallbackMode stats
        ]
    , "bundles"    .= A.toJSON (zipWith (bundleRowJson ix) [1 :: Int ..] keptBundles)
    ]

optionsJson :: Options -> A.Value
optionsJson Options{..} = A.object
  [ "min_support"        .= optMinSupport
  , "min_lift"           .= optMinLift
  , "min_span"           .= optMinSpan
  , "top_n"              .= optTopN
  , "k_max"              .= optKMax
  , "exclude_top_freq"   .= optExcludeTopFreq
  , "forced_suppress"    .= optForcedSuppress
  , "forced_fraction"    .= optForcedFraction
  , "max_basket_size"    .= optMaxBasketSize
  ]

bundleRowJson :: Index -> Int -> Bundle -> A.Value
bundleRowJson ix rank b = A.object
  [ "rank"        .= rank
  , "items"       .= map (shortName ix) (bunItems b)
  , "items_full"  .= map (\i -> defName (defAt ix i)) (bunItems b)
  , "support"     .= bunSupport b
  , "lift"        .= bunLift b
  , "span"        .= bunSpan b
  , "specificity" .= specificity b
  , "owners"      .= map (\i -> defName (defAt ix i)) (bunOwners b)
  ]

