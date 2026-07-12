{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Small helpers shared across the analyses: unqualified-name extraction,
-- the "foundational prelude" and theorem-tag heuristics, the terminal-node
-- set, the @--exclude-name-regex@ → node-id set, the Apriori itemset
-- primitives, and the budget reaper. The single source of truth for these,
-- so the analyses cannot drift.
module AgdaOptimization.Common
  ( lastSegment
  , isFoundationalModule
  , notFoundational
  , isTagged
  , terminals
  , computeExcludedSet
  , externalsSummaryHasRows
  , chunksOf
  , shortName
  , showD
  , orderPair
  , orderTriple
  , computeTopFreqItems
  , withReaper
  ) where

import           Control.Concurrent ( forkIO, killThread, threadDelay )
import           Control.Exception  ( bracket )
import           Data.IORef         ( IORef, writeIORef )
import           Data.List          ( sort, sortOn )
import           Data.Ord           ( Down(..) )
import           Data.Text          ( Text )
import qualified Data.Text          as T
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS
import qualified Data.Map.Strict    as Map
import qualified Data.Vector        as V
import           Text.Regex.TDFA    ( Regex, makeRegex, matchTest )

import           AgdaGraph.Index    ( Index(..), defAt )
import           AgdaGraph.Schema   ( Definition(..), ExternalsSummary(..) )

-- | Trailing dot-component of a fully-qualified QName ("the unqualified
-- name"). @a.b.c@ ↦ @c@; a name with no dot is returned unchanged.
lastSegment :: Text -> Text
lastSegment !x = case T.breakOnEnd "." x of
  (_, suf) | T.null suf -> x
           | otherwise  -> suf

-- | Is this module part of Agda's builtin / primitive prelude (the trusted
-- base that analyses treat as foundational)?
isFoundationalModule :: Text -> Bool
isFoundationalModule m =
     "Agda.Builtin."  `T.isPrefixOf` m
  || "Agda.Primitive" == m
  || "Agda.Primitive." `T.isPrefixOf` m

-- | A definition that does /not/ live in the foundational prelude.
notFoundational :: Definition -> Bool
notFoundational d = not (isFoundationalModule (defModule d))

-- | Theorem-name heuristic: case-insensitive @-thm@ suffix, @theorem-@
-- prefix, exact @theorem@, or @.theorem@ infix anywhere in the qualified
-- name.
isTagged :: Text -> Bool
isTagged !t =
  let lt = T.toLower (lastSegment t)
  in T.isSuffixOf "-thm" lt
  || T.isPrefixOf "theorem-" lt
  || lt == "theorem"
  || T.isInfixOf ".theorem" (T.toLower t)

-- | Nodes with no inbound edges.
terminals :: Index -> IS.IntSet
terminals ix =
  let !n  = idxNodeCount ix
      !rv = idxReverse ix
      go !acc i
        | i >= n = acc
        | otherwise =
            let inbound = IM.findWithDefault IS.empty i rv
            in if IS.null inbound then go (IS.insert i acc) (i + 1)
                                  else go acc (i + 1)
  in go IS.empty 0

-- | Node ids whose unqualified name matches the @--exclude-name-regex@
-- pattern. An empty pattern excludes nothing.
computeExcludedSet :: Index -> Text -> IS.IntSet
computeExcludedSet !ix !pat
  | T.null pat = IS.empty
  | otherwise =
      let !re = makeRegex (T.unpack pat) :: Regex
          test :: Text -> Bool
          test n = matchTest re (T.unpack (lastSegment n))
      in V.foldl'
           (\ !acc d ->
              if test (defName d)
                then IS.insert (defId d) acc
                else acc)
           IS.empty
           (idxDefs ix)

-- | Does the wire 'ExternalsSummary' carry any postulate rows? 'Nothing',
-- or an all-empty per-module map, ⇒ 'False'.
externalsSummaryHasRows :: Maybe ExternalsSummary -> Bool
externalsSummaryHasRows Nothing                        = False
externalsSummaryHasRows (Just (ExternalsSummary _ pm)) =
  any (not . null) (Map.elems pm)

-- | Split a list into chunks of size @k@ in input order. @k <= 0@ is
-- clamped to 1 to avoid an infinite loop; empty input ⇒ empty output.
chunksOf :: Int -> [a] -> [[a]]
chunksOf k xs0
  | k <= 0    = chunksOf 1 xs0
  | otherwise = go xs0
  where
    go [] = []
    go xs = let (h, t) = splitAt k xs in h : go t

-- | Unqualified name of definition @i@ (final dot-component of its QName).
shortName :: Index -> Int -> Text
shortName ix i = lastSegment (defName (defAt ix i))

-- | A @Double@ rendered via its derived 'Show'. Named so call sites read as
-- "show a metric" and the numeric format lives in one place.
showD :: Double -> String
showD = show

-- | Canonical @(a, b)@ with @a <= b@.
orderPair :: Int -> Int -> (Int, Int)
orderPair a b
  | a <= b    = (a, b)
  | otherwise = (b, a)

-- | Canonical @(a, b, c)@ with @a <= b <= c@.
orderTriple :: Int -> Int -> Int -> (Int, Int, Int)
orderTriple a b c = case sort [a, b, c] of
  [x, y, z] -> (x, y, z)
  _         -> (a, b, c)  -- unreachable: sort of a 3-list yields a 3-list

-- | The item ids in the top @pct%@ of the support-count distribution, ties
-- at the boundary all included (everything with @count >= threshold@).
-- @pct <= 0@ ⇒ empty (filter disabled). The Apriori top-frequency exclusion
-- shared by @basket@ and @concept-bundle@; the ceiling excludes at least one
-- item when @pct > 0@.
computeTopFreqItems :: Double -> IM.IntMap Int -> IS.IntSet
computeTopFreqItems pct itemCounts
  | pct <= 0    = IS.empty
  | nItems == 0 = IS.empty
  | otherwise   = IS.fromList topItems
  where
    nItems    = IM.size itemCounts
    !nExclude = min nItems (max 1 (ceiling (pct / 100 * fromIntegral nItems)))
    sortedDesc = sortOn (Down . snd) (IM.toList itemCounts)
    topItems = map fst (take nExclude sortedDesc)

-- | Run @act@ with a background reaper that flips @deadlineRef@ to 'True'
-- after @secs@ (a soft budget the analysis polls). 'bracket' kills the
-- reaper before returning so no stale thread writes into a dead ref.
-- @secs <= 0@ runs @act@ with no reaper.
withReaper :: Double -> IORef Bool -> IO a -> IO a
withReaper secs deadlineRef act
  | secs <= 0 = act
  | otherwise =
      let !micros = floor (secs * 1e6) :: Int
      in bracket
           (forkIO (threadDelay micros >> writeIORef deadlineRef True))
           killThread
           (const act)
