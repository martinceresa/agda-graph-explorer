{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Pure text edits for the repair loop, and the spec-preservation predicate.
--
-- Repair is __import-only__: the sole edit inserts an @open import@ line
-- (renames were removed — R25 — because a rename can rewrite a theorem's
-- meaning to make a scope error vanish; repair now fails with a spelling
-- suggestion instead). Spec preservation is therefore structural — an
-- inserted import never touches an existing line — and 'signatures' remains
-- the invariant the loop checks after each edit as a backstop.
module AgdaRepair.Edit
  ( Edit(..)
  , applyEdits
  , insertImport
  , signatures
  , isSigLine
  ) where

import           Data.Char   (isSpace)
import           Data.Text   (Text)
import qualified Data.Text   as T

-- | One repair edit. A 'Candidate' (see "AgdaRepair.Strategy") is a bundle of
-- these applied and validated together. Currently a single constructor, kept
-- as a sum so the bundle vocabulary can grow without touching call sites.
data Edit
  = EAddImport !Text        -- ^ an @open import M using (…)@ line to insert.
  deriving (Eq, Show)

-- | Apply a bundle in order. 'Nothing' if the net effect is a no-op (e.g. the
-- import was already present) — the loop treats that as "candidate made no
-- change" and moves on.
applyEdits :: Text -> [Edit] -> Maybe Text
applyEdits t es =
  let t' = foldl' step t es
  in if t' == t then Nothing else Just t'
  where
    step acc (EAddImport l) = insertImport acc l

-- | Insert an import line after the last existing @open import@ / @import@
-- (else after the @module … where@ header, else at the top). A no-op if the
-- exact line is already present. Preserves the file's trailing newline.
insertImport :: Text -> Text -> Text
insertImport src line
  | line `elem` ls = src
  | otherwise      = rejoin (insertAt idx line ls)
  where
    ls  = T.lines src
    idx = case [ i | (i, l) <- zip [0 ..] ls, isImport l ] of
            [] -> case [ i | (i, l) <- zip [0 ..] ls, "module " `T.isPrefixOf` l ] of
                    (m:_) -> m + 1
                    []    -> 0
            is -> last is + 1
    isImport l = "open import" `T.isPrefixOf` l || "import " `T.isPrefixOf` l
    insertAt n x xs = let (a, b) = splitAt n xs in a ++ [x] ++ b
    rejoin xs = T.intercalate "\n" xs <> (if "\n" `T.isSuffixOf` src then "\n" else "")

-- | The top-level @name : Type@ signature lines — the theorem statements the
-- repair loop must leave byte-identical. The loop asserts this set is
-- unchanged after every accepted edit (an import insertion trivially
-- preserves it — it adds no signature line and reorders nothing).
signatures :: Text -> [Text]
signatures = filter isSigLine . T.lines

-- | A top-level @name : Type@ line: starts in column 0 with a single-token
-- left-hand side followed by a colon.
isSigLine :: Text -> Bool
isSigLine l =
  case T.uncons l of
    Just (c, _) | not (isSpace c) ->
      let (lhs, rhs) = T.breakOn ":" l
      in not (T.null rhs) && length (T.words lhs) == 1 && not (T.null (T.strip lhs))
    _ -> False
