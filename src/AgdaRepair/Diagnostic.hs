{-# LANGUAGE OverloadedStrings #-}
-- | Pure classifier: turn @agda@'s rendered error messages into a structured
-- '[Diagnostic]' the repair loop acts on.
--
-- The @--interaction-json@ Error message is byte-identical to @agda@'s CLI
-- rendering (bracketed @[Tag]@, a @Not in scope:@ block, a @when scope checking
-- X@ trailer), so this parses that text directly. Lenient: an unrecognised tag
-- collapses to 'DRefuse', so the loop reports the class and leaves the file
-- untouched rather than guessing. Pinned by tests in @test/Spec.hs@.
--
-- Parsing facts it relies on:
--
--   * agda reports scope errors one at a time, so repair is a recompile loop;
--   * a missing operator import (@_×_@) surfaces as @NoParseForApplication@ on
--     the bare @×@, a missing constructor in a pattern as @NoParseForLHS@ —
--     neither is a @NotInScope@;
--   * @when scope checking the declaration@ is prose — dropped by 'stopWords'.
module AgdaRepair.Diagnostic
  ( Diagnostic(..)
  , classify
    -- * Extraction primitives (exported for goldens)
  , errorTags
  , notInScopeNames
  , parseErrorNames
  , stopWords
  , stripUnderscores
  , nameKeys
  , isRefusableTag
  , hintOutOfScope
  ) where

import           Data.Char        (isAlphaNum)
import           Data.List        (nub, sort)
import           Data.Maybe       (mapMaybe)
import           Data.Text        (Text)
import qualified Data.Text        as T

-- | One actionable (or refused) finding. Actionable ones come first in
-- 'classify's output; 'DRefuse' is emitted only when there are errors but
-- nothing the loop knows how to try. (Open goals aren't a 'Diagnostic': a
-- module with holes has no hard errors, so the loop reports them directly off
-- 'coGoals' rather than classifying them.)
data Diagnostic
  = DScope !Text        -- ^ an identifier / operator reported not-in-scope;
                        --   resolve by adding an import or renaming a typo.
  | DParse !Text        -- ^ a candidate operator / constructor from a
                        --   @NoParseFor*@ error (import-only; no rename).
  | DIncomplete         -- ^ incomplete pattern matching — recommend @case_split@.
  | DRefuse !Text !Text -- ^ (tag, message): a class we deliberately do not
                        --   touch (semantic / unknown). Reported, never faked.
  deriving (Eq, Show)

-- | Prose words that appear in agda diagnostics where a name would but are
-- never identifiers. Keeps @when scope checking the declaration@ /
-- @Operators used in the grammar@ etc. out of the candidate set.
stopWords :: [Text]
stopWords =
  [ "the","left-hand","side","application","of","in","definition","expression"
  , "declaration","operator","operators","used","grammar","none","problematic"
  , "when","scope","checking","at","not","a","an","type","checking" ]

-- | Error-class tags the loop refuses outright: semantic mismatches and the
-- soundness-escaping classes (a hole-fill can never legitimately silence
-- these). Everything else unknown also refuses, via 'classify's fallthrough.
isRefusableTag :: Text -> Bool
isRefusableTag t = t `elem`
  [ "UnequalTerms", "UnequalTypes", "TerminationIssue", "NonTerminating"
  , "PositivityCheckFailed", "ConstructorDoesNotFitInSort", "WrongNamedArgument"
  , "MissingTypeSignature", "ClashingDefinition", "AbstractConstructorNotInScope" ]

-- | Underscore-stripped core of a mixfix name (@_×_@ ↦ @×@). Agda reports the
-- bare operator (@×@) as not-in-scope even though an import names it @_×_@, so
-- we match under both forms.
stripUnderscores :: Text -> Text
stripUnderscores = T.filter (/= '_')

-- | All keys a used name might be indexed / looked up under (mixfix core +
-- the section forms an infix reporter could emit).
nameKeys :: Text -> [Text]
nameKeys n =
  let core = stripUnderscores n
      base = nub [n, core]
  in if T.any (== '_') n
       then base
       else base ++ ["_" <> n <> "_", "_" <> n, n <> "_"]

-- | Split a rendered fragment into maximal identifier/operator tokens on
-- whitespace and name-segment delimiters. Different delimiter set from
-- 'AgdaInteract.Guard.tokens': splits on @|,@ (they bound sub-expressions in a
-- parse-error dump), keeps @\@\"@ (absent in diagnostics).
tokens :: Text -> [Text]
tokens = filter (not . T.null) . T.split isDelim
  where isDelim c = c `elem` (" \t\r\n(){}|;,." :: String)

-- | Every @error: [Tag]@ class tag in the joined diagnostics, in order.
errorTags :: Text -> [Text]
errorTags = mapMaybe tagOf . T.lines
  where
    tagOf ln
      | "error:" `T.isInfixOf` ln
      , (_, rest) <- T.breakOn "[" ln
      , not (T.null rest)
      , (tag, close) <- T.breakOn "]" (T.drop 1 rest)
      , not (T.null close)
      = Just (T.strip tag)
      | otherwise = Nothing

-- | Did agda reject a Mimer hint @h@ as out of scope? Mimer aborts the
-- whole @Cmd_autoOne@ when a seeded hint name is not in scope (Agda 2.9),
-- returning a @NotInScope@ error. Reporting that as "no solution" is a
-- false negative — the graph named a closing lemma the file just hasn't
-- imported (R19). Precise path: the structured not-in-scope list names the
-- hint. Fallback: a @NotInScope@ tag with the (dot-free base) hint present
-- in the message, hedging a layout the primary parser misses. Anything else
-- is a genuine search failure, not a scope problem.
hintOutOfScope :: Text -> Text -> Bool
hintOutOfScope h err =
     h `elem` notInScopeNames err
  || ("NotInScope" `elem` errorTags err && h `T.isInfixOf` err)

-- | Not-in-scope identifiers: the token after @when scope checking@, plus the
-- indented entries under a @Not in scope:@ block, minus 'stopWords'. Handles
-- the two layouts (@X at …@ on one line, or @X@ then @at …@).
notInScopeNames :: Text -> [Text]
notInScopeNames txt = dedup (fromTrailer ++ fromBlock)
  where
    ls = T.lines txt
    fromTrailer =
      [ tok
      | ln <- ls
      , Just rest <- [T.stripPrefix "when scope checking" (T.strip ln)]
      , tok : _ <- [tokens rest]
      , keep tok ]
    fromBlock = go ls
      where
        go [] = []
        go (l:rest)
          | "Not in scope" `T.isPrefixOf` T.strip l = block rest ++ go rest
          | otherwise = go rest
        block = concatMap one . takeWhile isEntry
        isEntry l = let s = T.strip l
                    in not (T.null s) && not ("at " `T.isPrefixOf` s)
                                      && not ("when " `T.isPrefixOf` s)
                                      && not ("Not in scope" `T.isPrefixOf` s)
        one l = case tokens (T.strip l) of
                  (tok:_) | keep tok -> [tok]
                  _                  -> []
    keep t = not (T.null t) && T.toLower t `notElem` stopWords

-- | Candidate missing names from a @NoParseFor*@ error: dropping an operator
-- or constructor import breaks parsing, not scope, so the culprit is in the
-- unparseable expression. Over-collect symbolic / mixfix tokens from the
-- @Could not parse …@ and @Problematic expression:@ lines; the loop's
-- recompile step filters wrong guesses.
parseErrorNames :: Text -> [Text]
parseErrorNames txt = dedup (go (T.lines txt))
  where
    -- A @Could not parse …@ header is followed by the unparseable expression on
    -- the next line(s), up to the @Operators used@ / @Problematic@ / @when@
    -- trailer — collect those; a @Problematic expression:@ line carries it
    -- inline after the colon.
    go [] = []
    go (l : ls)
      | Just rest <- T.stripPrefix "Could not parse" s =
          let (expr, more) = span notStop ls
          in pick (T.unwords (rest : map T.strip expr)) ++ go more
      | Just rest <- T.stripPrefix "Problematic expression" s =
          pick (T.dropWhile (== ':') rest) ++ go ls
      | otherwise = go ls
      where s = T.strip l
    notStop l = let t = T.strip l
                in not (T.null t) && not (any (`T.isPrefixOf` t) ["Operator", "Problematic", "when "])
    pick seg = [ t | t <- tokens seg
                   , t /= "_"
                   , T.toLower t `notElem` stopWords
                   , T.any (\c -> c == '_' || not (isAlphaNum c)) t ]

dedup :: [Text] -> [Text]
dedup = nub . sort

-- | Classify a module's error messages into an ordered diagnostic list: scope
-- names first (the incremental repair frontier), then parse-error candidates,
-- then incomplete-pattern work, and finally 'DRefuse' for any error class with
-- nothing actionable. Called only on a /failing/ load (open goals, which carry
-- no error, are handled by the caller off 'coGoals').
classify :: [Text] -> [Diagnostic]
classify errs =
  let joined  = T.intercalate "\n" errs
      scope   = map DScope (notInScopeNames joined)
      parses  = if null scope then map DParse (parseErrorNames joined) else []
      tags    = errorTags joined
      incompl = [ DIncomplete | any ("IncompletePatternMatching" ==) tags
                             || any ("CoverageIssue" ==) tags ]
      actionable = scope ++ parses ++ incompl
      -- refuse only when nothing above is actionable but errors remain
      refusal
        | not (null actionable) = []
        | null errs             = []
        | otherwise             =
            let refused = filter isRefusableTag tags
                shown   = if null refused then tags else refused
            in [ DRefuse (T.intercalate "," (dedup shown)) joined ]
  in actionable ++ refusal
