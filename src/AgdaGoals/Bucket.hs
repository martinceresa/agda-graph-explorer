{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
-- | Bucket canonicalised goals by hash and rank by bucket size.
--
-- The biggest bucket is the "missing intermediate lemma" candidate —
-- the one combinator that, were it introduced, would discharge the
-- most holes in one stroke. The centroid (first-seen representative)
-- of the bucket is the combinator's type signature. Ranking is by
-- descending bucket size.
module AgdaGoals.Bucket
  ( -- * Buckets
    Bucket(..)
  , GoalOccurrence(..)
  , bucketGoals
  , rankBuckets
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Data.List            ( sortOn )
import qualified Data.Map.Strict      as Map
import           Data.Map.Strict      ( Map )
import           Data.Ord             ( Down(..) )
import           Data.Text            ( Text )
import           Data.Word            ( Word64 )

import           AgdaGoals.Canon      ( CanonicalGoal(..), canonicalizeGoal
                                      , hashCanonical )

-- | One occurrence of a goal somewhere in the source corpus.
data GoalOccurrence = GoalOccurrence
  { occModule  :: !Text
    -- ^ Module name the hole lives in (e.g. @"Holes"@). Carried so
    -- the human report can name examples.
  , occLine    :: !(Maybe Int)
    -- ^ Source line, when the protocol gave us a range.
  , occRawType :: !Text
    -- ^ The raw goal-type string from the wire. Kept for diagnostics
    -- and so the human report can show one representative example.
  } deriving (Show, Eq)

instance NFData GoalOccurrence where
  rnf (GoalOccurrence m l r) = rnf m `seq` rnf l `seq` rnf r

-- | One bucket of canonically-equivalent goals.
data Bucket = Bucket
  { bucketHash        :: !Word64
    -- ^ Hash of 'bucketCanonical'. Stable across runs (see
    -- 'AgdaGoals.Canon.hashCanonical').
  , bucketCanonical   :: !CanonicalGoal
    -- ^ The canonical form every member normalises to.
  , bucketOccurrences :: ![GoalOccurrence]
    -- ^ Insertion-order list of every goal in the bucket. First
    -- element is the centroid.
  , bucketSize        :: !Int
    -- ^ Length of 'bucketOccurrences', maintained alongside it so
    -- ranking doesn't need to recount.
  } deriving (Show)

instance NFData Bucket where
  rnf (Bucket h c os sz) = rnf h `seq` rnf c `seq` rnf os `seq` rnf sz

-- | Bucket a list of (raw type, occurrence) pairs by canonical form.
-- The fold is strict in the accumulator map so memory stays flat
-- across large inputs; occurrence lists are conses (so first-seen is
-- preserved on the head once we reverse).
bucketGoals :: [(Text, GoalOccurrence)] -> [Bucket]
bucketGoals = finalise . foldl' step Map.empty
  where
    step :: Map Word64 (CanonicalGoal, [GoalOccurrence], Int)
         -> (Text, GoalOccurrence)
         -> Map Word64 (CanonicalGoal, [GoalOccurrence], Int)
    step !acc (raw, occ) =
      let !c   = canonicalizeGoal raw
          !h   = hashCanonical c
          !occ' = occ
      in Map.alter (Just . upd c occ') h acc

    upd c occ Nothing                  = (c, [occ], 1)
    upd _ occ (Just (c, occs, !sz))    = (c, occ : occs, sz + 1)

    finalise m =
      [ Bucket
          { bucketHash        = h
          , bucketCanonical   = c
          , bucketOccurrences = reverse occs
          , bucketSize        = sz
          }
      | (h, (c, occs, sz)) <- Map.toList m
      ]

-- | Rank by descending bucket size, with stable secondary keys
-- (hash, canonical form) so the output is deterministic across
-- @+RTS -N1@ / @+RTS -NK@ — see the determinism acceptance test in
-- CLAUDE.md.
rankBuckets :: [Bucket] -> [Bucket]
rankBuckets = sortOn key
  where
    key b = ( Down (bucketSize b)
            , bucketHash b
            , unCanonical (bucketCanonical b)
            )
