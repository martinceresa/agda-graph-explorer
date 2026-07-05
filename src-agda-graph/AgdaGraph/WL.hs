{-# LANGUAGE BangPatterns #-}

-- | Weisfeiler–Leman colour refinement, the per-node hashing it relies on,
-- and weighted-Jaccard similarity over the resulting fingerprints. Shared
-- by the structural-similarity analyses (@fingerprint@, @echo@,
-- @silhouette@ in @agda-optimization@, and @similar_types@ in
-- @agda-explore@).
--
-- It lives in the @agda-graph@ library (rather than the
-- @agda-optimization@ executable) precisely so the @agda-explore@ daemon
-- can compute the /same/ fingerprints the batch @silhouette@ analysis
-- does — point queries and the bulk analysis then agree by construction.
--
-- The WL functions are parameterised by a neighbour function
-- @Int -> IS.IntSet@, so each caller supplies its own adjacency (a
-- direction, or a provenance-split subgraph) without this module having to
-- know about any 'Direction' enum.
module AgdaGraph.WL
  ( -- * Hashing primitives
    mixI
  , hashInts
  , hashTag
    -- * Kind / state / degree tags
  , kindCode
  , stateCode
  , outDegreeBucket
    -- * WL refinement
  , ColorVec
  , initialColors
  , wlStep
  , refine
    -- * Fingerprints
  , Fingerprint
  , fingerprintAt
  , weightedJaccard
  ) where

import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           Data.Bits          ( xor, shiftL, shiftR )
import           Data.List          ( sort )
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS
import           Data.Vector        ( Vector )
import qualified Data.Vector        as V

import           AgdaGraph.Index    ( Index(..), defAt )
import           AgdaGraph.Schema   ( Definition(..), Kind(..), State(..) )

--------------------------------------------------------------------------------
-- Hashing primitives
--
-- A small Bernstein/xor mixer in pure 'Int' arithmetic. This is the /only/
-- hash these analyses use; everything funnels through 'mixI'.
--------------------------------------------------------------------------------

-- | Mix one 'Int' into a running hash. djb2-ish, with an extra xor of a
-- shifted version of @x@ to spread bits across the word.
mixI :: Int -> Int -> Int
mixI !acc !x =
  let !a  = acc * 1099511628211          -- FNV-ish prime
      !b  = a `xor` x
      !c  = b `xor` (b `shiftR` 17)
      !d  = c * 31
  in d `xor` (d `shiftL` 5)

-- | Combine a salt with a list of 'Int's, left-to-right and strictly.
hashInts :: Int -> [Int] -> Int
hashInts = foldl' mixI

-- | Hash a 'String' as a sequence of character codes. Used only for the
-- kind / state tags below; the inputs are small fixed words.
hashTag :: String -> Int
hashTag = foldl' (\h c -> mixI h (fromEnum c)) 0x9E3779B9

--------------------------------------------------------------------------------
-- Tag hashes for kind/state.
--------------------------------------------------------------------------------

kindCode :: Kind -> Int
kindCode k = case k of
  KFunction    -> 1
  KProjection  -> 2
  KDatatype    -> 3
  KRecord      -> 4
  KConstructor -> 5
  KPostulate   -> 6
  KPrimitive   -> 7
  KOther       -> 8

stateCode :: State -> Int
stateCode s = case s of
  Defined   -> 1
  Postulate -> 2
  Hole      -> 3
  Failed    -> 4

-- | Logarithmic bucket of an out-degree (0 -> 0, 1 -> 1, 2-3 -> 2,
-- 4-7 -> 3, 8+ -> 4).
outDegreeBucket :: Int -> Int
outDegreeBucket d
  | d <= 0   = 0
  | d == 1   = 1
  | d <= 3   = 2
  | d <= 7   = 3
  | otherwise = 4

--------------------------------------------------------------------------------
-- WL refinement (precomputed once across the whole graph)
--------------------------------------------------------------------------------

-- | A 'Vector' indexed by node id, carrying the colour after @k@
-- refinement rounds.
type ColorVec = Vector Int

-- | Initial per-node colour: a hash of (kind, state, degBucket) where the
-- degree is taken from the supplied neighbour function.
initialColors :: Index -> (Int -> IS.IntSet) -> ColorVec
initialColors ix nbr =
  V.generate (idxNodeCount ix) $ \i ->
    let d   = defAt ix i
        deg = IS.size (nbr i)
    in hashInts (hashTag "init")
                [ kindCode (defKind d)
                , stateCode (defState d)
                , outDegreeBucket deg
                ]

-- | One round of WL refinement. For each node, hash @(currentColor,
-- sorted multiset of neighbours' colours)@. Parallelised via 'parMap';
-- each per-node hash is independent and 'V.fromListN' preserves order, so
-- the result is deterministic.
wlStep :: Index -> (Int -> IS.IntSet) -> ColorVec -> ColorVec
wlStep ix nbr prev =
  let !n = idxNodeCount ix
      computeNew !i =
        let !ci     = prev V.! i
            !nbrs   = nbr i
            !sorted = sort [ prev V.! j | j <- IS.toList nbrs ]
        in hashInts (mixI (hashTag "wl") ci) sorted
  in V.fromListN n (parMap rdeepseq computeNew [0 .. n - 1])

-- | Iterate 'wlStep' @k@ times. When @k <= 0@ this is the identity.
refine :: Index -> (Int -> IS.IntSet) -> Int -> ColorVec -> ColorVec
refine ix nbr !k !v0
  | k <= 0    = v0
  | otherwise = refine ix nbr (k - 1) (wlStep ix nbr v0)

--------------------------------------------------------------------------------
-- Fingerprint + weighted Jaccard / Ruzicka similarity
--------------------------------------------------------------------------------

-- | A fingerprint is a multiset of colours stored as @colour -> count@.
type Fingerprint = IM.IntMap Int

-- | Build the fingerprint for a single rooted subtree.
fingerprintAt :: ColorVec -> IS.IntSet -> Fingerprint
fingerprintAt cols sub =
  IS.foldl' bump IM.empty sub
  where
    bump !acc i = IM.insertWith (+) (cols V.! i) 1 acc

-- | Weighted Jaccard. Returns 0 when both fingerprints are empty (treating
-- empty-vs-empty as undefined rather than perfect overlap).
weightedJaccard :: Fingerprint -> Fingerprint -> Double
weightedJaccard a b
  | IM.null a && IM.null b = 0
  | otherwise              =
      let !num = IM.foldlWithKey'
                   (\ !acc k av -> acc + min av (IM.findWithDefault 0 k b))
                   (0 :: Int) a
          !den = IM.foldl' (+) (0 :: Int) a + IM.foldl' (+) (0 :: Int) b - num
      in if den == 0 then 0 else fromIntegral num / fromIntegral den
