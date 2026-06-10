{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Lightweight source-scan helpers that extract structured information
-- from the @open import …@ headers of an Agda source file.
--
-- This module does NOT understand Agda's grammar beyond what's needed
-- for the unused-import analysis:
--
-- * Each logical line is scanned with line/block-comments stripped.
-- * @open import M …@ and @import M …@ are recognised.
-- * Optional @using (n₁; …; nₖ)@ / @hiding (…)@ / @renaming (…)@
--   clauses are extracted; we only inspect @using@.
-- * Trailing @public@ keyword is detected so the analyser can apply
--   different rules to re-exports.
--
-- False positives in symbol-token extraction are acceptable: the
-- downstream analysis is a hint, not a refactor authority.
module AgdaUnused.Source
  ( ImportLine(..)
  , scanImports
  , bodyTokens
  ) where

import           Data.Char  ( isSpace )
import           Data.List  ( isPrefixOf )
import qualified Data.Set   as S
import qualified Data.Text  as T

-- | One @open import …@ / @import …@ statement extracted from the
-- source, with its 1-based line number and the @using (...)@ symbol
-- list. If no @using@ clause is present, 'ilUsing' is 'Nothing' (a
-- blanket open, semantically "all visible names").
data ImportLine = ImportLine
  { ilLine    :: !Int
    -- ^ 1-based line number where the @open import …@ token sits.
  , ilModule  :: !T.Text
    -- ^ Imported module name (sanitised the same way
    -- "AgdaDeps.Precompute" does).
  , ilUsing   :: !(Maybe [T.Text])
    -- ^ 'Just' xs when a @using (...)@ clause is present; 'Nothing' for
    -- a blanket @open import M@ (or @import M@) with no @using@.
  , ilPublic  :: !Bool
    -- ^ True if a trailing @public@ keyword was found.
  , ilRaw     :: !T.Text
    -- ^ Original line, kept for the user-facing report.
  , ilScope   :: !Int
    -- ^ Indent column of the enclosing @module … where@ declaration
    -- (0 for top-level). Two opens with different 'ilScope' values
    -- live in different lexical scopes and should not be considered
    -- duplicates of one another. See 'scanImports' for the tracking
    -- heuristic.
  } deriving (Show)

-- | Scan the file content for import headers. Returns one
-- 'ImportLine' per @open import …@ / @import …@ line.
--
-- Caveats:
--
-- * Multi-line @using (...)@ clauses are NOT supported. If one
--   occurs, the @using@ list will be partial and the analyser will
--   over-report.
-- * Statements that aren't at the start of their line (modulo leading
--   whitespace) are ignored, matching the heuristic of
--   "AgdaDeps.Precompute".
scanImports :: T.Text -> [ImportLine]
scanImports raw =
  let stripped = stripBlock (T.unpack raw)
      ls       = lines stripped
      ls'      = zip [1..] (map stripLineComment ls)
      -- Walk the file maintaining a stack of enclosing
      -- @module … where@ declarations. Each entry is a pair
      -- @(indentColumn, headerLine)@: @indentColumn@ governs when the
      -- block closes, @headerLine@ is the scope tag we attach to
      -- imports inside it. Using the header line (not the column) as
      -- the tag side-steps the case where two distinct nested modules
      -- happen to share an indent column — they get different tags.
      -- Top-level (no enclosing nested module on the stack) is tag 0.
      walk _stack [] = []
      walk stack ((lineNo, line) : rest) =
        let indent  = length (takeWhile (== ' ') line)
            ws      = words (dropWhile isSpace line)
            isBlank = null ws
            -- A non-blank line at column <= a stack entry's indent
            -- closes that block. Blank lines never pop.
            stack' = if isBlank
                       then stack
                       else dropWhile (\(c, _) -> c >= indent) stack
            currentScope = case stack' of
              ((_, lh):_) -> lh
              []          -> 0
            stackAfter =
              if isBlank
                then stack
                else case ws of
                  -- @module Foo where@, @module Foo (...) where@,
                  -- @module _ where@. Push the header's
                  -- @(indent, lineNo)@. The file's top-level header
                  -- (e.g. @module Prelude.Init where@ at indent 0)
                  -- gets pushed too, but its content lives at indent
                  -- >= 0, and the @>= indent@ pop rule strips it
                  -- away the moment we see a column-0 import — so
                  -- top-level imports correctly resolve to tag 0
                  -- (empty stack).
                  ("module" : _) | "where" `elem` ws ->
                    (indent, lineNo) : stack'
                  _ -> stack'
            mk = ImportLine
                   { ilLine   = lineNo
                   , ilModule = T.empty
                   , ilUsing  = Nothing
                   , ilPublic = False
                   , ilRaw    = T.pack line
                   , ilScope  = currentScope
                   }
            here = case ws of
              "open" : "import" : name : args ->
                [mk { ilModule = T.pack (sanitiseName name)
                    , ilUsing  = extractUsing args `orElseElided` args
                    , ilPublic = "public" `elem` args
                    }]
              "import" : name : args ->
                [mk { ilModule = T.pack (sanitiseName name)
                    , ilUsing  = extractUsing args `orElseElided` args
                    , ilPublic = False
                    }]
              _ -> []
        in here ++ walk stackAfter rest
  in walk [] ls'
  where

    -- '⋯' (U+22EF MIDLINE HORIZONTAL ELLIPSIS) is used as an inline
    -- placeholder for an elided @using (...)@ clause in
    -- literate-Markdown sources. Without special-casing it, every such
    -- open looks blanket and the 'UnusedBlanketOpen' check fires
    -- wholesale. Treating a present '⋯' as @Just []@ — "there IS a
    -- using clause; we just don't know its contents" — suppresses the
    -- blanket false positive while keeping every other check honest.
    orElseElided :: Maybe [T.Text] -> [String] -> Maybe [T.Text]
    orElseElided (Just xs) _    = Just xs
    orElseElided Nothing   toks = if any (elem '\x22ef') toks
                                    then Just []
                                    else Nothing

-- | Return the comma/semicolon-separated identifier list of a
-- @using (...)@ clause, if one is present in the tokens. The tokens
-- already exclude the leading "open"/"import"/module-name.
extractUsing :: [String] -> Maybe [T.Text]
extractUsing tokens = case dropUntilUsing tokens of
  Nothing -> Nothing
  Just rest ->
    -- 'rest' starts AFTER the "using" keyword. We expect an
    -- '(' opening paren next (possibly with leading whitespace
    -- because we re-joined word-tokens with spaces). Concatenate
    -- everything up to the matching ')' and split on ';' / ',' /
    -- whitespace.
    let joined = unwords rest
    in case parseParen joined of
         Nothing      -> Just []   -- malformed; treat as empty
         Just (inner, _) ->
           let toks = splitSyms inner
           in Just (map T.pack (filter (not . null) toks))

dropUntilUsing :: [String] -> Maybe [String]
dropUntilUsing []           = Nothing
dropUntilUsing ("using":xs) = Just xs
dropUntilUsing (_:xs)       = dropUntilUsing xs

-- | Extract the contents of the first top-level @(...)@ in the input;
-- balance parens so renamings like @using (foo) renaming (a to b)@
-- still parse the right slice.
parseParen :: String -> Maybe (String, String)
parseParen s = case dropWhile isSpace s of
  ('(':rest) -> go 1 [] rest
  _          -> Nothing
  where
    go :: Int -> String -> String -> Maybe (String, String)
    go _ _   []       = Nothing
    go 1 acc (')':cs) = Just (reverse acc, cs)
    go n acc ('(':cs) = go (n + 1) ('(':acc) cs
    go n acc (')':cs) = go (n - 1) (')':acc) cs
    go n acc (c:cs)   = go n       (c:acc)   cs

-- | Split a @using-list@ body into bare identifiers. Drops 'module',
-- '_', and any 'renaming (X to Y)' sub-clauses. The tokenisation is
-- "Agda-grade": identifiers are runs of non-separator characters,
-- separators are whitespace, ';', ','.
splitSyms :: String -> [String]
splitSyms = filter (not . null) . map clean . splitOnSeps
  where
    splitOnSeps :: String -> [String]
    splitOnSeps s = go [] [] s
      where
        sep c = c == ';' || c == ',' || isSpace c
        go acc cur []     = reverse (reverse cur : acc)
        go acc cur (c:cs)
          | sep c     = go (reverse cur : acc) [] cs
          | otherwise = go acc (c:cur) cs

    -- Drop the optional "module" qualifier inline ("module M") and
    -- ignore "to … " / "renaming (…)" pairs by stopping at "to".
    clean s
      | s == "module"   = ""
      | s == "renaming" = ""
      | s == "hiding"   = ""
      | s == "to"       = ""
      | s == "public"   = ""
      | otherwise       = s

-- | Identifier-ish tokens that appear OUTSIDE the import block of a
-- file. Used as the haystack the unused-import analysis searches.
--
-- We deliberately scan the whole file (including the import block):
-- false positives from a symbol appearing in its own @using (...)@
-- clause are avoided by structuring the analyser to ignore the
-- per-import line itself when computing usage (see "AgdaUnused.Analysis").
--
-- The token set is an over-approximation: anything that looks like a
-- (possibly unicode) Agda identifier is reported. Operator-name
-- pieces wrapped in @_@ are NOT split — they're returned whole, which
-- is what Agda's symbol table uses too.
bodyTokens :: T.Text -> S.Set T.Text
bodyTokens raw =
  let stripped = stripBlock (T.unpack raw)
      noCmts   = unlines (map stripLineComment (lines stripped))
  in S.fromList (map T.pack (tokenise noCmts))
  where
    tokenise []     = []
    tokenise (c:cs)
      | isIdChar c  = let (t, rest) = span isIdChar (c:cs) in t : tokenise rest
      | otherwise   = tokenise cs

    -- Agda identifiers are very permissive: any non-whitespace,
    -- non-special character can appear in a name. We approximate that
    -- by allowing alphanumerics, all the operator-character ASCII
    -- punctuation Agda actually permits ('<', '>', '=', '+', '-',
    -- '*', '/', '!', '?', '#', '$', '%', '&', '^', '~', '|', ':',
    -- '\''), and any non-ASCII rune so unicode names like '∈-Propose'
    -- or 'NE×SE⇒SFE' survive.
    --
    -- We deliberately reject '.', '(', ')', '{', '}', '[', ']', ';',
    -- ',' so qualified names like 'Nat.<-wellFounded' tokenise as the
    -- two pieces 'Nat' and '<-wellFounded' rather than as one big run.
    -- That's the form the import-name check wants to match.
    isIdChar c =
         (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c `elem` ("_-'!?<>=+*/#$%&^~|:" :: String)
      || c > '\x7f'

-- ** Comment stripping (copied from "AgdaDeps.Precompute" so this
-- module stays standalone — the originals aren't exported).

stripLineComment :: String -> String
stripLineComment = go
  where
    go [] = []
    go ('-':'-':_) = []
    go (c:cs) = c : go cs

stripBlock :: String -> String
stripBlock = go (0 :: Int)
  where
    go _ []                       = []
    go 0 ('{':'-':rest)           = go 1 rest
    go 0 (c:cs)                   = c : go 0 cs
    go n ('-':'}':rest)           = go (max 0 (n - 1)) rest
    go n ('{':'-':rest)           = go (n + 1) rest
    go n (_:cs)                   = go n cs

-- | Trim Agda module names of trailing punctuation (semicolons, parens,
-- …). Matches "AgdaDeps.Precompute.sanitiseName".
sanitiseName :: String -> String
sanitiseName =
  takeWhile (\c -> c == '.' || c == '_' || c == '\'' || c == '-' || isIdCharS c)
  where
    isIdCharS c = (c >= 'a' && c <= 'z')
               || (c >= 'A' && c <= 'Z')
               || (c >= '0' && c <= '9')
               || c > '\x7f'

-- | 'isPrefixOf' lifted to 'Data.Text'.
_isTextPrefix :: T.Text -> T.Text -> Bool
_isTextPrefix p s = T.unpack p `isPrefixOf` T.unpack s
