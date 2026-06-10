{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | Canonicalise the goal-type strings produced by
-- @agda --interaction-json@ so that two clearly-equivalent goals
-- bucket together.
--
-- The @--interaction-json@ protocol only ships the /rendered/ goal
-- type as a 'Text' (e.g. @"Nat → Nat"@), not the internal 'Term', so
-- this is a /textual/ canonicalisation: whitespace normalisation,
-- comment stripping, and alpha-renaming of bound variables to
-- de-Bruijn-style placeholders. It buckets goals that differ only in
-- editor whitespace and choice of variable names, but /will/
-- under-cluster compared to a structural canonicaliser (two goals
-- that normalise to the same 'Term' but print differently land in
-- different buckets).
module AgdaGoals.Canon
  ( -- * Canonical form
    CanonicalGoal(..)
  , canonicalizeGoal

    -- * Hash
  , hashCanonical
  ) where

import           Control.DeepSeq  ( NFData(..) )
import           Data.Char        ( isSpace, isLower, isAlphaNum )
import           Data.Text        ( Text )
import qualified Data.Text        as T
import           Data.Word        ( Word64 )
import qualified Data.Map.Strict  as Map

import           Data.Digest.Murmur64 ( asWord64, hash64 )

-- | Stable 64-bit string hash. Vendored from @murmur-hash@ to keep this
-- repo Agda-free: this is byte-for-byte the definition of Agda's
-- @Agda.Utils.Hash.hashString@ (@asWord64 . hash64@), so canonical-goal
-- buckets stay identical to the pre-split agda-goals output and remain
-- cross-referenceable with @agda-deps@'s @hashQName@.
hashString :: String -> Word64
hashString = asWord64 . hash64

-- | Canonical form of a rendered goal-type string. The 'Eq' / 'Ord'
-- instances are the operative comparison — the underlying 'Text' is
-- an implementation detail.
newtype CanonicalGoal = CanonicalGoal { unCanonical :: Text }
  deriving (Eq, Ord, Show)

instance NFData CanonicalGoal where
  rnf (CanonicalGoal t) = rnf t

-- | Canonicalise one rendered goal-type string:
--
--   1. Strip block comments @{- … -}@ (greedy, non-nested — the
--      protocol shouldn't emit nested block comments in goal types,
--      but if it does we'll under-canonicalise rather than crash).
--   2. Strip line comments @-- …\n@.
--   3. Collapse all unicode whitespace into single ASCII spaces.
--   4. Trim leading / trailing whitespace.
--   5. Alpha-rename free identifiers (lowercase ASCII alphanumeric)
--      to @v0, v1, …@ in left-to-right occurrence order, collapsing
--      e.g. @λ x → x@ and @λ y → y@ to the same shape.
--
-- Step 5 only renames tokens whose first character is a lowercase
-- ASCII letter, so 'Nat', 'List', '∷', and qualified names like
-- 'Data.List' all survive verbatim. Single-character identifiers like
-- @a@, @b@, @c@ that are actually /uses/ of in-scope type variables
-- also get rewritten.
canonicalizeGoal :: Text -> CanonicalGoal
canonicalizeGoal raw =
  let !s1 = stripBlockComments raw
      !s2 = stripLineComments  s1
      !s3 = normaliseWhitespace s2
      !s4 = T.strip s3
      !s5 = alphaRename s4
  in CanonicalGoal s5

-- | Stable 64-bit fingerprint of a canonical goal. Uses the local
-- 'hashString' (the same Murmur64 hash @agda-deps@'s @TermCanon.hashOf@
-- and @Deps.hashQName@ use) so any downstream consumer that already keys
-- on @hashQName@ can cross-reference.
hashCanonical :: CanonicalGoal -> Word64
hashCanonical (CanonicalGoal t) = fromIntegral (hashString (T.unpack t))

----------------------------------------------------------------------
-- Implementation.

-- | Strip @{- … -}@ blocks (non-nested).
stripBlockComments :: Text -> Text
stripBlockComments t = case T.breakOn "{-" t of
  (pre, rest)
    | T.null rest -> pre
    | otherwise   ->
        let after = T.drop 2 rest
        in case T.breakOn "-}" after of
             (_, end)
               | T.null end -> pre  -- unterminated; drop tail
               | otherwise  -> pre <> stripBlockComments (T.drop 2 end)

stripLineComments :: Text -> Text
stripLineComments = T.unlines . map dropLine . T.lines
  where
    dropLine l = case T.breakOn "--" l of
      (pre, _) -> pre

normaliseWhitespace :: Text -> Text
normaliseWhitespace = T.pack . go . T.unpack
  where
    go [] = []
    go (c:cs)
      | isSpace c = ' ' : go (dropWhile isSpace cs)
      | otherwise = c   : go cs

-- | Lowercase-leading alphanumeric runs get rewritten to @v0, v1, …@
-- in first-occurrence order. Non-identifier characters and tokens
-- starting with uppercase / non-ASCII characters pass through.
alphaRename :: Text -> Text
alphaRename = T.pack . go Map.empty (0 :: Int) . T.unpack
  where
    -- Always consume an identifier chunk atomically first. Only the
    -- chunk's /first/ character decides whether it's a candidate for
    -- alpha-renaming; mid-identifier characters never split a token.
    go _   _ []       = []
    go !m !n s@(c:_)
      | identStart c =
          let (tok, rest) = span identChar s
          in if isLower (head tok) && head tok < '\x80'
               then case Map.lookup tok m of
                 Just placeholder -> placeholder ++ go m n rest
                 Nothing          ->
                   let placeholder = 'v' : show n
                       m'          = Map.insert tok placeholder m
                   in placeholder ++ go m' (n + 1) rest
               else tok ++ go m n rest
      | otherwise = c : go m n (drop 1 s)

    identStart ch = isAlphaNum ch || ch == '_'
    identChar  ch = isAlphaNum ch || ch == '\'' || ch == '_'
