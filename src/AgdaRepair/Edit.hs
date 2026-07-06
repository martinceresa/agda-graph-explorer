{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Pure text edits for the repair loop, and the spec-preservation predicate.
--
-- Two edit kinds: insert an @open import@, or rename a mis-typed reference. A
-- repair must never rewrite a theorem statement, so 'renameInBody' skips
-- signature / import / module lines and tokens inside comments and string
-- literals. 'signatures' is the invariant the loop checks after each edit.
module AgdaRepair.Edit
  ( Edit(..)
  , applyEdits
  , insertImport
  , renameInBody
  , signatures
  , isProtectedLine
  , isSigLine
  ) where

import           Data.Char   (isAlphaNum, isSpace)
import           Data.Text   (Text)
import qualified Data.Text   as T

-- | One repair edit. A 'Candidate' (see "AgdaRepair.Strategy") is a bundle of
-- these applied and validated together.
data Edit
  = EAddImport !Text        -- ^ an @open import M using (…)@ line to insert.
  | ERename    !Text !Text  -- ^ replace a not-in-scope token with a name.
  deriving (Eq, Show)

-- | Apply a bundle in order. 'Nothing' if the net effect is a no-op (e.g. the
-- import was already present and there was no rename) — the loop treats that
-- as "candidate made no change" and moves on.
applyEdits :: Text -> [Edit] -> Maybe Text
applyEdits t es =
  let t' = foldl' step t es
  in if t' == t then Nothing else Just t'
  where
    step acc (EAddImport l) = insertImport acc l
    step acc (ERename o n)  = renameInBody acc o n

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

-- | Replace whole-token occurrences of @old@ with @new@, but only in body
-- lines (not signatures / imports / module headers) and only in code (not
-- comments or string literals). Block-comment depth is threaded across lines
-- so a rename inside a multi-line @{- … -}@ is correctly skipped. Preserves
-- the trailing newline.
renameInBody :: Text -> Text -> Text -> Text
renameInBody src old new
  | T.null old = src
  | otherwise  = rejoin (go 0 (T.lines src))
  where
    rejoin xs = T.intercalate "\n" xs <> (if "\n" `T.isSuffixOf` src then "\n" else "")
    -- thread block-comment depth across every line; only rewrite unprotected
    -- lines, but always scan so the depth stays correct.
    go _ [] = []
    go !depth (l:rest) =
      let allow          = not (isProtectedLine l)
          (l', depth')   = scanLine allow depth l
      in l' : go depth' rest

    scanLine :: Bool -> Int -> Text -> (Text, Int)
    scanLine allow depth0 line = let (out, d) = walk '\n' depth0 False (T.unpack line)
                                 in (T.pack out, d)
      where
        oldS = T.unpack old
        newS = T.unpack new
        identChar c = isAlphaNum c || c == '_' || c == '\''
        -- prev: last emitted source char (for left-boundary); depth: block
        -- comment nesting; inStr: inside a "…" literal.
        walk _ d _ [] = ("", d)
        walk prev d inStr cs@(c:rest)
          | inStr =
              case c of
                '\\' -> case rest of
                          (e:r2) -> let (o, d') = walk e d True r2 in (c:e:o, d')
                          []     -> ("\\", d)
                '"'  -> let (o, d') = walk c d False rest in (c:o, d')
                _    -> let (o, d') = walk c d True rest in (c:o, d')
          | d > 0 =
              case cs of
                ('-':'}':r2) -> let (o, d') = walk '}' (d-1) False r2 in ('-':'}':o, d')
                ('{':'-':r2) -> let (o, d') = walk '-' (d+1) False r2 in ('{':'-':o, d')
                _            -> let (o, d') = walk c d False rest in (c:o, d')
          | otherwise =
              case cs of
                ('-':'-':_)  -> (cs, d)                       -- line comment: copy rest verbatim
                ('{':'-':r2) -> let (o, d') = walk '-' 1 False r2 in ('{':'-':o, d')
                ('"':r2)     -> let (o, d') = walk '"' d True r2 in ('"':o, d')
                _ | allow
                  , oldS `isTokenPrefixOf` cs
                  , not (identChar prev)
                  , boundaryAfter (drop (length oldS) cs) ->
                      let r2       = drop (length oldS) cs
                          (o, d')  = walk (lastDef prev newS) d False r2
                      in (newS ++ o, d')
                  | otherwise -> let (o, d') = walk c d False rest in (c:o, d')

        isTokenPrefixOf p s = take (length p) s == p && not (null p)
        boundaryAfter []      = True
        boundaryAfter (c:_)   = not (identChar c)
        lastDef p [] = p
        lastDef _ xs = last xs

-- | The top-level @name : Type@ signature lines — the theorem statements the
-- repair loop must leave byte-identical. The loop asserts this set is
-- unchanged after every accepted edit.
signatures :: Text -> [Text]
signatures = filter isSigLine . T.lines

-- | A line the repair loop never rewrites: a top-level signature, an import,
-- or a module header.
isProtectedLine :: Text -> Bool
isProtectedLine l =
     isSigLine l
  || "open import" `T.isPrefixOf` l
  || "import "     `T.isPrefixOf` l
  || "module "     `T.isPrefixOf` l

-- | A top-level @name : Type@ line: starts in column 0 with a single-token
-- left-hand side followed by a colon.
isSigLine :: Text -> Bool
isSigLine l =
  case T.uncons l of
    Just (c, _) | not (isSpace c) ->
      let (lhs, rhs) = T.breakOn ":" l
      in not (T.null rhs) && length (T.words lhs) == 1 && not (T.null (T.strip lhs))
    _ -> False
