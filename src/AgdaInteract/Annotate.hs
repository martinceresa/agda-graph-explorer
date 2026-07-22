{-# LANGUAGE OverloadedStrings #-}
-- | The @agda-auto@ annotation channel: a versioned marker left
-- /inside/ an unsolved hole recording what was tried and which lemmas to
-- reach for, so the file itself becomes the handoff document. Pure — no IO,
-- no State — so the offline suite pins the whole grammar.
--
-- Shape (the marker is a block comment carried inside the hole braces; Agda
-- treats a hole's body as free text, so @{! user {- agda-auto/1 … -} !}@ loads
-- as an ordinary interaction hole — verified on Agda 2.8):
--
-- > {! <preserved user content> {- agda-auto/1
-- >   ⊢ n + zero ≡ n
-- >   tried: plain 5s + 4 hints
-- >   try: +-identityʳ, +-comm
-- >   import: open import Data.Nat.Properties using (+-suc)
-- > -} !}
--
-- Invariants (all pinned in test/Spec.hs):
--
--   * __Idempotent.__ @'annotateHole' ('annotateHole' h a) a == 'annotateHole' h a@ —
--     'annotateHole' strips any prior @agda-auto/N@ block first, so a re-run
--     replaces, never stacks. The marker carries no timestamp / run-varying
--     text, so a second identical run is a zero diff.
--   * __Comment-safe.__ Field values are 'sanitize'd: interior @{-@/@-}@ become
--     the look-alike U+2010 forms and newlines collapse, so the block can never
--     unbalance Agda's /nesting/ comment lexer ('commentBalanced' is the oracle).
--   * __User content preserved.__ Whatever the user wrote in the hole survives
--     annotate→strip verbatim.
--
-- The @/1@ is the payload version; 'stripMarker' / 'parseMarker' key off the
-- version-agnostic @{- agda-auto/@ prefix, so a future richer payload (a
-- @bridge:@ or @refuted:@ field, say) is forward-compatible.
module AgdaInteract.Annotate
  ( Annotation(..)
  , renderMarker
  , parseMarker
  , stripMarker
  , annotateHole
  , holeHints
  , sanitize
  , commentBalanced
  ) where

import           Data.List  ( nub )
import           Data.Maybe ( fromMaybe, listToMaybe )
import           Data.Text  ( Text )
import qualified Data.Text  as T

import           AgdaGraph.GoalCanon ( baseComponent )

-- | The v1 marker payload. All fields are already in display form; the render
-- step only sanitizes + truncates, it does not restructure.
data Annotation = Annotation
  { annGoalType :: !Text    -- ^ the goal type (@⊢@), whitespace-collapsed + truncated on render.
  , annTried    :: !Text    -- ^ what was attempted (@tried:@), e.g. @"plain 5s + 4 hints"@.
  , annTry      :: ![Text]  -- ^ in-scope lemma names to try (@try:@).
  , annImports  :: ![Text]  -- ^ ready-to-paste import lines for out-of-scope hints (@import:@).
  } deriving (Eq, Show)

-- | The version-agnostic marker opener; 'stripMarker' / 'parseMarker' find any
-- @agda-auto/N@ block by it.
markerOpenPrefix :: Text
markerOpenPrefix = "{- agda-auto/"

-- | The current payload-version header.
markerTag :: Text
markerTag = "agda-auto/1"

-- | Max displayed goal-type length (then truncated with @…@).
goalTypeMax :: Int
goalTypeMax = 120

-- | Render the marker block (the @{- agda-auto/1 … -}@; 'annotateHole' wraps it
-- into the hole). Empty fields are omitted; the goal-type line is always
-- present. Deterministic layout (fixed 2-space indent) — no run-varying text.
renderMarker :: Annotation -> Text
renderMarker ann = T.intercalate "\n" (open : map ("  " <>) fields ++ [close])
  where
    open  = "{- " <> markerTag
    close = "-}"
    fields = concat
      [ [ "⊢ " <> truncateType (sanitize (annGoalType ann)) ]
      , [ "tried: "  <> sanitize (annTried ann)               | not (T.null (annTried ann)) ]
      , [ "try: "    <> sanitize (T.intercalate ", " (annTry ann)) | not (null (annTry ann)) ]
      , [ "import: " <> sanitize (T.intercalate "; " (annImports ann)) | not (null (annImports ann)) ]
      ]

-- | Parse the first @agda-auto/N@ marker out of arbitrary text (a hole body).
-- Forward-lenient: recognised field lines are read, everything else ignored;
-- 'Nothing' only when no marker is present. Inverse of 'renderMarker' on a
-- normalised 'Annotation' (render is lossy — it collapses whitespace and
-- truncates — so the round-trip holds for already-normalised values).
parseMarker :: Text -> Maybe Annotation
parseMarker t =
  let (_, rest) = T.breakOn markerOpenPrefix t
  in if T.null rest
       then Nothing
       else
         let body  = fst (T.breakOn "-}" rest)         -- marker header .. first "-}"
             ls     = map T.strip (T.lines body)
             field pfx = listToMaybe
               [ T.strip (T.drop (T.length pfx) l) | l <- ls, pfx `T.isPrefixOf` l ]
         in Just Annotation
              { annGoalType = fromMaybe "" (field "⊢ ")
              , annTried    = fromMaybe "" (field "tried: ")
              , annTry      = maybe [] (splitList ", ") (field "try: ")
              , annImports  = maybe [] (splitList "; ") (field "import: ")
              }
  where
    splitList sep s = filter (not . T.null) (map T.strip (T.splitOn sep s))

-- | Remove every @agda-auto/N@ block from a hole body, then trim. Total and
-- lenient: an unterminated marker (no @-}@) is dropped to end of text.
stripMarker :: Text -> Text
stripMarker = T.strip . go
  where
    go t = case T.breakOn markerOpenPrefix t of
      (before, rest)
        | T.null rest -> t
        | otherwise ->
            let afterOpen = T.drop (T.length markerOpenPrefix) rest
                tailAfter = case T.breakOn "-}" afterOpen of
                              (_, r) | T.null r  -> ""            -- unterminated → drop to end
                                     | otherwise -> T.drop 2 r    -- text after "-}"
            in go (before <> tailAfter)                          -- strip any further markers

-- | Rewrite a hole's full source text (@{! … !}@ or a bare @?@, possibly
-- already carrying a marker) into an annotated hole. The user's content is
-- preserved (minus any prior marker); a bare @?@ is rewritten to the braced
-- form (a one-way, semantically-identical change — a @?@ cannot carry text).
annotateHole :: Text -> Annotation -> Text
annotateHole oldHole ann =
  let user   = stripMarker (holeInner oldHole)
      marker = renderMarker ann
      body   = if T.null user then marker else user <> " " <> marker
  in "{! " <> body <> " !}"

-- | Candidate Mimer-hint names read out of a hole's full text (the read side
-- of the channel): the identifiers the user wrote (their explicit
-- intent, first) followed by a prior marker's @try:@ list, deduped. Qualified
-- names are reduced to their base component — a qualified name aborts
-- @Cmd_autoOne@, and scope resolution keys off the base anyway. Lenient:
-- unparseable content simply yields fewer names, never an error. (Mimer does
-- NOT read hole contents natively on Agda 2.8 — verified — so these must be
-- seeded explicitly by the caller.)
holeHints :: Text -> [Text]
holeHints holeText =
  nub (userIdents (stripMarker (holeInner holeText))
         ++ maybe [] annTry (parseMarker holeText))

-- | Identifier-like tokens of a hole's user content. Mixfix names (@_+_@,
-- @+-comm@) survive; qualifiers are stripped; holes / wildcards dropped.
userIdents :: Text -> [Text]
userIdents = filter keep . map (baseComponent . T.strip) . tokenize
  where
    tokenize = concatMap (T.split isSep) . T.words
    isSep c  = c `elem` ("()[]{};,@" :: [Char])
    keep t   = not (T.null t) && t /= "?" && t /= "_"

-- | The content between a hole's delimiters — @""@ for a bare @?@, the inner
-- text for @{! … !}@. Lenient: an unrecognised shape is treated as inner text.
holeInner :: Text -> Text
holeInner raw
  | h == "?"                                       = ""
  | "{!" `T.isPrefixOf` h && "!}" `T.isSuffixOf` h = T.strip (T.dropEnd 2 (T.drop 2 h))
  | otherwise                                      = h
  where h = T.strip raw

-- | Make a field value safe to embed in @{! … {- value -} … !}@: neutralise
-- comment delimiters (so it can never open/close the block comment) AND the
-- hole delimiters (so an interior @!}@ can never close the hole early), then
-- collapse all whitespace to single spaces. @{-@/@-}@ become the
-- visually-identical, lexically-inert U+2010 (hyphen) forms; the hole
-- delimiters @{!@/@!}@ are broken with a space.
sanitize :: Text -> Text
sanitize = collapseWs . neutralizeHole . neutralizeComment
  where
    hy               = "\8208"                 -- U+2010 HYPHEN (not the ASCII '-')
    neutralizeComment = T.replace "{-" ("{" <> hy) . T.replace "-}" (hy <> "}")
    neutralizeHole    = T.replace "{!" "{ !"   . T.replace "!}" "! }"
    collapseWs        = T.unwords . T.words     -- any whitespace (incl. newlines) → single space, trimmed

-- | Truncate an already-sanitised goal type to 'goalTypeMax' display chars,
-- marking the cut with @…@.
truncateType :: Text -> Text
truncateType s
  | T.length s > goalTypeMax = T.take (goalTypeMax - 1) s <> "…"
  | otherwise                = s

-- | 'True' iff @{-@/@-}@ nest and balance (never closing without an open) —
-- the test oracle for 'sanitize' / 'renderMarker' (Agda block comments nest).
commentBalanced :: Text -> Bool
commentBalanced = go (0 :: Int) . T.unpack
  where
    go n ('{' : '-' : r) = go (n + 1) r
    go n ('-' : '}' : r) = n > 0 && go (n - 1) r
    go n (_ : r)         = go n r
    go n []              = n == 0
