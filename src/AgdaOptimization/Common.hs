{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Small graph / name helpers shared across the analyses: unqualified-name
-- extraction, the "foundational prelude" and theorem-tag heuristics, the
-- terminal-node set, and the @--exclude-name-regex@ → node-id set.
-- Previously each analysis carried its own (often "Mirrors X"-annotated)
-- copy; this is the single source of truth so they cannot drift.
module AgdaOptimization.Common
  ( lastSegment
  , isFoundationalModule
  , notFoundational
  , isTagged
  , terminals
  , computeExcludedSet
  ) where

import           Data.Text          ( Text )
import qualified Data.Text          as T
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS
import qualified Data.Vector        as V
import           Text.Regex.TDFA    ( Regex, makeRegex, matchTest )

import           AgdaGraph.Index    ( Index(..) )
import           AgdaGraph.Schema   ( Definition(..) )

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
