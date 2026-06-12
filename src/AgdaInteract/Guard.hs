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
