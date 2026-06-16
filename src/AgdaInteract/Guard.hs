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
  , forbiddenIdentifiers
  , stripComments
  ) where

import           Data.Text ( Text )
import qualified Data.Text as T

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
--   * Any 'forbiddenIdentifiers' token (after stripping comments, so a
--     @-- postulate@ note is not a false positive, and a @postulate@
--     hidden after a comment is still caught).
checkGiveInput :: Text -> GuardVerdict
checkGiveInput input
  | "{-#" `T.isInfixOf` input =
      Rejected "input contains a pragma ({-# … #-}); the bridge refuses \
               \pragmas in hole terms (they can disable termination, \
               \coverage, or --safe)."
  | (t:_) <- hits =
      Rejected ("input uses a forbidden escape hatch: '" <> t
                  <> "'. The bridge enforces a zero-postulate / fixed-axiom \
                     \contract.")
  | otherwise = Allowed
  where
    hits = filter (`elem` forbiddenIdentifiers) (tokens (stripComments input))

-- | Whole-file / whole-definition variant of 'checkGiveInput', for the
-- file-authoring tools (@give_file@ / @new_module@ / @promote@). Unlike
-- 'checkGiveInput' — which rejects /every/ pragma, right for a bare hole
-- term — a real module legitimately carries pragmas (@{-# OPTIONS --safe
-- #-}@, @{-# BUILTIN … #-}@), so this rejects only the soundness-escaping
-- ones:
--
--   * any 'forbiddenIdentifiers' token (postulate \/ primTrustMe \/ …),
--     after comment stripping;
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
    hits       = filter (`elem` forbiddenIdentifiers) (tokens (stripComments input))
    badPragmas = filter isBadPragma (pragmaContents input)

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

-- | Remove Agda line comments (@-- … EOL@) and (nested) block comments
-- (@{- … -}@). Pragmas are handled separately by 'checkGiveInput' before
-- this runs, so stripping only ever removes inert text — a @postulate@
-- in active code is not inside a comment and survives.
stripComments :: Text -> Text
stripComments = T.pack . go . T.unpack
  where
    go [] = []
    go ('-':'-':rest) = go (dropLine rest)
    go ('{':'-':rest) = go (dropBlock (1 :: Int) rest)
    go (c:rest)       = c : go rest

    dropLine = drop 1 . dropWhile (/= '\n')

    dropBlock _ [] = []
    dropBlock n ('{':'-':rest) = dropBlock (n + 1) rest
    dropBlock n ('-':'}':rest)
      | n <= 1    = rest
      | otherwise = dropBlock (n - 1) rest
    dropBlock n (_:rest) = dropBlock n rest
