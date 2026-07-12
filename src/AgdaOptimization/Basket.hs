{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | BasketProver — frequent-itemset / association-rule mining over a
-- definition's /direct/ out-edges.
--
-- Each top-level real definition is treated as a transaction; its
-- basket is exactly @IM.findWithDefault IS.empty d idxForward@ (no
-- transitive closure: universal primitives would otherwise drown the
-- signal). Items from the basket whose kind is @KConstructor@ or
-- @KPostulate@ are dropped graph-wide (too noisy).
--
-- Pipeline:
--
--   1. Build qualifying baskets (size ≥ 2).
--   2. Apriori: L1 (singletons) → L2 (pairs) → L3 (triples), with the
--      anti-monotone subset prune. Capped at k = 3 (higher k explodes
--      and rarely helps on proof graphs).
--   3. For every frequent itemset of size ≥ 2, enumerate rules
--      @X ⇒ {y}@ and keep those passing the confidence / lift gates.
--   4. Multiple-testing control: chi-squared upper bound on the
--      Fisher's-exact p-value (analytic bound: degenerate 2×2 has
--      χ² = N · (ad − bc)² / ((a+b)(c+d)(a+c)(b+d))). Apply Bonferroni
--      over the number of /candidate rules considered/ (NOT just those
--      that crossed conf/lift). A rule is rejected if
--      @p_raw × #candidates > 0.01@.
--   5. Near-miss flagger: for the top-5 most-confident kept rules of
--      LHS size ≥ 2, list 2–3 baskets that contain (k−1) of the k items.
--
-- All hot work runs over strict 'IntMap' / 'IntSet' / @foldl'@. The
-- only IO is 'run'.
module AgdaOptimization.Basket
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq         ( rnf )
import           Control.Exception       ( evaluate )
import           Control.Monad           ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           Data.IORef              ( IORef, newIORef, readIORef )
import qualified Data.IntMap.Strict      as IM
import           Data.IntMap.Strict      ( IntMap )
import qualified Data.IntSet             as IS
import           Data.IntSet             ( IntSet )
import           Data.List               ( sortOn, sort, nub )
import qualified Data.Map.Strict         as Map
import           Data.Map.Strict         ( Map )
import           Data.Ord                ( Down(..) )
import qualified Data.Text               as T
import           System.IO               ( hPutStrLn, stderr )

import qualified Data.Aeson              as A
import           Data.Aeson              ( (.=) )

import           AgdaGraph.Index         ( Index(..), defAt )
import           AgdaGraph.Schema        ( Definition(..), Kind(..) )
import           AgdaOptimization.Common ( chunksOf, computeTopFreqItems
                                         , orderPair, orderTriple
                                         , shortName, showD, withReaper )
import           AgdaOptimization.FamilyFilter ( isForcedByFamily )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , showD3, withHumanOutput )

----------------------------------------------------------------------
-- Options.

data Options = Options
  { optMinSupport     :: !Double
    -- ^ Minimum fraction of qualifying baskets an itemset must appear in.
  , optMinConfidence  :: !Double
    -- ^ Rule @X ⇒ y@: @support(X∪{y}) / support(X) ≥ this@.
  , optMinLift        :: !Double
    -- ^ Lift threshold: @confidence / support({y}) ≥ this@.
  , optExcludeTopFreq :: !Double
    -- ^ Drop rules whose LHS or RHS is in the top @P%@ most-frequent
    -- items (by raw support count). Range [0, 100]; @0@ disables the
    -- filter (regression escape hatch). Default @5.0@.
  , optTopN           :: !Int
    -- ^ Cap on the number of rules retained after sorting. Stats
    -- distinguish @considered@ / @passed@ / @kept@ accordingly.
  , optBudgetSecs     :: !Double
    -- ^ Wall-clock budget for the Apriori + rule-enumeration pipeline,
    -- in seconds. 0 (the default) disables the budget; the pipeline
    -- runs to completion. When > 0 a reaper thread flips a deadline
    -- 'IORef' once the budget is up; the run loop checks it between
    -- coarse steps (after L2 pair counting, after L3 triple counting,
    -- after rule enumeration) and falls through to a partial-output
    -- branch carrying whatever was already computed.
  , optForcedSuppress :: !Bool
    -- ^ Forced-by-elaborator suppressor. When 'True' (default), drop
    -- rules whose bundle (LHS ∪ {RHS}) is dominated by a
    -- per-case-unfold family: items whose unqualified name matches
    -- @^(.+)-(\\d+)$@ with the same stem (e.g. @VoteBlock-0@,
    -- @VoteBlock-1@, @VoteBlock-2@) and at least two members. These
    -- families are Agda's per-constructor unfolding of state-update
    -- functions, not refactor-actionable duplication. Disable with
    -- @--no-forced-suppress@.
  , optForcedFraction :: !Double
    -- ^ Fraction-of-bundle gate for 'optForcedSuppress'. A rule is
    -- suppressed when ≥ this fraction of its bundle items belongs to
    -- one per-case-unfold family. Default 0.5: any bundle where the
    -- majority is a single family is suppressed. 1.0 requires the whole
    -- bundle to be one family; 0.0 plus 'optForcedSuppress' would
    -- suppress anything touching a family at all.
  , optMaxBasketSize  :: !Int
    -- ^ Drop transactions whose qualifying-item count exceeds this cap
    -- /before/ the L2/L3 pair/triple enumeration. A basket of @b@ items
    -- contributes @C(b,2)@ pairs and @C(b,3)@ triples, so a single
    -- high-fan-out definition (a big aggregator module, a wide record)
    -- can make the count maps blow up super-linearly and the run hang.
    -- Mirrors 'AgdaOptimization.ConceptBundle'. @0@ disables the cap;
    -- default @64@.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optMinSupport     = 0.05
  , optMinConfidence  = 0.6
  , optMinLift        = 1.5
  , optExcludeTopFreq = 5.0
  , optTopN           = 100
  , optBudgetSecs     = 0.0
  , optForcedSuppress = True
  , optForcedFraction = 0.5
  , optMaxBasketSize  = 64
  }

-- | Declarative flag spec for the @basket@ subcommand. Drives both the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--forced-suppress@ / @--no-forced-suppress@ are 'SwitchIgnoreValue'
-- switches (an attached @=value@ is ignored). They share a single YAML
-- key (@forced-suppress@), carried by the @--forced-suppress@ entry; the
-- @--no-forced-suppress@ entry takes no part in the overlay ('Nothing').
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ DblFlag "min-support" "--min-support=F             min support (default 0.05)"
      (\x o -> o { optMinSupport = x })
  , DblFlag "min-confidence" "--min-confidence=F          min confidence (default 0.5)"
      (\x o -> o { optMinConfidence = x })
  , DblFlag "min-lift" "--min-lift=F                min lift (default 1.5)"
      (\x o -> o { optMinLift = x })
  , DblFlag "exclude-top-frequency" "--exclude-top-frequency=F   drop rules with top-pct% items; 0 = disabled (default 5.0)"
      (\x o -> o { optExcludeTopFreq = x })
  , IntFlag "top-n" "--top-n=N                   rules to keep after sort (default 100)"
      (\x o -> o { optTopN = x })
  , DblFlag "budget" "--budget=F                  wall-clock seconds; 0 = unlimited (default)"
      (\x o -> o { optBudgetSecs = x })
  , SwitchFlag "no-forced-suppress" "--no-forced-suppress        disable the per-case-unfold-family suppressor"
      SwitchIgnoreValue (\o -> o { optForcedSuppress = False })
      Nothing (\_ o -> o)
  , SwitchFlag "forced-suppress" "--forced-suppress           re-enable the suppressor (default on)"
      SwitchIgnoreValue (\o -> o { optForcedSuppress = True })
      (Just "forced-suppress") (\v o -> o { optForcedSuppress = v })
  , DblFlag "forced-fraction" "--forced-fraction=F         bundle-fraction gate for the suppressor (default 0.5)"
      (\x o -> o { optForcedFraction = x })
  , IntFlag "max-basket-size" "--max-basket-size=N         drop baskets exceeding N items before counting; 0 = disabled (default 64)"
      (\x o -> o { optMaxBasketSize = x })
  ]

-- | Hand-rolled CLI parser for the @basket@ subcommand. Each value is
-- a 'Double'. See 'AgdaOptimization.Motif.parseOptions' for the
-- shape; strict fold over the argv.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "basket" flagSpecs

-- | Overlay the @basket:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "basket" flagSpecs obj o0

----------------------------------------------------------------------
-- Internal types.

-- | A transaction is the source definition id (for diagnostics +
-- near-miss reporting) paired with its filtered basket as a sorted
-- list of item ids. We carry both the list (cheap to walk pair-wise)
-- and an 'IntSet' (for membership tests).
data Tx = Tx
  { txOwner   :: !Int
  , txItems   :: ![Int]
  , txItemSet :: !IntSet
  } deriving (Show)

-- | One emitted rule, post-thresholds and post-Bonferroni acceptance.
data Rule = Rule
  { rLhs        :: ![Int]
  , rRhs        :: !Int
  , rSupport    :: !Double
  , rConfidence :: !Double
  , rLift       :: !Double
  , rPRaw       :: !Double
  , rPCorrected :: !Double
  } deriving (Show)

-- | Mining statistics for the human-readable preamble.
data Stats = Stats
  { sTotalTx        :: !Int
  , sQualifyingTx   :: !Int
  , sL1Count        :: !Int
  , sL2Count        :: !Int
  , sL3Count        :: !Int
  , sTopFreqExcluded:: !Int       -- items excluded by --exclude-top-frequency
  , sRulesConsidered:: !Int       -- candidate rules generated
  , sRulesPassed    :: !Int       -- passed conf+lift+Bonferroni (pre-cap)
  , sRulesKept      :: !Int       -- post-cap, actually emitted
  , sForcedSuppressed :: !Int     -- ^ Rules dropped by the
                                  -- per-case-unfold-family detector.
                                  -- Reported separately so a non-zero
                                  -- count tells the user the suppressor
                                  -- earned its keep.
  , sBudgetExhausted:: !Bool      -- did the wall-clock budget trip?
  , sReachedLevel   :: !Int       -- largest Apriori level L_k that completed
                                  -- (1 = L1 only, 2 = L2 done, 3 = L3 done +
                                  -- rules enumerated)
  } deriving (Show)

----------------------------------------------------------------------
-- Entry point.

-- | Top-level: print the BasketProver report to stdout. Never throws.
--
-- Pipeline runs in IO so the heavy Apriori levels can be /forced/
-- between coarse-grained deadline checks. The wall-clock budget
-- (@--budget=<secs>@) is enforced by a reaper thread that flips a
-- shared 'IORef'; when 0 (default) no reaper is spawned and the
-- pipeline runs to completion unbounded.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let !txsAll = buildTransactions ix
      -- Cap oversized baskets BEFORE the C(b,k) enumeration so one
      -- high-fan-out definition can't make the pair/triple count maps
      -- blow up super-linearly (the cause of the prior hang on large
      -- corpora). Disabled with --max-basket-size=0.
      (!txs, !nCapped) = capLargeBaskets (optMaxBasketSize opts) (qualifying txsAll)
      !n      = length txs

      -- Item -> count of transactions containing it.
      itemCounts :: IntMap Int
      !itemCounts = foldl' countTx IM.empty txs
        where
          countTx !acc (Tx _ _ s) =
            IS.foldl' (\m i -> IM.insertWith (+) i 1 m) acc s

      !minSupCount = ceiling (optMinSupport opts * fromIntegral n) :: Int

      -- L1: singletons above support.
      !l1 = IS.fromList
              [ i | (i, c) <- IM.toList itemCounts, c >= minSupCount ]

      -- Top-frequency exclusion (cheap; computed once).
      !topFrequencyItems =
        computeTopFreqItems (optExcludeTopFreq opts) itemCounts

      supOf1 :: Int -> Int
      supOf1 i = IM.findWithDefault 0 i itemCounts

      pCorrThreshold :: Double
      pCorrThreshold = 0.01

  when (nCapped > 0) $
    hPutStrLn stderr $
      "agda-optimization basket: dropped " ++ show nCapped
        ++ " oversized basket(s) (> " ++ show (optMaxBasketSize opts)
        ++ " items) before counting; raise --max-basket-size (or 0 to "
        ++ "disable) to include them."

  -- Deadline plumbing. When the budget is 0 we still allocate the
  -- IORef but no reaper is spawned, so 'readIORef' is always False.
  deadlineRef <- newIORef False

  withReaper (optBudgetSecs opts) deadlineRef $ do

    -- Stage 1 — L2. Heavy step; budgeted variant checks the deadline
    -- 'IORef' between batches so a non-terminating L_k still emits
    -- whatever it accumulated.
    trippedBeforeL2 <- readIORef deadlineRef
    (!l2, !trippedAfterL2) <-
      if trippedBeforeL2
        then pure (Map.empty, True)
        else do
          (!raw, !midTrip) <- countPairsBudgeted (optBudgetSecs opts) deadlineRef txs l1
          let !filtered = Map.filter (>= minSupCount) raw
          _ <- evaluate (rnf filtered)
          tailTrip <- readIORef deadlineRef
          pure (filtered, midTrip || tailTrip)

    -- Stage 2 — L3. Skipped (replaced by empty) if the deadline tripped
    -- at any point through L2.
    (!l3, !trippedAfterL3) <-
      if trippedAfterL2
        then pure (Map.empty, True)
        else do
          (!raw, !midTrip) <- countTriplesBudgeted (optBudgetSecs opts) deadlineRef txs l1 l2
          let !filtered = Map.filter (>= minSupCount) raw
          _ <- evaluate (rnf filtered)
          tailTrip <- readIORef deadlineRef
          pure (filtered, midTrip || tailTrip)

    -- Stage 3 — enumerateRules. Always run (with empty L2/L3 the rule
    -- set is just empty), so we always produce a valid stats table.
    let supOf2 :: Int -> Int -> Int
        supOf2 a b = Map.findWithDefault 0 (orderPair a b) l2

        (!passedRules, !considered) =
          enumerateRules opts topFrequencyItems n l2 l3 supOf1 supOf2
    _ <- evaluate (rnf considered)
    trippedAfterRules <- readIORef deadlineRef

    let !tripped = trippedBeforeL2
                || trippedAfterL2
                || trippedAfterL3
                || trippedAfterRules
        -- "Reached level" is the largest L_k that fully completed:
        --   1  budget tripped before/during L2
        --   2  L2 done, L3 skipped or tripped during L3
        --   3  full pipeline ran (rule enumeration finished, even if the
        --      deadline fired mid-render — at that point the heavy work
        --      is already in hand)
        !reached
          | trippedAfterL2 = 1
          | trippedAfterL3 = 2
          | otherwise      = 3

        -- Bonferroni: reject rules whose p_raw * considered > 0.01.
        bonferroniKept =
          [ r { rPCorrected = corr }
          | r <- passedRules
          , let corr = rPRaw r * fromIntegral (max 1 considered)
          , corr <= pCorrThreshold
          ]

        -- Forced-by-elaborator suppressor. Drop rules whose bundle is
        -- dominated by a per-case-unfold family (@X-0, X-1, X-2, …@).
        -- 'forcedKept' is the post-suppression list; 'forcedDropped' is
        -- the count for the Stats line.
        (!forcedKept, !forcedDropped) =
          if optForcedSuppress opts
            then partitionForced ix
                                 (optForcedFraction opts)
                                 bonferroniKept
            else (bonferroniKept, 0)

        -- Specificity primary, confidence secondary (one stable pass,
        -- equivalent to the former sortOn-after-sortOn).
        ranked = sortOn (\r -> (Down (specificity r), Down (rConfidence r)))
                        forcedKept

        !cap       = max 0 (optTopN opts)
        !keptRules = take cap ranked

        !stats = Stats
          { sTotalTx         = length txsAll
          , sQualifyingTx    = n
          , sL1Count         = IS.size l1
          , sL2Count         = Map.size l2
          , sL3Count         = Map.size l3
          , sTopFreqExcluded = IS.size topFrequencyItems
          , sRulesConsidered = considered
          , sRulesPassed     = length bonferroniKept
          , sRulesKept       = length keptRules
          , sForcedSuppressed = forcedDropped
          , sBudgetExhausted = tripped
          , sReachedLevel    = reached
          }

    when tripped $
      hPutStrLn stderr $
        "[basket] budget exhausted after "
        ++ show (optBudgetSecs opts)
        ++ "s at L_" ++ show reached
        ++ "; emitting partial results."

    case gOutFormat gOpts of
      OutJson ->
        emitJsonReport (gOutPath gOpts) $
          basketJson ix opts stats pCorrThreshold txs keptRules
      OutHuman -> withHumanOutput (gOutPath gOpts) $ do
        -- Render. Near-misses first (highest-signal-per-byte output), then
        -- the capped rules table.
        putStrLn (headerLine opts)
        putStrLn (statsLine stats pCorrThreshold)
        if null keptRules
          then putStrLn $
                 "no rules above thresholds at these parameters "
              ++ "(support ≥ " ++ show (optMinSupport opts)
              ++ ", confidence ≥ " ++ show (optMinConfidence opts)
              ++ ", lift ≥ " ++ show (optMinLift opts) ++ ")."
          else do
            renderNearMisses ix txs keptRules
            putStr (renderRulesTable ix (zip [1..] keptRules))
            putStrLn ""

-- | Specificity = support * lift. High specificity = the rule isn't
-- just riding on a common RHS. Used as the tertiary sort key.
specificity :: Rule -> Double
specificity r = rSupport r * rLift r

-- | Header banner.
headerLine :: Options -> String
headerLine Options{..} =
     "# BasketProver — co-usage rules (sup≥"
  ++ showD optMinSupport
  ++ ", conf≥" ++ showD optMinConfidence
  ++ ", lift≥" ++ showD optMinLift
  ++ ", excl-top-freq=" ++ showD optExcludeTopFreq ++ "%"
  ++ ", top-n=" ++ show optTopN
  ++ (if optBudgetSecs > 0 then ", budget=" ++ showD optBudgetSecs ++ "s" else "")
  ++ (if optForcedSuppress
        then ", forced-suppress@" ++ showD optForcedFraction
        else ", forced-suppress=off")
  ++ (if optMaxBasketSize > 0
        then ", max-basket-size=" ++ show optMaxBasketSize
        else ", max-basket-size=off")
  ++ ")"

statsLine :: Stats -> Double -> String
statsLine Stats{..} pThr =
     "# tx=" ++ show sTotalTx
  ++ " qualifying=" ++ show sQualifyingTx
  ++ " L1=" ++ show sL1Count
  ++ " L2=" ++ show sL2Count
  ++ " L3=" ++ show sL3Count
  ++ " top-freq-excluded=" ++ show sTopFreqExcluded
  ++ " rules-considered=" ++ show sRulesConsidered
  ++ " passed=" ++ show sRulesPassed
  ++ (if sForcedSuppressed > 0
        then " forced-suppressed=" ++ show sForcedSuppressed
        else "")
  ++ " kept=" ++ show sRulesKept
  ++ " p_corr≤" ++ showD pThr

----------------------------------------------------------------------
-- Transactions.

-- | Build one transaction per /real/ definition (synthetic edge-only
-- nodes don't carry useful basket semantics). Items are filtered by
-- 'isQualifyingItem'.
buildTransactions :: Index -> [Tx]
buildTransactions ix =
  let nReal = idxRealCount ix
      mkTx d =
        let oid   = defId d
            outs  = IM.findWithDefault IS.empty oid (idxForward ix)
            items = IS.filter (isQualifyingItem ix) outs
            sorted = IS.toAscList items
        in Tx { txOwner = oid, txItems = sorted, txItemSet = items }
  in [ mkTx (defAt ix i) | i <- [0 .. nReal - 1] ]

-- | An item is qualifying iff its kind is /not/ @KConstructor@ or
-- @KPostulate@. Synthetic nodes (kind defaults to 'KOther') pass.
isQualifyingItem :: Index -> Int -> Bool
isQualifyingItem ix i = case defKind (defAt ix i) of
  KConstructor -> False
  KPostulate   -> False
  _            -> True

-- | A transaction is "qualifying" iff its filtered basket has ≥ 2
-- items.
qualifying :: [Tx] -> [Tx]
qualifying = filter (\t -> length (txItems t) >= 2)

-- | Drop transactions whose basket exceeds the cap, returning
-- @(kept, droppedCount)@. A cap of @0@ disables the filter. Applied
-- after 'qualifying' and before the @C(b,k)@ pair/triple enumeration,
-- this bounds the count-map blow-up a single high-fan-out definition
-- would otherwise cause (the @basket@ analogue of
-- 'AgdaOptimization.ConceptBundle.capLargeBaskets').
capLargeBaskets :: Int -> [Tx] -> ([Tx], Int)
capLargeBaskets capN txs
  | capN <= 0 = (txs, 0)
  | otherwise = foldr step ([], 0) txs
  where
    step t (!keep, !dropped)
      | length (txItems t) > capN = (keep, dropped + 1)
      | otherwise                 = (t : keep, dropped)

----------------------------------------------------------------------
-- Apriori levels.

-- | Chunk size for the per-tx parallel fold.
--
-- With no budget, targets ~8 chunks, clamped to at least 64 to avoid
-- spark overhead swamping the work on small corpora.
--
-- Under a wall-clock budget we want many more, smaller chunks so a
-- single chunk's worth of L3 work can't blow the budget: target ~256
-- chunks, min chunk size 16.
chunkSizeFor :: Double -> [a] -> Int
chunkSizeFor budget xs =
  let !n = length xs
  in if budget <= 0
       then max 64 ((n + 7)   `div` 8)
       else max 16 ((n + 255) `div` 256)   -- ~256 chunks

-- | How many batches to split the chunk list into for budget-check
-- purposes. With no budget, caps at 16; under budget caps at 32 so the
-- deadline 'IORef' is read every ~3% of total L_k work. Each batch
-- still contains multiple chunks (parMap fans them out), so parallelism
-- is preserved.
chooseNBatches :: Double -> Int -> Int
chooseNBatches budget nChunks
  | budget <= 0 = max 1 (min 16 nChunks)
  | otherwise   = max 1 (min 32 nChunks)

-- | Count occurrences of every 2-subset (a, b) where a < b. Both
-- items must be in @l1@; this is the anti-monotone prune at k=2 (an
-- infrequent singleton can't appear in a frequent pair).
--
-- Parallel-reduce within a batch (chunks fanned out via 'parMap'); IO
-- between batches to check the deadline 'IORef' and bail with
-- whatever's accumulated, so a non-terminating L_k still emits its
-- partial result. Sum is associative + commutative, so the final map
-- is byte-identical regardless of batch order / spark order. Returns
-- @(partial, trippedMidway)@.
--
-- Chunk / batch granularity is budget-aware: under a non-zero
-- @--budget@ chunks are smaller and there are more batches, so a single
-- batch can't push end-to-end time past the budget by more than one
-- batch's worth of work.
countPairsBudgeted
  :: Double
  -> IORef Bool
  -> [Tx]
  -> IntSet
  -> IO (Map (Int, Int) Int, Bool)
countPairsBudgeted budget deadlineRef txs l1 = do
  let !chunks    = chunksOf (chunkSizeFor budget txs) txs
      !nChunks   = length chunks
      !nBatches  = chooseNBatches budget nChunks
      !batchSize = max 1 ((nChunks + nBatches - 1) `div` nBatches)
      !batches   = chunksOf batchSize chunks
      !total     = length batches
  go total 0 [] Map.empty batches
  where
    go !_total !_done !accs !_running []         =
      pure (Map.unionsWith (+) accs, False)
    go !total !done !accs !running (b : rest)   = do
      tripped <- readIORef deadlineRef
      if tripped
        then pure (Map.unionsWith (+) accs, True)
        else do
          let !partial = parMap rdeepseq (foldl' bump Map.empty) b
          _ <- evaluate (rnf partial)
          let !merged   = Map.unionsWith (+) partial
              !done'    = done + 1
              !accs'    = merged : accs
              !running' = Map.unionWith (+) running merged
          hPutStrLn stderr $
            "[basket] L2: " ++ show done' ++ "/" ++ show total
              ++ " batches, |L2| ~ " ++ show (Map.size running') ++ " so far"
          go total done' accs' running' rest

    bump !acc (Tx _ items _) =
      let filtered = filter (`IS.member` l1) items
      in pairsAcc acc filtered
    pairsAcc !acc xs = case xs of
      []       -> acc
      (x:rest) ->
        let !acc' = foldl' (\m y -> Map.insertWith (+) (orderPair x y) 1 m)
                           acc rest
        in pairsAcc acc' rest

-- | Count occurrences of every 3-subset whose three 2-subsets are all
-- in @l2@ — the standard Apriori anti-monotone gate.
--
-- Same batch-with-mid-loop-deadline-check pattern as
-- 'countPairsBudgeted'. The @l2@ map is finalised in 'run' before
-- this is called, so it's safe to share across sparks. Returns
-- @(partial, trippedMidway)@. This is the hot path: the cubic per-tx
-- work on big baskets makes finer budget-aware chunking matter here.
countTriplesBudgeted
  :: Double
  -> IORef Bool
  -> [Tx]
  -> IntSet
  -> Map (Int, Int) Int
  -> IO (Map (Int, Int, Int) Int, Bool)
countTriplesBudgeted budget deadlineRef txs l1 l2 = do
  let !chunks    = chunksOf (chunkSizeFor budget txs) txs
      !nChunks   = length chunks
      !nBatches  = chooseNBatches budget nChunks
      !batchSize = max 1 ((nChunks + nBatches - 1) `div` nBatches)
      !batches   = chunksOf batchSize chunks
      !total     = length batches
  go total 0 [] Map.empty batches
  where
    go !_total !_done !accs !_running []         =
      pure (Map.unionsWith (+) accs, False)
    go !total !done !accs !running (b : rest)   = do
      tripped <- readIORef deadlineRef
      if tripped
        then pure (Map.unionsWith (+) accs, True)
        else do
          let !partial = parMap rdeepseq (foldl' bump Map.empty) b
          _ <- evaluate (rnf partial)
          let !merged   = Map.unionsWith (+) partial
              !done'    = done + 1
              !accs'    = merged : accs
              !running' = Map.unionWith (+) running merged
          hPutStrLn stderr $
            "[basket] L3: " ++ show done' ++ "/" ++ show total
              ++ " batches, |L3| ~ " ++ show (Map.size running') ++ " so far"
          go total done' accs' running' rest

    bump !acc (Tx _ items _) =
      let filtered = filter (`IS.member` l1) items
      in triplesAcc acc filtered
    triplesAcc !acc xs = case xs of
      []         -> acc
      (x:r1)     -> case r1 of
        []     -> acc
        _      ->
          let !acc' = goPair acc x r1
          in triplesAcc acc' r1
    goPair !acc x rest = case rest of
      []      -> acc
      (y:r2)  ->
        let !acc1 = goSingle acc x y r2
        in goPair acc1 x r2
    goSingle !acc x y zs =
      foldl' (step x y) acc zs
    step x y !m z =
      -- All three 2-subsets must be frequent.
      let p1 = orderPair x y
          p2 = orderPair x z
          p3 = orderPair y z
      in if Map.member p1 l2 && Map.member p2 l2 && Map.member p3 l2
           then Map.insertWith (+) (orderTriple x y z) 1 m
           else m

----------------------------------------------------------------------
-- Rule enumeration.

-- | Enumerate every candidate rule @X ⇒ {y}@ from frequent 2- and
-- 3-itemsets. For each, compute confidence, lift, and a chi-squared
-- p-value upper bound on Fisher's exact. Return rules that pass
-- conf+lift+p_raw (before Bonferroni), plus the /total/ number of
-- candidates considered (the Bonferroni denominator).
enumerateRules
  :: Options
  -> IntSet                           -- ^ items to exclude (top frequency)
  -> Int                              -- ^ N (qualifying txs)
  -> Map (Int, Int) Int               -- ^ L2 counts
  -> Map (Int, Int, Int) Int          -- ^ L3 counts
  -> (Int -> Int)                     -- ^ supOf1
  -> (Int -> Int -> Int)              -- ^ supOf2
  -> ([Rule], Int)
enumerateRules opts excludeSet n l2 l3 supOf1 supOf2 =
  let pairRules =
        [ rule
        | ((a, b), supAB) <- Map.toList l2
        , (lhs, rhs) <- [([a], b), ([b], a)]
        , let rule = mkRule lhs rhs supAB
        ]

      tripleRules =
        [ rule
        | ((a, b, c), supABC) <- Map.toList l3
        , (lhs, rhs) <- [ ([a, b], c)
                        , ([a, c], b)
                        , ([b, c], a)
                        ]
        , let rule = mkRule lhs rhs supABC
        ]

      all_ = pairRules ++ tripleRules
      considered = length all_
      kept = [ r | r <- all_, passes r ]
  in (kept, considered)
  where
    mkRule :: [Int] -> Int -> Int -> Rule
    mkRule lhs rhs supJoint =
      let supLhs = case lhs of
            [x]    -> supOf1 x
            [x, y] -> supOf2 x y
            _      -> 0  -- v1: cap at 3, so |lhs| ∈ {1, 2}
          supRhs = supOf1 rhs
          conf
            | supLhs == 0 = 0
            | otherwise   = fromIntegral supJoint / fromIntegral supLhs
          supRhsFrac
            | n == 0    = 0
            | otherwise = fromIntegral supRhs / fromIntegral n
          lift
            | supRhsFrac == 0 = 0
            | otherwise       = conf / supRhsFrac
          supFrac
            | n == 0    = 0
            | otherwise = fromIntegral supJoint / fromIntegral n
          pRaw = fisherUpperBound n supLhs supRhs supJoint
      in Rule
           { rLhs        = lhs
           , rRhs        = rhs
           , rSupport    = supFrac
           , rConfidence = conf
           , rLift       = lift
           , rPRaw       = pRaw
           , rPCorrected = pRaw  -- filled in by run after Bonferroni
           }

    -- Frequency-band gate: reject the rule if any item on either side
    -- is in the most-frequent band. Cheap O(|lhs|) membership tests on
    -- an IntSet.
    notExcluded :: Rule -> Bool
    notExcluded r =
         not (IS.member (rRhs r) excludeSet)
      && not (any (`IS.member` excludeSet) (rLhs r))

    passes :: Rule -> Bool
    passes r =
         notExcluded r
      && rConfidence r >= optMinConfidence opts
      && rLift       r >= optMinLift opts

----------------------------------------------------------------------
-- Forced-by-elaborator suppressor.
--
-- The per-case-unfold-family detector lives in
-- 'AgdaOptimization.FamilyFilter' so 'AgdaOptimization.ConceptBundle'
-- can reuse it. Here we just lift the bundle-level decision to a
-- 'Rule' (using 'ruleBundle') and partition the list.

-- | Split a rule list into @(kept, droppedCount)@ by running every
-- rule's bundle through 'isForcedByFamily'. Strict count; preserves
-- order of the kept list.
partitionForced :: Index -> Double -> [Rule] -> ([Rule], Int)
partitionForced ix fraction = foldr step ([], 0)
  where
    step r (!keep, !dropped)
      | isForcedByFamily ix fraction (ruleBundle r) =
          (keep, dropped + 1)
      | otherwise =
          (r : keep, dropped)

----------------------------------------------------------------------
-- Statistical control.

-- | Upper bound on Fisher's-exact two-tailed p-value via the
-- chi-squared (with continuity correction skipped for simplicity).
--
-- For the 2×2 contingency table with marginals @N, supLhs, supRhs@
-- and joint cell @supJoint = a@:
--
-- @
--             Y=yes        Y=no       row total
--   X=yes      a            b          supLhs
--   X=no       c            d          N - supLhs
--   col tot    supRhs   N - supRhs     N
-- @
--
-- @χ² = N · (a·d − b·c)² / ((a+b)(c+d)(a+c)(b+d))@. We then map χ² to a
-- two-tailed p-value via the survival function of χ²₁,
-- @p ≈ erfc(√(χ²/2))@. This is an /upper bound/ on the Fisher's-exact
-- p when expected cell counts are reasonable; it's loose when any cell
-- is very small but that only makes our Bonferroni more conservative,
-- which is the safe direction.
--
-- Degenerate inputs (zero margin) return @p = 1@, which guarantees the
-- rule is filtered out by Bonferroni.
fisherUpperBound :: Int -> Int -> Int -> Int -> Double
fisherUpperBound n supLhs supRhs supJoint
  | n <= 0 || supLhs <= 0 || supRhs <= 0
      || supLhs >= n || supRhs >= n = 1.0
  | otherwise =
      let a = fromIntegral supJoint :: Double
          b = fromIntegral (supLhs - supJoint)
          c = fromIntegral (supRhs - supJoint)
          d = fromIntegral (n - supLhs - supRhs + supJoint)
          nd = fromIntegral n :: Double
          num = nd * (a * d - b * c) ** 2
          den = fromIntegral (supLhs)
              * fromIntegral (n - supLhs)
              * fromIntegral (supRhs)
              * fromIntegral (n - supRhs)
      in if den <= 0
           then 1.0
           else
             let chi2 = num / den
                 p    = erfcApprox (sqrt (chi2 / 2))
             in clamp01 p

clamp01 :: Double -> Double
clamp01 x
  | x < 0     = 0
  | x > 1     = 1
  | otherwise = x

-- | Abramowitz & Stegun 7.1.26 rational approximation of @erfc(x)@
-- for @x ≥ 0@. Max abs. error ≈ 1.5e-7 — more than enough for a
-- Bonferroni gate at p ≤ 0.01. For @x < 0@ returns @2 − erfc(-x)@,
-- but the chi-squared path above only feeds @x ≥ 0@.
erfcApprox :: Double -> Double
erfcApprox x
  | x < 0     = 2 - erfcApprox (-x)
  | otherwise =
      let p  = 0.3275911
          a1 = 0.254829592
          a2 = -0.284496736
          a3 = 1.421413741
          a4 = -1.453152027
          a5 = 1.061405429
          t  = 1 / (1 + p * x)
          poly = ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t
      in poly * exp (- x * x)

----------------------------------------------------------------------
-- Rendering.

renderRulesTable :: Index -> [(Int, Rule)] -> String
renderRulesTable ix ranked =
  let header = [ "Rank", "LHS", "RHS", "Support", "Conf", "Lift", "Spec", "p_corr" ]
      rows   = map (renderRuleRow ix) ranked
  in renderTable header rows

renderRuleRow :: Index -> (Int, Rule) -> [String]
renderRuleRow ix (rank, r) =
  [ show rank
  , T.unpack (T.intercalate "," (map (shortName ix) (rLhs r)))
  , T.unpack (shortName ix (rRhs r))
  , showD3 (rSupport r)
  , showD3 (rConfidence r)
  , showD3 (rLift r)
  , showD3 (specificity r)
  , showD3 (rPCorrected r)
  ]

----------------------------------------------------------------------
-- Near-miss flagger.

-- | For each of the top-5 /distinct/ bundles drawn from rules with
-- LHS size ≥ 2, walk the transactions and report 2–3 baskets that
-- contain @k − 1@ of the @k@ items in the bundle (i.e. they are one
-- item short of completing it).
--
-- Dedup by bundle: rules @{a,b} ⇒ c@ and @{a,c} ⇒ b@ describe the
-- same bundle @{a,b,c}@, so we'd print the same near-miss list twice
-- otherwise.
renderNearMisses :: Index -> [Tx] -> [Rule] -> IO ()
renderNearMisses ix txs ranked = do
  let bundles = take 5
              $ dedupBundles
              $ map ruleBundle
              $ filter (\r -> length (rLhs r) >= 2) ranked
  when (not (null bundles)) $ do
    putStrLn "## Near-miss bundles"
    putStrLn "(transactions that use k-1 of k items in a rule's bundle)"
    putStrLn ""
    mapM_ (renderOneBundleMisses ix txs) bundles

-- | Sorted, deduplicated bundle list (just the items in @rLhs ∪
-- {rRhs}@).
ruleBundle :: Rule -> [Int]
ruleBundle r = sort (nub (rRhs r : rLhs r))

-- | Preserve order while dropping duplicates. We could use 'Set' here
-- but the list is at most ~hundreds; nub-in-order is fine and keeps
-- the result stable.
dedupBundles :: [[Int]] -> [[Int]]
dedupBundles = go Map.empty
  where
    go _ []           = []
    go !seen (b : bs)
      | Map.member b seen = go seen bs
      | otherwise         = b : go (Map.insert b () seen) bs

renderOneBundleMisses :: Index -> [Tx] -> [Int] -> IO ()
renderOneBundleMisses ix txs bundle = do
  let bundleSet = IS.fromList bundle
      k = length bundle
      misses =
        [ (tx, missing)
        | tx <- txs
        , let inter = IS.intersection (txItemSet tx) bundleSet
              haveCount = IS.size inter
              missing = IS.difference bundleSet (txItemSet tx)
        , haveCount == k - 1
        , IS.size missing == 1
        ]
      shown = take 3 misses
      bundleLabel = T.intercalate ", " (map (shortName ix) bundle)
  putStrLn $ "* bundle {" ++ T.unpack bundleLabel ++ "} (k=" ++ show k ++ ")"
  if null shown
    then putStrLn "  (no near-miss baskets)"
    else mapM_ (renderOneMiss ix) shown
  putStrLn ""

renderOneMiss :: Index -> (Tx, IntSet) -> IO ()
renderOneMiss ix (tx, missing) = do
  let owner   = defAt ix (txOwner tx)
      ownerNm = T.unpack (defName owner)
      missingNm = case IS.toList missing of
        [m] -> T.unpack (shortName ix m)
        ms  -> T.unpack (T.intercalate "," (map (shortName ix) ms))
  putStrLn $ "  - " ++ ownerNm
          ++ " uses (k-1)/k of bundle; missing: " ++ missingNm

----------------------------------------------------------------------
-- JSON rendering. See the schema in 'AgdaOptimization.Report'.

basketJson
  :: Index
  -> Options
  -> Stats
  -> Double          -- ^ p-correlation threshold (Bonferroni gate).
  -> [Tx]            -- ^ Qualifying transactions (for near-misses).
  -> [Rule]          -- ^ Kept rules (already top-N capped, ranked).
  -> A.Value
basketJson ix opts Stats{..} pThr txs keptRules =
  A.object
    [ "subcommand" .= ("basket" :: T.Text)
    , "options"    .= basketOptionsJson opts
    , "stats"      .= A.object
        [ "tx"                 .= sTotalTx
        , "qualifying"         .= sQualifyingTx
        , "l1"                 .= sL1Count
        , "l2"                 .= sL2Count
        , "l3"                 .= sL3Count
        , "top_freq_excluded"  .= sTopFreqExcluded
        , "rules_considered"   .= sRulesConsidered
        , "rules_passed"       .= sRulesPassed
        , "rules_kept"         .= sRulesKept
        , "forced_suppressed"  .= sForcedSuppressed
        , "p_corr_threshold"   .= pThr
        -- Budget additions: present unconditionally. @budget_exhausted@
        -- is @false@ when no budget was set; @reached_level@ is 3 in
        -- the no-budget path (full pipeline completed).
        , "budget_exhausted"   .= sBudgetExhausted
        , "reached_level"      .= sReachedLevel
        ]
    , "near_misses" .= A.toJSON (collectNearMisses ix txs keptRules)
    , "rules"       .= A.toJSON
        (zipWith (basketRuleJson ix) [1 :: Int ..] keptRules)
    ]

basketOptionsJson :: Options -> A.Value
basketOptionsJson Options{..} = A.object
  [ "min_support"           .= optMinSupport
  , "min_confidence"        .= optMinConfidence
  , "min_lift"              .= optMinLift
  , "exclude_top_freq_pct"  .= optExcludeTopFreq
  , "top_n"                 .= optTopN
  -- @budget_seconds@: 0.0 when the @--budget@ flag was not passed.
  , "budget_seconds"        .= optBudgetSecs
  , "forced_suppress"       .= optForcedSuppress
  , "forced_fraction"       .= optForcedFraction
  , "max_basket_size"       .= optMaxBasketSize
  ]

basketRuleJson :: Index -> Int -> Rule -> A.Value
basketRuleJson ix rank r = A.object
  [ "rank"        .= rank
  , "lhs"         .= map (shortName ix) (rLhs r)
  , "rhs"         .= shortName ix (rRhs r)
  , "support"     .= rSupport r
  , "confidence"  .= rConfidence r
  , "lift"        .= rLift r
  , "specificity" .= specificity r
  , "p_corrected" .= rPCorrected r
  ]

-- | Mirror 'renderNearMisses' but return a JSON-shaped list. Each entry
-- is one bundle of items and the (≤ 3) transactions that have all but
-- one of them.
collectNearMisses :: Index -> [Tx] -> [Rule] -> [A.Value]
collectNearMisses ix txs ranked =
  let bundles = take 5
              $ dedupBundles
              $ map ruleBundle
              $ filter (\r -> length (rLhs r) >= 2) ranked
  in map (oneBundleMissesJson ix txs) bundles

oneBundleMissesJson :: Index -> [Tx] -> [Int] -> A.Value
oneBundleMissesJson ix txs bundle =
  let bundleSet = IS.fromList bundle
      k = length bundle
      misses =
        [ (tx, missing)
        | tx <- txs
        , let inter = IS.intersection (txItemSet tx) bundleSet
              haveCount = IS.size inter
              missing = IS.difference bundleSet (txItemSet tx)
        , haveCount == k - 1
        , IS.size missing == 1
        ]
      shown = take 3 misses
      missJson (tx, missing) = A.object
        [ "owner"   .= defName (defAt ix (txOwner tx))
        , "missing" .= map (shortName ix) (IS.toList missing)
        ]
  in A.object
       [ "bundle" .= map (shortName ix) bundle
       , "misses" .= map missJson shown
       ]
