{-# LANGUAGE OverloadedStrings #-}
-- | The no-escape-hatch guard for the write-side interaction bridge.
--
-- The bridge must __never__ let an agent close a goal by smuggling in an
-- axiom or by disabling a soundness check — zero-postulate \/
-- fixed-axiom invariants are a hard contract for the consumer corpus.
-- 'checkGiveInput' runs on every @give@\/@refine@ term __before__ it is
-- handed to Agda, so a forbidden term fails locally and is never even
-- elaborated.
--
-- This is deliberately conservative: when in doubt, reject. It is a
-- first line of defence; the session can additionally run under
-- @--safe@ (see "AgdaInteract.Session") so even a guard miss is caught
-- by Agda refusing the term.
module AgdaInteract.Guard
  ( GuardVerdict(..)
  , checkGiveInput
  , checkFileInput
  , checkFileInputFor
  , forbiddenIdentifiers
  , guardScrub
  ) where

import           Data.Text ( Text )
import qualified Data.Text as T

import           AgdaInteract.Literate ( codeBlocksFor, codeSlices, isLiterate )

-- | Verdict for one piece of give\/refine input.
data GuardVerdict
  = Allowed
  | Rejected !Text   -- ^ Human-readable reason (which rule fired).
  deriving (Show, Eq)

-- | Reserved words \/ identifiers that introduce unsoundness or escape
-- the type checker. Matched as whole tokens after comment stripping.
forbiddenIdentifiers :: [Text]
forbiddenIdentifiers =
  [ "postulate"        -- introduces an axiom
  , "primTrustMe"      -- unsound equality
  , "trustMe"
  , "believe_me"
  , "unsafeCoerce"
  ]

-- | Reject give\/refine input that would violate the no-axiom contract.
--
--   * Any pragma block @{-# … #-}@ — a hole term never legitimately
--     carries one, and @TERMINATING@ \/ @NON_TERMINATING@ \/
--     @NO_TERMINATION_CHECK@ \/ @NON_COVERING@ \/ @OPTIONS@ pragmas all
--     disable a soundness check.
--   * Any 'forbiddenIdentifiers' token (after 'guardScrub', so a
--     @-- postulate@ note is not a false positive, and a @postulate@
--     hidden after a comment is still caught).
checkGiveInput :: Text -> GuardVerdict
checkGiveInput input
  | "{-#" `T.isInfixOf` v =
      Rejected "input contains a pragma ({-# … #-}); the bridge refuses \
               \pragmas in hole terms (they can disable termination, \
               \coverage, or --safe)."
  | (t:_) <- hits =
      Rejected ("input uses a forbidden escape hatch: '" <> t
                  <> "'. The bridge enforces a zero-postulate / fixed-axiom \
                     \contract.")
  | otherwise = Allowed
  where
    v    = guardScrub input
    hits = filter (`elem` forbiddenIdentifiers) (tokens v)

-- | Whole-file / whole-definition variant of 'checkGiveInput', for the
-- file-authoring tools (@give_file@ / @new_module@ / @promote@). Unlike
-- 'checkGiveInput' — which rejects /every/ pragma, right for a bare hole
-- term — a real module legitimately carries pragmas (@{-# OPTIONS --safe
-- #-}@, @{-# BUILTIN … #-}@), so this rejects only the soundness-escaping
-- ones:
--
--   * any 'forbiddenIdentifiers' token (postulate \/ primTrustMe \/ …),
--     after 'guardScrub';
--   * a termination\/coverage-disabling pragma (TERMINATING \/
--     NON_TERMINATING \/ NO_TERMINATION_CHECK \/ NON_COVERING);
--   * an @OPTIONS@ pragma carrying a known unsafe flag (@--type-in-type@,
--     @--no-positivity-check@, …).
--
-- Benign options (@--safe@, @--without-K@, @--warning=…@) pass; the
-- session's own @--safe@ is the backstop for any unsafe flag this list
-- misses.
checkFileInput :: Text -> GuardVerdict
checkFileInput input
  | (p:_) <- badPragmas =
      Rejected ("input contains a forbidden pragma ({-# " <> p <> " #-}); the bridge \
                \refuses termination/coverage/unsafe-OPTIONS pragmas (zero-axiom contract).")
  | (t:_) <- hits =
      Rejected ("input uses a forbidden escape hatch: '" <> t
                  <> "'. The bridge enforces a zero-postulate / fixed-axiom contract.")
  | otherwise = Allowed
  where
    v          = guardScrub input
    hits       = filter (`elem` forbiddenIdentifiers) (tokens v)
    badPragmas = filter isBadPragma (pragmaContents v)

-- | Literate-aware 'checkFileInput': for a @.lagda*@ file only the fenced
-- Agda code blocks are guarded, so a literate module whose /prose/ merely
-- mentions @postulate@ or quotes a @{-# TERMINATING #-}@ pragma is not
-- refused (the false positive). For a plain @.agda@ file the whole file
-- is code, so this is exactly 'checkFileInput'. Code slices are rejoined with
-- newlines so a multi-line pragma\/comment inside a fence is scanned intact.
-- (Every fenced block is treated as Agda code — see "AgdaInteract.Literate" —
-- so a token in a @```text@ block is still refused; conservative by design,
-- and @--safe@ on the session is the backstop.)
checkFileInputFor :: FilePath -> Text -> GuardVerdict
checkFileInputFor fp txt
  | not (isLiterate fp) = checkFileInput txt      -- whole file is code; skip the slice pass
  | otherwise           = checkFileInput (T.intercalate "\n" (codeSlices (codeBlocksFor fp txt) txt))

-- | The trimmed contents of each @{-# … #-}@ pragma block in the text
-- (the bytes between the delimiters). An unterminated @{-#@ yields the
-- rest of the input as one block — still checked, not silently skipped.
pragmaContents :: Text -> [Text]
pragmaContents t = case T.breakOn "{-#" t of
  (_, rest)
    | T.null rest -> []
    | otherwise   ->
        let body       = T.drop 3 rest
            (p, after) = T.breakOn "#-}" body
        in T.strip p : pragmaContents (T.drop 3 after)

-- | A pragma whose head disables a soundness check, or an @OPTIONS@ pragma
-- carrying an unsafe flag.
isBadPragma :: Text -> Bool
isBadPragma p = case T.words p of
  []         -> False
  (hd:rest)
    | hd `elem` forbiddenPragmaHeads -> True
    | hd == "OPTIONS"                -> any (`elem` unsafeOptionFlags) rest
    | otherwise                      -> False

forbiddenPragmaHeads :: [Text]
forbiddenPragmaHeads =
  [ "TERMINATING", "NON_TERMINATING", "NO_TERMINATION_CHECK", "NON_COVERING" ]

-- | Unsafe @--flag@s that @--safe@ would also reject; named here so the
-- guard fails fast (and protects a session that isn't run under @--safe@).
unsafeOptionFlags :: [Text]
unsafeOptionFlags =
  [ "--type-in-type", "--no-positivity-check", "--no-termination-check"
  , "--allow-unsolved-metas", "--no-coverage-check", "--rewriting"
  , "--injective-type-constructors", "--experimental-irrelevance" ]

-- | Split into maximal tokens on whitespace and the Agda delimiters that
-- can never be part of a reserved word \/ qualified name segment. Enough
-- to recognise a standalone @postulate@ even when written @(postulate@.
tokens :: Text -> [Text]
tokens = filter (not . T.null) . T.split isDelim
  where
    isDelim c = c `elem` (" \t\r\n(){};.@\"" :: String)

-- | The text the guard scans, made source-region aware in one left-to-right
-- comment/string-aware pass:
--
--   * @{-# … #-}@ pragma blocks at comment-depth 0 are copied __verbatim__
--     (a @--@ inside a pragma must not start a comment, and the pragma scan
--     needs its body) — so a real pragma still reaches 'pragmaContents';
--   * @-- … EOL@ line comments and (nested) @{- … -}@ block comments are
--     removed, so a pragma\/keyword quoted in a comment is inert
--     (a commented-out @{- {-# TERMINATING #-} -}@ balances as one block);
--   * string-literal contents are blanked (the quotes kept, bounded at EOL —
--     Agda strings are single-line) so a quoted @"postulate"@ \/ @"{-#"@ is
--     inert __and__ a stray @"@ can no longer open a phantom comment that
--     swallows following real code (a guard bypass this closes).
--
-- Only ever removes\/blanks inert text: a @postulate@ in active code is
-- outside every comment\/string and survives to the token scan.
guardScrub :: Text -> Text
guardScrub = T.pack . go . T.unpack
  where
    -- depth-0: real code, scanning for comment/string/pragma openers.
    go [] = []
    go ('{':'-':'#':rest) = '{':'-':'#': pragma rest    -- preserve pragma verbatim
    go ('-':'-':rest)     = go (skipToNL rest)          -- line comment (keep the \n)
    go ('{':'-':rest)     = go (dropBlock (1 :: Int) rest)
    go ('"':rest)         = '"' : blankStr rest          -- string literal
    go (c:rest)           = c : go rest

    -- inside a pragma block: copy through the closing #-} (or to EOF).
    pragma ('#':'-':'}':rest) = '#':'-':'}': go rest
    pragma (c:rest)           = c : pragma rest
    pragma []                 = []

    skipToNL = dropWhile (/= '\n')

    -- blank a string's contents; keep the delimiting quotes; an escape blanks
    -- both chars (so an escaped @\"@ can't close early); a bare newline ends
    -- an unterminated literal (Agda strings are single-line).
    blankStr ('\\':_:rest) = ' ' : ' ' : blankStr rest
    blankStr ('"':rest)    = '"' : go rest
    blankStr ('\n':rest)   = '\n' : go rest
    blankStr (_:rest)      = ' ' : blankStr rest
    blankStr []            = []

    dropBlock _ [] = []
    dropBlock n ('{':'-':rest) = dropBlock (n + 1) rest
    dropBlock n ('-':'}':rest)
      | n <= 1    = go rest
      | otherwise = dropBlock (n - 1) rest
    dropBlock n (_:rest) = dropBlock n rest
