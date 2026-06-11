{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Entwine — pairwise mutual information over caller baskets.
--
-- The motivation is to catch what 'AgdaOptimization.Basket' cannot:
-- /low-frequency/, /high-determinism/ pairs.  Apriori thresholds on
-- support/confidence/lift miss pairs that appear in only a handful of
-- callers but whose joint behaviour is /perfectly/ deterministic
-- (IQR ≈ 1).  Those are precisely the bundles worth folding into a
-- combinator.  Entwine also catches the inverse signal —
-- /anti-coreference/: pairs systematically partitioned across callers,
-- which 'Basket' (frequency-anchored) is blind to by construction.
--
-- Pipeline:
--
--   1. Build a /caller basket/ per node @c@ with non-empty
--      @idxForward[c]@.  The basket is either the direct out-edges
--      (default) or the full transitive closure ('descendants') when
--      @--transitive@ is set.  Optionally drop short-name regex
--      matches (@--exclude-name-regex@).
--
--   2. Walk every basket once, emitting all @(x, y)@ pairs with
--      @x < y@ — this is the Apriori trick that brings the cost from
--      @O(D²)@ down to @O(Σ_C |C|²)@.  Aggregate counts in
--      'IM.IntMap' (Int -> IntMap Int -> Int).  Compute per-def
--      caller-frequency in the same pass.
--
--   3. For each candidate pair @(x, y)@ with @n_xy ≥
--      --min-co-callers@ compute the 2×2 contingency table:
--
--      @
--                       Y in C       Y not in C
--        X in C        n_11           n_10
--        X not in C    n_01           n_00
--      @
--
--      …from which:
--
--      * @I(X;Y) = Σ p_ij · log2(p_ij / (p_i · p_j))@
--        (cells with @p_ij == 0@ contribute 0; standard convention)
--      * @H(X,Y) = - Σ p_ij · log2(p_ij)@
--      * @IQR    = I / H@  (1 = perfectly mutual; 0 = independent)
--      * @G      = 2 · Σ O_ij · ln(O_ij / E_ij)@
--        — natural log, expected counts from independence;
--        asymptotic χ² with 1 dof.  Default gate @G ≥ 6.635@
--        corresponds to p < 0.01.
--
--   4. Filter by @--min-iqr@ and @--min-g-stat@, sort by IQR
--      descending (with G as the tertiary tiebreaker), keep
--      @--top-n@.
--
--   5. Flag @anti=True@ when @n_11 < n_10 + n_01@ and the joint cell
--      is the /smaller/ of the two marginals — i.e. the pair is more
--      "either-or" than "both".
--
-- The per-pair scoring step is the only hot loop (linear in the
-- candidate-pair count; usually 10⁴–10⁵).  We spark it via @parMap
-- rdeepseq@ over chunks; the reduction is sort-by-key on a
-- 'NFData'-able record, so determinism between @-N1@ and @-NK@ is
-- preserved by construction.
module AgdaOptimization.Entwine
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           Data.Foldable        ( foldl' )
import qualified Data.IntMap.Strict   as IM
import           Data.IntMap.Strict   ( IntMap )
import qualified Data.IntSet          as IS
import           Data.IntSet          ( IntSet )
import           Data.List            ( sortOn )
import           Data.Ord             ( Down(..) )
import           Data.Text            ( Text )
import qualified Data.Text            as T
import           System.IO            ( hPutStrLn, stderr )

import           Control.DeepSeq      ( NFData(..) )
import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )


import           AgdaGraph.Index      ( Index(..), defAt, descendants )
import           AgdaGraph.Schema     ( Definition(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Common ( computeExcludedSet, lastSegment )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , showD3, withHumanOutput )

----------------------------------------------------------------------
-- Options.

-- | User-facing options.  All thresholds are inclusive (@>=@).
data Options = Options
  { optMinCoCallers     :: !Int
    -- ^ Minimum number of callers a pair must co-occur in to be
    -- considered.  Default 3.  Low values let in noise from
    -- single-caller incidence; higher values trade off the
    -- /low-frequency/ surface Entwine is designed to expose.
  , optMinIQR           :: !Double
    -- ^ Minimum IQR (I / H_xy) to keep a pair.  Default 0.5.
  , optMinGStat         :: !Double
    -- ^ Minimum G-statistic to keep a pair.  @6.635@ corresponds to
    -- p < 0.01 at 1 dof under χ²; @3.841@ would be p < 0.05.
  , optTopN             :: !Int
    -- ^ Cap on retained pairs after ranking.  Default 100.
  , optTransitive       :: !Bool
    -- ^ Use the full forward transitive closure as the basket
    -- instead of direct out-edges.  Default 'False' — direct edges
    -- give cleaner "co-call" semantics; transitive baskets are wider
    -- and risk drowning the signal in universally-reachable
    -- primitives.
  , optExcludeNameRegex :: !Text
    -- ^ POSIX-ERE pattern matched against /unqualified/ def names.
    -- Defs whose short name matches are dropped from every basket
    -- and excluded from the candidate pair set.  Empty (default) =
    -- no filter.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optMinCoCallers     = 3
  , optMinIQR           = 0.5
  , optMinGStat         = 6.635
  , optTopN             = 100
  , optTransitive       = False
  , optExcludeNameRegex = T.empty
  }

-- | Declarative flag spec for the @entwine@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
--
-- @--transitive@ is a 'SwitchPreGuard' switch (matched against the raw
-- token before 'splitFlag', so @--transitive=x@ falls through to the
-- unknown-flag path); its YAML key is @transitive@.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "min-co-callers" "--min-co-callers=N             pair must co-occur in >= N callers (default 3)"
      (\x o -> o { optMinCoCallers = x })
  , DblFlag "min-iqr" "--min-iqr=F                    min IQR (default 0.5)"
      (\x o -> o { optMinIQR = x })
  , DblFlag "min-g-stat" "--min-g-stat=F                 min G-statistic; 6.635 ≈ p<0.01 (default)"
      (\x o -> o { optMinGStat = x })
  , IntFlag "top-n" "--top-n=N                      rows to keep (default 100)"
      (\x o -> o { optTopN = x })
  , SwitchFlag "transitive" "--transitive                   use ancestors as basket instead of direct callers"
      SwitchPreGuard (\o -> o { optTransitive = True })
      (Just "transitive") (\v o -> o { optTransitive = v })
  , TextFlag "exclude-name-regex" "--exclude-name-regex=PATTERN   POSIX-ERE on unqualified name"
      (\p o -> o { optExcludeNameRegex = p })
  ]

-- | Hand-rolled CLI parser.  Mirrors the dispatch table style used by
-- every other 'AgdaOptimization' analysis (see 'Basket.parseOptions').
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "entwine" flagSpecs

-- | Overlay the @entwine:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "entwine" flagSpecs obj o0

----------------------------------------------------------------------
-- Internal types.

-- | One scored pair, post-thresholds.  Strict record + 'NFData' so
-- 'parMap rdeepseq' actually forces the work in the spark.
data Pair = Pair
  { pX        :: !Int
  , pY        :: !Int
  , pN11      :: !Int
  , pN10      :: !Int
  , pN01      :: !Int
  , pN00      :: !Int
  , pMI       :: !Double  -- ^ I(X;Y) in bits.
  , pHxy      :: !Double  -- ^ H(X, Y) in bits.
  , pIQR      :: !Double  -- ^ Information Quality Ratio = I / H.
  , pG        :: !Double  -- ^ G-statistic (natural log).
  , pAnti     :: !Bool    -- ^ Anti-coreference flag.
  } deriving (Show)

instance NFData Pair where
  rnf Pair{..} =
        rnf pX
    `seq` rnf pY
    `seq` rnf pN11
    `seq` rnf pN10
    `seq` rnf pN01
    `seq` rnf pN00
    `seq` rnf pMI
    `seq` rnf pHxy
    `seq` rnf pIQR
    `seq` rnf pG
    `seq` rnf pAnti

-- | Aggregate stats reported in the header line.
data Stats = Stats
  { sCallers         :: !Int    -- ^ @N@ — non-empty baskets.
  , sBasketItemsAvg  :: !Double -- ^ mean basket size after filtering.
  , sExcludedItems   :: !Int    -- ^ defs dropped by @--exclude-name-regex@.
  , sPairsCounted    :: !Int    -- ^ candidate pairs that crossed @--min-co-callers@.
  , sPairsKept       :: !Int    -- ^ after IQR + G gates.
  , sPairsEmitted    :: !Int    -- ^ after @--top-n@ cap.
  } deriving (Show)

----------------------------------------------------------------------
-- Entry point.

-- | Top-level: build baskets, count pairs, score, render.  Never
-- throws.  Honours @gOutFormat@ / @gOutPath@ for JSON + human output.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let !excluded    = computeExcludedSet ix (optExcludeNameRegex opts)
      !nExcluded   = IS.size excluded

      -- 1. Baskets.  Only callers with a non-empty basket count.
      !baskets     = buildBaskets ix opts excluded
      !nCallers    = length baskets

      -- 2. Per-def caller frequency + pair counts in one pass.
      (!singleCnt, !pairCnt) = countPairs baskets

      -- Equals 'length candidates' by construction (same '>= minCo'
      -- filter), so reuse 'nCand' rather than folding 'pairCnt' again.
      !pairsCounted = nCand
      !minCo = max 1 (optMinCoCallers opts)

      !avgItems
        | nCallers == 0 = 0
        | otherwise     =
            let !tot = sum (map (IS.size . snd) baskets)
            in fromIntegral tot / fromIntegral nCallers

      -- 3. Score every surviving candidate.  Sparked in chunks; the
      -- result of the map is a list of NF Pairs so spark order does
      -- not affect bytes.
      !candidates =
        [ (x, y, n)
        | (x, inner) <- IM.toAscList pairCnt
        , (y, n)     <- IM.toAscList inner
        , n >= minCo
        ]
      -- Aim for ~64 chunks but never finer than ~32 candidates each.
      !nCand     = length candidates
      !nChunks   = max 1 (min 64 ((nCand + 31) `div` 32))
      !chunkSize = max 1 ((nCand + nChunks - 1) `div` nChunks)
      !scored =
        concat (parMap rdeepseq (map (scorePair singleCnt nCallers))
                                (chunkList chunkSize candidates))

      -- 4. Filter on IQR / G; sort by IQR desc, G desc, x asc, y asc
      -- for stable output across runs.
      !filtered =
        [ p | p <- scored
            , pIQR p >= optMinIQR opts
            , pG   p >= optMinGStat opts
            ]
      !ranked = sortOn rankKey filtered
        where
          rankKey p = (Down (pIQR p), Down (pG p), pX p, pY p)
      !kept = take (max 0 (optTopN opts)) ranked

      !stats = Stats
        { sCallers        = nCallers
        , sBasketItemsAvg = avgItems
        , sExcludedItems  = nExcluded
        , sPairsCounted   = pairsCounted
        , sPairsKept      = length filtered
        , sPairsEmitted   = length kept
        }

  hPutStrLn stderr $
    "[entwine] " ++ show nCallers
      ++ " callers, " ++ show pairsCounted
      ++ " candidate pairs (>=" ++ show minCo
      ++ "), kept " ++ show (length kept)
      ++ "/" ++ show (length filtered) ++ "."

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        entwineJson ix opts stats kept
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn (headerLine opts)
      putStrLn (statsLine stats)
      if null kept
        then putStrLn $
               "no pairs above thresholds at these parameters "
            ++ "(min-co-callers >= " ++ show (optMinCoCallers opts)
            ++ ", min-iqr >= " ++ showD3 (optMinIQR opts)
            ++ ", min-g-stat >= " ++ showD3 (optMinGStat opts) ++ ")."
        else do
          putStr (renderPairsTable ix kept)
          putStrLn ""

----------------------------------------------------------------------
-- Basket construction.

-- | Build one basket per node that has a non-empty out-edge set.
-- Items are filtered against the @--exclude-name-regex@ excluded set.
-- A basket with fewer than 2 items contributes nothing to pair counts;
-- we keep it in the list so 'sCallers' / 'sBasketItemsAvg' reflect
-- the true qualifying-caller pool.
buildBaskets :: Index -> Options -> IntSet -> [(Int, IntSet)]
buildBaskets ix opts excluded =
  let n   = idxNodeCount ix
      raw = [ (c, basket c) | c <- [0 .. n - 1]
                            , not (IS.null (basket c)) ]
      basket c
        | optTransitive opts =
            let !d = descendants ix (IS.singleton c)
            in IS.difference d excluded
        | otherwise =
            let !d = IM.findWithDefault IS.empty c (idxForward ix)
            in IS.difference d excluded
  in raw

----------------------------------------------------------------------
-- Pair counting (Apriori within-basket emission).

-- | One pass over the baskets.  Yields:
--
--   * a per-def map of \"how many callers contain me\" (the
--     marginal @n_x@ for every candidate @x@);
--   * a nested map keyed by @(x, y)@ with @x < y@ of joint counts.
--
-- Both maps are strict.  We carry the pair count as
-- @IntMap (IntMap Int)@ because nested lookups dominate the per-pair
-- scoring later, and 'IntMap' is a strict-spined Patricia trie
-- (@Map (Int, Int)@ would box the pair).
countPairs
  :: [(Int, IntSet)]
  -> (IntMap Int, IntMap (IntMap Int))
countPairs baskets =
  foldl' step (IM.empty, IM.empty) baskets
  where
    step (!single, !pairs) (_, items) =
      let !single' = IS.foldl' bumpSingle single items
          !pairs'  = enumeratePairs pairs (IS.toAscList items)
      in (single', pairs')

    bumpSingle !m i = IM.insertWith (+) i 1 m

    -- Walk the sorted item list once; for each prefix item @x@ bump
    -- every (x, y) with y in the suffix.  Sorted input guarantees
    -- x < y so we don't need orderPair.
    enumeratePairs !m []     = m
    enumeratePairs !m (x:rest) =
      let !m' = foldl' (\ !mm y -> bumpPair mm x y) m rest
      in enumeratePairs m' rest

    bumpPair !m x y =
      IM.alter (Just . bumpInner) x m
      where
        bumpInner Nothing   = IM.singleton y 1
        bumpInner (Just im) = IM.insertWith (+) y 1 im

----------------------------------------------------------------------
-- Per-pair scoring.

-- | Compute the 2×2 cells, MI, H_xy, IQR, G-statistic, and the
-- anti-coreference flag.  Returns a strict 'Pair'.
--
-- Edge cases:
--
--   * Any cell with @n_ij = 0@ contributes 0 to MI and H by the
--     usual @0·log 0 := 0@ convention.
--
--   * If @H_xy = 0@ (one cell holds all callers) IQR defaults to
--     0.  This only happens when X and Y are perfectly identical /
--     perfectly disjoint and one of those degenerate cases also
--     drives @n_x = n_y = N@ — we'd want such a pair filtered out
--     by the IQR threshold anyway.
--
--   * @G = 0@ on degenerate margins (any zero expected cell).
scorePair :: IntMap Int -> Int -> (Int, Int, Int) -> Pair
scorePair singleCnt n (x, y, nxy) =
  let !nx   = IM.findWithDefault 0 x singleCnt
      !ny   = IM.findWithDefault 0 y singleCnt
      !n11  = nxy
      !n10  = max 0 (nx - nxy)
      !n01  = max 0 (ny - nxy)
      !n00  = max 0 (n - nx - ny + nxy)
      !nd   = fromIntegral n :: Double

      -- joint probabilities
      !p11 = fromIntegral n11 / nd
      !p10 = fromIntegral n10 / nd
      !p01 = fromIntegral n01 / nd
      !p00 = fromIntegral n00 / nd

      -- marginals
      !px1 = fromIntegral nx / nd
      !px0 = 1 - px1
      !py1 = fromIntegral ny / nd
      !py0 = 1 - py1

      -- mutual information in bits.
      !mi = miCell p11 px1 py1
          + miCell p10 px1 py0
          + miCell p01 px0 py1
          + miCell p00 px0 py0

      !hxy = entropyTerm p11
           + entropyTerm p10
           + entropyTerm p01
           + entropyTerm p00

      !iqr
        | hxy <= 0  = 0
        | otherwise = mi / hxy

      !g = gStat n11 n10 n01 n00 nx ny n

      -- Anti-coreference: more off-diagonal mass than joint, and the
      -- joint is smaller than the smaller of the two marginals — the
      -- pair behaves more like XOR than AND.
      !anti = n10 + n01 > n11 && n11 < min nx ny
  in Pair
       { pX = x, pY = y
       , pN11 = n11, pN10 = n10, pN01 = n01, pN00 = n00
       , pMI = mi
       , pHxy = hxy
       , pIQR = iqr
       , pG  = g
       , pAnti = anti
       }

-- | Single-cell MI contribution: @p · log2(p / (px · py))@, with the
-- standard @0·log 0 := 0@ convention.  A zero marginal would make the
-- ratio undefined; we return 0 in that case as well (the cell must
-- also be zero, since the joint cannot exceed either marginal).
miCell :: Double -> Double -> Double -> Double
miCell p px py
  | p  <= 0   = 0
  | px <= 0 || py <= 0 = 0
  | otherwise = p * log2 (p / (px * py))

-- | Per-cell Shannon term @-p · log2 p@ with @0·log 0 := 0@.
entropyTerm :: Double -> Double
entropyTerm p
  | p <= 0    = 0
  | otherwise = - p * log2 p

log2 :: Double -> Double
log2 x = log x / log 2

-- | G-statistic with the natural log: @G = 2 · Σ O_ij · ln(O_ij / E_ij)@.
-- Expected counts come from independence: @E_ij = (row · col) / N@.
-- Cells with zero observed are skipped (standard convention; the
-- limit of @O · ln(O / E)@ is 0 as @O → 0@).  Returns 0 on degenerate
-- margins.
gStat :: Int -> Int -> Int -> Int -> Int -> Int -> Int -> Double
gStat n11 n10 n01 n00 nx ny n
  | n <= 0 || nx <= 0 || ny <= 0 || nx >= n || ny >= n = 0
  | otherwise =
      let nd   = fromIntegral n :: Double
          e11  = fromIntegral nx       * fromIntegral ny       / nd
          e10  = fromIntegral nx       * fromIntegral (n - ny) / nd
          e01  = fromIntegral (n - nx) * fromIntegral ny       / nd
          e00  = fromIntegral (n - nx) * fromIntegral (n - ny) / nd
          term o e
            | o <= 0    = 0
            | e <= 0    = 0
            | otherwise = fromIntegral o * log (fromIntegral o / e)
      in 2 * (term n11 e11 + term n10 e10 + term n01 e01 + term n00 e00)

----------------------------------------------------------------------
-- (Regex exclusion + lastSegment moved to "AgdaOptimization.Common".)

----------------------------------------------------------------------
-- Chunking (matches Basket).

-- | Standard list chunking.  Negative / zero chunk size clamps to 1
-- to avoid infinite loops; empty input yields empty output.
chunkList :: Int -> [a] -> [[a]]
chunkList k xs0
  | k <= 0    = chunkList 1 xs0
  | otherwise = go xs0
  where
    go [] = []
    go xs = let (h, t) = splitAt k xs in h : go t

----------------------------------------------------------------------
-- Human rendering.

headerLine :: Options -> String
headerLine Options{..} =
     "# Entwine — pairwise MI over caller baskets (min-co-callers>="
  ++ show optMinCoCallers
  ++ ", min-iqr>=" ++ showD3 optMinIQR
  ++ ", min-g-stat>=" ++ showD3 optMinGStat
  ++ ", top-n=" ++ show optTopN
  ++ (if optTransitive then ", transitive" else ", direct")
  ++ ")"

statsLine :: Stats -> String
statsLine Stats{..} =
     "# callers=" ++ show sCallers
  ++ " avg-basket=" ++ showD3 sBasketItemsAvg
  ++ " excluded=" ++ show sExcludedItems
  ++ " pairs-counted=" ++ show sPairsCounted
  ++ " kept=" ++ show sPairsKept
  ++ " emitted=" ++ show sPairsEmitted

renderPairsTable :: Index -> [Pair] -> String
renderPairsTable ix kept =
  let header = ["Rank", "X", "Y", "Module-X", "Module-Y"
               , "n_xy", "n_x", "n_y"
               , "I", "IQR", "G", "anti"]
      rows = zipWith (renderPairRow ix) [1 :: Int ..] kept
  in renderTable header rows

-- | One body row.  Includes the last-two-segment module for each side
-- so users can disambiguate the same unqualified name appearing in
-- multiple modules.
renderPairRow :: Index -> Int -> Pair -> [String]
renderPairRow ix rank p =
  let nx = pN11 p + pN10 p
      ny = pN11 p + pN01 p
      dx = defAt ix (pX p)
      dy = defAt ix (pY p)
  in [ show rank
     , T.unpack (shortNameOf dx)
     , T.unpack (shortNameOf dy)
     , T.unpack (shortModule (defModule dx))
     , T.unpack (shortModule (defModule dy))
     , show (pN11 p)
     , show nx
     , show ny
     , showD3 (pMI p)
     , showD3 (pIQR p)
     , showD3 (pG p)
     , if pAnti p then "yes" else "no"
     ]

-- | Last dot-component of a QName.  Same trick as Basket /
-- LoadBearing — full QNames blow tables up.
shortNameOf :: Definition -> Text
shortNameOf = lastSegment . defName

-- | Last two dot-components of a module name, joined with @.@.
-- @\"Local.Step\"@ for @\"Protocol.Example.Local.Step\"@;
-- @\"Records\"@ for @\"Records\"@; @\"\"@ for empty.
shortModule :: Text -> Text
shortModule m =
  let segs = T.splitOn "." m
      n    = length segs
  in T.intercalate "." (drop (max 0 (n - 2)) segs)

----------------------------------------------------------------------
-- JSON rendering.

-- | Self-describing JSON object.  Same conventions as every other
-- subcommand: @subcommand@ first, then @options@, then @stats@, then
-- the body.  Pair entries include both raw cell counts and derived
-- statistics so downstream tools don't need to re-derive the table.
entwineJson :: Index -> Options -> Stats -> [Pair] -> A.Value
entwineJson ix opts Stats{..} kept = A.object
  [ "subcommand" .= ("entwine" :: Text)
  , "options"    .= entwineOptionsJson opts
  , "stats"      .= A.object
      [ "callers"          .= sCallers
      , "avg_basket_size"  .= sBasketItemsAvg
      , "excluded_items"   .= sExcludedItems
      , "pairs_counted"    .= sPairsCounted
      , "pairs_kept"       .= sPairsKept
      , "pairs_emitted"    .= sPairsEmitted
      ]
  , "pairs" .= A.toJSON
      (zipWith (pairJson ix) [1 :: Int ..] kept)
  ]

entwineOptionsJson :: Options -> A.Value
entwineOptionsJson Options{..} = A.object
  [ "min_co_callers"     .= optMinCoCallers
  , "min_iqr"            .= optMinIQR
  , "min_g_stat"         .= optMinGStat
  , "top_n"              .= optTopN
  , "transitive"         .= optTransitive
  , "exclude_name_regex" .= optExcludeNameRegex
  ]

pairJson :: Index -> Int -> Pair -> A.Value
pairJson ix rank p = A.object
  [ "rank"  .= rank
  , "x"     .= defName (defAt ix (pX p))
  , "y"     .= defName (defAt ix (pY p))
  , "n_11"  .= pN11 p
  , "n_10"  .= pN10 p
  , "n_01"  .= pN01 p
  , "n_00"  .= pN00 p
  , "mi"    .= pMI p
  , "h_xy"  .= pHxy p
  , "iqr"   .= pIQR p
  , "g"     .= pG p
  , "anti"  .= pAnti p
  ]
