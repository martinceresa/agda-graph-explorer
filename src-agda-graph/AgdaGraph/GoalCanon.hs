{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
-- | Canonicalise the goal-type strings produced by
-- @agda --interaction-json@ so that two clearly-equivalent goals
-- bucket together, plus the conclusion-/token-extraction helpers the
-- @agda-explore@ daemon's @find_lemma@ tool ranks goals with.
--
-- This module lives in the shared @agda-graph@ library (rather than the
-- @agda-goals@ executable) so both @agda-goals@ (bucketing) and
-- @agda-explore@ (free-text lemma search) import one definition of the
-- vendored-Murmur64 'hashString' — see the "@hashString@ is vendored
-- Murmur64" gotcha in @CLAUDE.md@. @AgdaGoals.Canon@ is now a thin
-- re-export of this module.
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
module AgdaGraph.GoalCanon
  ( -- * Canonical form
    CanonicalGoal(..)
  , canonicalizeGoal

    -- * Hash
  , hashCanonical

    -- * Conclusion / token extraction (find_lemma)
  , conclusionOf
  , identTokens
  , tokenJaccard
  ) where

import           Control.DeepSeq  ( NFData(..) )
import           Data.Char        ( isSpace, isLower, isUpper, isAlphaNum )
import           Data.Set         ( Set )
import qualified Data.Set         as Set
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
          -- 'span identChar' is non-empty here (its head is 'c', which
          -- 'identStart' just matched), so the first-char test reads 'c'.
          let (tok, rest) = span identChar s
          in if isLower c && c < '\x80'
               then case Map.lookup tok m of
                 Just placeholder -> placeholder ++ go m n rest
                 Nothing          ->
                   let placeholder = 'v' : show n
                       m'          = Map.insert tok placeholder m
                   in placeholder ++ go m' (n + 1) rest
               else tok ++ go m n rest
      | otherwise = c : go m n (drop 1 s)

-- | First character of an identifier token.
identStart :: Char -> Bool
identStart ch = isAlphaNum ch || ch == '_'

-- | Subsequent characters of an identifier token.
identChar :: Char -> Bool
identChar ch = isAlphaNum ch || ch == '\'' || ch == '_'

----------------------------------------------------------------------
-- Conclusion / token extraction (find_lemma).

-- | The /conclusion/ (result type) of a (rendered or canonicalised)
-- type string: everything after the /last top-level/ function arrow.
-- Arrows nested inside balanced @()@\/@{}@\/@[]@ groups do not split, so
-- @(A → B) → C@ yields @C@ (not @B@). Splits on both the Unicode arrow
-- @→@ (U+2192, what @--interaction-json@ emits) and the ASCII @->@
-- (what some elaborated\/source signatures use). A type with no
-- top-level arrow (e.g. a bare @Even n@) is returned trimmed and
-- unchanged.
--
-- Bracket-depth tracking mirrors the @atomize@/@desugarLiterals@ delta
-- counter in @AgdaMcp.Query@: we scan left-to-right, track depth over
-- the three bracket pairs, and remember the offset just /after/ the
-- last depth-0 arrow seen.
conclusionOf :: Text -> Text
conclusionOf t = T.strip (go 0 (T.unpack t) "" "")
  where
    -- @go depth input lastConclusion acc@: @acc@ accumulates the segment
    -- since the most recent top-level arrow (built reversed); when we hit
    -- a top-level arrow we discard @lastConclusion@/@acc@ and start a
    -- fresh @acc@. At end-of-input the surviving @acc@ is the conclusion.
    go :: Int -> String -> String -> String -> Text
    go _ []           _    acc = T.pack (reverse acc)
    go d s@(c : rest) lastC acc
      | d <= 0, Just s' <- arrowAt s = go 0 s' "" ""
      | c `elem` ("({[" :: String)   = go (d + 1) rest lastC (c : acc)
      | c `elem` (")}]" :: String)   = go (d - 1) rest lastC (c : acc)
      | otherwise                    = go d rest lastC (c : acc)
    -- Match a leading arrow (Unicode or ASCII) and return the remainder.
    arrowAt ('\x2192' : r) = Just r
    arrowAt ('-' : '>' : r) = Just r
    arrowAt _               = Nothing

-- | The /name/ tokens of a (canonicalised) type string: the identifier
-- and operator runs that carry discriminating information for matching,
-- dropping the alpha-renamed / bound /lowercase variables/ (which a
-- canonicaliser turns into @v0@\/@v1@\/… and which say nothing about
-- /what/ a type is about). Two flavours of token are scanned:
--
--   * /identifier/ runs (per 'canonicalizeGoal''s 'identStart' \/
--     'identChar', so the boundary matches the alpha-renamer exactly):
--     kept when the run begins with an uppercase letter, a non-ASCII
--     letter, or contains any uppercase letter — i.e. a type\/
--     constructor\/qualified name like @List@, @Nat@, @≡@-free names —
--     and dropped when it is a bare lowercase ASCII run (a @v0@
--     placeholder or surviving bound var). Qualified names like
--     @Data.List@ split on the dot into per-component tokens, so @List@
--     survives even behind a lowercase qualifier.
--
--   * /operator/ runs: maximal runs of symbol characters that are not
--     whitespace, brackets, the dot, or alphanumerics — e.g. @∷@, @≡@,
--     @++@, @→@. These are highly discriminating for lemma conclusions
--     (an equation @… ≡ …@ vs. a function @… → …@), so they are kept
--     verbatim. (The arrow @→@ rarely survives into a /conclusion/ since
--     'conclusionOf' splits on top-level arrows, but nested ones do.)
identTokens :: Text -> Set Text
identTokens = Set.fromList . map T.pack . scan . T.unpack
  where
    scan [] = []
    scan s@(c : _)
      | identStart c =
          let (tok, rest) = span identChar s
          in (if keepIdent tok then (tok :) else id) (scan rest)
      | isOpChar c =
          let (tok, rest) = span isOpChar s
          in tok : scan rest
      | otherwise = scan (drop 1 s)
    -- Keep an identifier token unless it is a bare lowercase-ASCII run
    -- (an alpha-rename placeholder or surviving bound var).
    keepIdent []          = False
    keepIdent tok@(c : _) =
      isUpper c
        || not (isAsciiLower c || isDigit' c || c == '_')   -- non-ASCII letter
        || any isUpper tok                                   -- mixed-case name
    -- A symbol character: anything that is not whitespace, a bracket, a
    -- dot (qualified-name separator), or an identifier character.
    isOpChar c =
      not (isSpace c)
        && not (identStart c)
        && c `notElem` ("()[]{}." :: String)
    isAsciiLower c = isLower c && c < '\x80'
    isDigit' c = c >= '0' && c <= '9'

-- | Jaccard similarity of two token sets: @|A ∩ B| / |A ∪ B|@. Two empty
-- sets are defined to be @0@ (no shared evidence ⇒ no match), so an
-- empty goal conclusion never spuriously scores @1.0@ against another
-- empty conclusion.
tokenJaccard :: Set Text -> Set Text -> Double
tokenJaccard a b
  | Set.null a && Set.null b = 0
  | otherwise =
      let inter = Set.size (Set.intersection a b)
          uni   = Set.size (Set.union a b)
      in if uni == 0 then 0 else fromIntegral inter / fromIntegral uni
