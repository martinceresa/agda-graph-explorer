{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Shared forced-by-elaborator suppressor.
--
-- Detects /per-case-unfold families/ — groups of items whose
-- unqualified name matches @^(stem)-(\d+)$@ with at least two members
-- sharing the same stem (e.g. @VoteBlock-0@, @VoteBlock-1@,
-- @VoteBlock-2@, or Agda's stdlib @_—→⟨_⟩_-0@, @_—→⟨_⟩_-1@, …). These
-- are Agda's per-clause unfoldings of state-update functions or
-- equational-reasoning operators; the co-occurrence is forced by the
-- elaborator, not refactor-actionable.
--
-- Used by:
--   * @AgdaOptimization.Basket@ — drops co-usage rules whose bundle
--     is dominated by one family.
--   * @AgdaOptimization.ConceptBundle@ — same, on signature-provenance
--     itemsets.
--
-- Add more callers here rather than duplicating the parser.
module AgdaOptimization.FamilyFilter
  ( -- * Family identification
    parseCaseUnfold
  , familyOf

    -- * Forced-bundle decision
  , isForcedByFamily
  ) where

import qualified Data.Map.Strict   as Map
import           Data.Map.Strict   ( Map )
import           Data.List         ( foldl' )
import qualified Data.Text         as T
import           Data.Text         ( Text )

import           AgdaGraph.Index   ( Index, defAt )
import           AgdaGraph.Schema  ( Definition(..) )

-- | Strip a qname to its last dot-component, then try to split it into
-- @(stem, idx)@ matching @^(.+)-(\\d+)$@. Returns 'Nothing' for items
-- that aren't part of a numeric-suffix family.
familyOf :: Index -> Int -> Maybe Text
familyOf ix i =
  let !short = lastDotComponent (defName (defAt ix i))
  in case parseCaseUnfold (T.unpack short) of
       Just (stem, _) -> Just (T.pack stem)
       Nothing        -> Nothing

-- | Match @<stem>-<digits>@ at the end of a short name. Right-anchored;
-- the stem may itself contain dashes (e.g. @cong-of-foo-2@ → stem
-- @cong-of-foo@, idx @2@), but the suffix must be a non-empty digit
-- run, which is what Agda emits for per-clause unfoldings.
parseCaseUnfold :: String -> Maybe (String, Int)
parseCaseUnfold s =
  let (revTail, revRest) = span isDigitChar (reverse s)
  in case revTail of
       []      -> Nothing                       -- no trailing digits
       _ | null revRest                  -> Nothing  -- whole name is digits
         | head revRest /= '-'           -> Nothing  -- no dash separator
         | length revRest < 2            -> Nothing  -- stem must be non-empty
         | otherwise ->
             let !stem = reverse (drop 1 revRest)
                 !idxS = reverse revTail
             in case reads idxS of
                  [(n :: Int, "")] -> Just (stem, n)
                  _                -> Nothing
  where
    isDigitChar c = c >= '0' && c <= '9'

-- | The bundle decision. Given a list of item ids, group them by
-- detected family. Returns 'True' (suppress) when:
--
--   * The bundle has ≥ 2 items overall (a singleton bundle has no
--     "co-firing" to claim).
--   * The largest detected family within the bundle contributes
--     ≥ 2 items (so a stray @Foo-0@ next to unrelated items doesn't
--     trigger).
--   * That family covers ≥ @fraction@ of the bundle (default in
--     callers: 0.5 — a majority).
--
-- Family membership is counted **two ways**:
--
--   1. Items whose own name matches @<stem>-<digits>@ — these credit
--      the @stem@.
--   2. Items whose own name **is** a stem already present in the
--      bundle from a @<stem>-N@ neighbour — these credit the same
--      @stem@. This catches the @{mk, mk-1}@ pair (one bare stem +
--      one numeric suffix), which is still per-case-unfold pollution
--      but missed by a suffix-only detector.
isForcedByFamily :: Index -> Double -> [Int] -> Bool
isForcedByFamily ix fraction items =
  let !total = length items
      -- First pass: stems contributed by items with the -N suffix.
      !stems = foldl' addStem Map.empty items
      addStem :: Map Text Int -> Int -> Map Text Int
      addStem !acc !item = case familyOf ix item of
        Nothing  -> acc
        Just fam -> Map.insertWith (+) fam 1 acc
      -- Second pass: items whose bare name equals one of the stems
      -- discovered in pass 1 also count toward that family.
      !groups = foldl' (addBareStem ix stems) stems items
      !maxFam = if Map.null groups
                  then 0
                  else maximum (Map.elems groups)
  in total >= 2
       && maxFam >= 2
       && fromIntegral maxFam >= fraction * fromIntegral total
  where
    addBareStem :: Index -> Map Text Int -> Map Text Int -> Int -> Map Text Int
    addBareStem idx' !sset !acc !item = case familyOf idx' item of
      Just _  -> acc       -- already counted in pass 1
      Nothing ->
        let !short = lastDotComponent (defName (defAt idx' item))
        in if Map.member short sset
             then Map.insertWith (+) short 1 acc
             else acc

----------------------------------------------------------------------
-- Helpers.

-- | Last dot-component of a dotted qname. @"Foo.Bar.baz"@ → @"baz"@,
-- @"baz"@ → @"baz"@. Used to expose just the unqualified name to the
-- per-case-unfold pattern matcher.
lastDotComponent :: Text -> Text
lastDotComponent t =
  let (_, tl) = T.breakOnEnd "." t
  in if T.null tl then t else tl
