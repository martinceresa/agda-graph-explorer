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
-- Murmur64" gotcha in @CLAUDE.md@. @AgdaGoals.Canon@ re-exports this
-- module.
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
  , hashString
  , word64Hex16

    -- * Conclusion / token extraction (find_lemma)
  , conclusionOf
  , headSymbol
  , tokenJaccard
    -- * Match-oriented tokens (find_lemma retrieval)
  , matchTokens
  , nameTokens
  , shapeTokens
  , goalFeatures
  , weightedCoverage
  , weightedCoverageIdf
  , idfOf
  , isOpToken
  , stripQualifiers

    -- * Qualified-name helpers
  , baseComponent
  , moduleComponent
  ) where

import           Control.DeepSeq  ( NFData(..) )
import           Data.Char        ( isSpace, isAsciiLower, isUpper, isAlphaNum, isDigit )
import           Data.List        ( nub, sort )
import           Data.Maybe       ( listToMaybe )
import           Data.Set         ( Set )
import qualified Data.Set         as Set
import           Data.Text        ( Text )
import qualified Data.Text        as T
import           Data.Word        ( Word64 )
import qualified Data.Map.Strict  as Map

import           Numeric              ( showHex )
import           Data.Digest.Murmur64 ( asWord64, hash64 )

-- | Stable 64-bit string hash. Vendored from @murmur-hash@ to keep this
-- repo Agda-free: this is byte-for-byte the definition of Agda's
-- @Agda.Utils.Hash.hashString@ (@asWord64 . hash64@), so canonical-goal
-- buckets remain cross-referenceable with @agda-deps@'s @hashQName@.
hashString :: String -> Word64
hashString = asWord64 . hash64

-- | Render a 'Word64' as a fixed 16-char zero-padded lowercase hex string —
-- the canonical form for the identity/fingerprint digests this hash feeds
-- (shared by @agda-explore@'s graph identity and @term-cluster@'s cluster
-- ids so the two agree by construction).
word64Hex16 :: Word64 -> String
word64Hex16 w = let s = showHex w "" in replicate (16 - length s) '0' ++ s

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
hashCanonical (CanonicalGoal t) = hashString (T.unpack t)

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
    dropLine = fst . T.breakOn "--"

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
          in if isAsciiLower c
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

-- | A symbol character: not whitespace, not a bracket, not the
-- qualified-name dot, and not an identifier character.
-- | The bracket pairs a printed Agda type can use to enclose a group.
--
-- @\8291 \8292@ (Agda's INSTANCE brackets) belong here as much as
-- @{ }@ does: an instance argument is a group, and leaving it out left its
-- contents at depth 0 and the bracket itself reading as a top-level
-- operator — so 'headSymbol' answered the bracket for any goal or premise
-- carrying one (@Reachable {a} (…) ⦃ Init-State ⦄ s@ headed by @⦃@ rather
-- than by @Reachable@). Every bracket-depth walker in this module —
-- 'flattenShape', 'isOpChar' and 'conclusionOf' — keys off these, so no
-- two of them can disagree about what a bracket is.
openBracket, closeBracket :: String
openBracket  = "([{\10627"
closeBracket = ")]}\10628"

isOpChar :: Char -> Bool
isOpChar ch =
  not (isSpace ch)
    && not (identStart ch)
    && ch `notElem` ('.' : openBracket ++ closeBracket)

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
conclusionOf t = T.strip (go 0 (T.unpack t) "")
  where
    -- @go depth input acc@: @acc@ accumulates the segment since the most
    -- recent top-level arrow (built reversed); when we hit a top-level
    -- arrow we discard @acc@ and start a fresh @acc@. At end-of-input the
    -- surviving @acc@ is the conclusion.
    go :: Int -> String -> String -> Text
    go _ []           acc = T.pack (reverse acc)
    go d s@(c : rest) acc
      | d <= 0, Just s' <- arrowAt s = go 0 s' ""
      -- The shared bracket sets, not a third literal pair: this is the
      -- function that decides where a signature's conclusion begins,
      -- before 'headSymbol' ever runs, so an arrow inside an instance
      -- group must not read as top-level here either.
      | c `elem` openBracket         = go (d + 1) rest (c : acc)
      | c `elem` closeBracket        = go (d - 1) rest (c : acc)
      | otherwise                    = go d rest (c : acc)
    -- Match a leading arrow (Unicode or ASCII) and return the remainder.
    arrowAt ('\x2192' : r) = Just r
    arrowAt ('-' : '>' : r) = Just r
    arrowAt _               = Nothing

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

----------------------------------------------------------------------
-- Match-oriented tokens (find_lemma goal→lemma retrieval).
--
-- These helpers are tuned for /retrieval/, where the query is a bare goal
-- type and the candidates are fully-qualified stored signatures. Three
-- differences decide whether the right lemma is rankable at all:
--
--   1. A qualified name is reduced to its final component before
--      tokenising, so @Data.Nat._+_@ contributes @+@ and @Data.List.map@
--      contributes @map@ — dropping the @Data@\/@Nat@\/@List@ noise that
--      otherwise clusters lemmas by module instead of by content (the
--      dominant confound: goal types are unqualified, stored sigs are
--      fully qualified).
--   2. A lowercase-ASCII run is kept only when a caller-supplied @keep@
--      predicate accepts it — used to retain head symbols that /are/
--      definitions (@map@\/@length@\/@reverse@) while still dropping
--      bound variables (@xs@\/@n@\/@f@).
--   3. The definition's own name ('nameTokens') and the goal's algebraic
--      /shape/ ('shapeTokens') feed the same token bag, because stdlib
--      states its most-reached-for lemmas via abstract combinators
--      (@+-comm : Commutative _≡_ _+_@) whose conclusion shares nothing
--      with the goal beyond the operator.

-- | True when a token reads as an operator (its first character is a
-- symbol, not a letter/digit/underscore) — @≡@, @+@, @++@ — as opposed
-- to an identifier like @List@ or @Commutative@.
isOpToken :: Text -> Bool
isOpToken t = case T.uncons t of
  Just (c, _) -> not (isAlphaNum c || c == '_')
  Nothing     -> False

-- | Final dotted component of a (possibly qualified) name
-- (@Data.Nat._+_@ → @_+_@, @map@ → @map@).
baseComponent :: Text -> Text
baseComponent = snd . T.breakOnEnd "."

-- | Module part of a qualified name: everything before the final dotted
-- component (@Data.Nat.Base.ℕ@ → @Data.Nat.Base@). @""@ when unqualified.
moduleComponent :: Text -> Text
moduleComponent qn = case fst (T.breakOnEnd "." qn) of
  pre | T.null pre -> ""
      | otherwise  -> T.dropEnd 1 pre

-- | Match-oriented tokens of a type string (see the section note). The
-- @keep@ predicate decides which bare-lowercase identifier runs survive
-- (bound variables are dropped, known definition names are kept).
matchTokens :: (Text -> Bool) -> Text -> Set Text
matchTokens keep = Set.fromList . map T.pack . scan . T.unpack
  where
    scan [] = []
    scan s@(c : _)
      | identStart c =
          let (tok, rest) = span identChar s
          in case rest of
               -- ".<ident>": @tok@ is a module qualifier — drop it and
               -- continue from the next component.
               ('.' : d : _) | identStart d ->
                 scan (drop 1 rest)
               -- ".<op>": a qualified operator (@…PropositionalEquality.≡@)
               -- — drop the qualifier and emit the operator.
               ('.' : d : _) | isOpChar d ->
                 let (op, rest') = span isOpChar (drop 1 rest)
                 in T.unpack (normOp op) : scan rest'
               _ -> (if keepTok tok then (tok :) else id) (scan rest)
      | isOpChar c =
          let (tok, rest) = span isOpChar s
          in T.unpack (normOp tok) : scan rest
      | otherwise = scan (drop 1 s)
    -- Keep uppercase / non-ASCII / mixed-case runs always; a bare
    -- lowercase-ASCII run only when @keep@ accepts it.
    keepTok []          = False
    keepTok tok@(c : _)
      | isUpper c                                        = True
      | not (isAsciiLower c || isDigit c || c == '_')    = True
      | any isUpper tok                                  = True
      | otherwise                                        = keep (T.pack tok)

-- | Strip mixfix placeholder underscores from an operator spelling
-- (@_+_@ → @+@); leaves a genuine symbol run (@++@) untouched. Falls
-- back to the original if stripping would empty it.
normOp :: String -> Text
normOp op = let s = filter (/= '_') op in T.pack (if null s then op else s)

-- | Tokens contributed by a definition's own (possibly qualified) name.
-- stdlib lemma names systematically encode operator + property
-- (@+-comm@, @length-++@, @reverse-involutive@) — often a stronger match
-- signal than the abstract combinator type. Split the base name on the
-- @-@ component separator and tokenise each piece permissively (a
-- curated name carries no bound variables to drop).
nameTokens :: Text -> Set Text
nameTokens qn =
  Set.unions (map (matchTokens (const True)) (T.splitOn "-" (baseComponent qn)))

-- | Strip module qualifiers from a rendered type string for display:
-- reduce each dotted qualified name to its final component
-- (@Data.Nat._+_@ → @_+_@, @Relation.Binary.PropositionalEquality._≡_@ →
-- @_≡_@, @(Data.Integer.+ 0)@ → @(+ 0)@), leaving operators, brackets and
-- spacing intact. Display-only (lossy) — do not use where the qualified
-- name is semantically needed.
stripQualifiers :: Text -> Text
stripQualifiers = T.pack . go . T.unpack
  where
    go [] = []
    go s@(c : _)
      | identStart c =
          let (run, rest) = span (\x -> identChar x || x == '.') s
          in lastComponent run ++ go rest
      | otherwise = c : go (drop 1 s)
    -- the suffix after the final '.', or the whole run when unqualified.
    lastComponent = reverse . takeWhile (/= '.') . reverse

-- | Operator-weighted coverage of a goal token set by a candidate bag:
-- the fraction of the goal's tokens the candidate contains, counting
-- operators (@≡@\/@+@) double since a symbol is far more discriminating
-- than an identifier. Asymmetric on purpose — @find_lemma@ is a
-- recall-first suggestion engine, so we score "how much of the goal does
-- this lemma cover", not symmetric similarity, and never penalise a
-- lemma for having a large signature.
weightedCoverage :: Set Text -> Set Text -> Double
weightedCoverage goal bag
  | den == 0  = 0
  | otherwise = num / den
  where
    w t = if isOpToken t then 2 else 1 :: Double
    den = sum [ w t | t <- Set.toList goal ]
    num = sum [ w t | t <- Set.toList goal, t `Set.member` bag ]

-- | 'weightedCoverage' with an extra per-token IDF multiplier: a token's
-- weight is its operator base (2 for a symbol, 1 for an identifier) times
-- @Map.findWithDefault 1.0 t idf@. So a rare identifier (a large IDF) out-votes
-- a ubiquitous one (@suc@\/@zero@, IDF ≈ 1). An __empty__ IDF map (or a token
-- absent from it) leaves every weight at its operator base, making this
-- byte-for-byte 'weightedCoverage' — the invariant the shipped ranker relies
-- on when IDF is off. See 'AgdaGraph.LemmaRank.computeIdf' for the map.
weightedCoverageIdf :: Map.Map Text Double -> Set Text -> Set Text -> Double
weightedCoverageIdf idf goal bag
  | den == 0  = 0
  | otherwise = num / den
  where
    w t = (if isOpToken t then 2 else 1) * Map.findWithDefault 1.0 t idf
    den = sum [ w t | t <- Set.toList goal ]
    num = sum [ w t | t <- Set.toList goal, t `Set.member` bag ]

-- | The retrieval feature bag of a (goal or signature) string: the match
-- tokens of its /conclusion/ (@keep@-filtered) unioned with the algebraic
-- 'shapeTokens'. The one definition of "a goal's tokens" — shared by the
-- lemma ranker ('AgdaGraph.LemmaRank.rankLemmaCandidatesWith') and Phase-2
-- premise selection ('AgdaGraph.PremiseSelect.featuresOf'), so
-- @sim(goal, n)@ compares like against like by construction.
goalFeatures :: (Text -> Bool) -> Text -> Set Text
goalFeatures keep s =
  matchTokens keep concl `Set.union` shapeTokens concl
  where concl = conclusionOf s

-- | Inverse document frequency over a set of token \"documents\":
-- @idf t = 1 + log (N / df t)@, where @N@ is the number of documents and
-- @df t@ how many contain @t@. A token in every document keeps weight 1 (no
-- boost, none dropped); a rare one is boosted; the empty corpus is the empty
-- map. Shared by the token-IDF ('AgdaGraph.LemmaRank.computeIdf', over
-- signature bags) and the premise-IDF ('AgdaGraph.PremiseSelect', over premise
-- sets), so the two weightings cannot drift.
idfOf :: [Set Text] -> Map.Map Text Double
idfOf docs
  | n == 0    = Map.empty
  | otherwise = Map.map (\c -> 1 + log (fromIntegral n / fromIntegral c)) df
  where
    n  = length docs
    df = Map.fromListWith (+) [ (t, 1 :: Int) | d <- docs, t <- Set.toList d ]

----------------------------------------------------------------------
-- Structural shape recognition (find_lemma, operator-only goals).
--
-- Bag-of-tokens cannot separate @+-comm@ from @+-assoc@ from
-- @+-identityʳ@: all three goals reduce to the tokens @{+, ≡}@. But the
-- goal's /shape/ names the property — @a ⊕ b ≡ b ⊕ a@ is commutativity,
-- @x ⊕ e ≡ x@ (with @e@ a literal) an identity — and the stored sigs
-- carry exactly that combinator (@Commutative@, @RightIdentity@, …). So
-- we recognise a handful of canonical equation shapes and inject the
-- matching @Algebra.Definitions@\/@Relation.Binary@ combinator token
-- into the goal bag. Heuristic and deliberately inexact — a suggestion,
-- not a proof.

-- | A bracket-aware, qualifier-stripped token of a goal conclusion, used
-- only by 'shapeTokens'.
data ShapeTok = TId !Text | TOp !Text | TLParen | TRParen
  deriving (Eq, Show)

-- | Flatten a conclusion into 'ShapeTok's: identifiers reduced to their
-- final component, operators underscore-normalised, the empty-list /
-- unit literal @[]@ captured as an identifier, brackets preserved for
-- depth tracking.
flattenShape :: Text -> [ShapeTok]
flattenShape = go . T.unpack
  where
    go [] = []
    go (c : cs)
      | isSpace c = go cs
      -- empty-list / unit literal  []  (or  [ ] )
      | c == '[', (']' : rest') <- dropWhile isSpace cs = TId "[]" : go rest'
      -- A RENDERING ARTEFACT, not a token: the producer prints an anonymous
      -- enclosing-section parameter as a lone U+22EF, and it reaches every
      -- consumer of a producer-rendered type (`defSig` in the lemma ranker
      -- and premise selection, `binders[i].type` in the argument report).
      -- Left in, it is an 'isOpChar' and therefore a top-level OPERATOR, so
      -- it outranks the real head: `AwaitingGS ⋯ s` came back headed by the
      -- placeholder rather than by the predicate. Dropped here so the whole
      -- shape vocabulary is free of it, not just one caller's view.
      | c == '\8943' = go cs
      | c `elem` openBracket  = TLParen : go cs
      | c `elem` closeBracket = TRParen : go cs
      | identStart c =
          let (tok, rest) = span identChar (c : cs) in resolveQual tok rest
      | isOpChar c =
          let (op, rest) = span isOpChar (c : cs) in TOp (normOp op) : go rest
      | otherwise = go cs
    -- Peel qualifier components off an identifier: ".<ident>" drops the
    -- current component; ".<op>" makes it a qualified operator.
    resolveQual tok rest = case rest of
      ('.' : d : _) | identStart d ->
        let (tok', rest') = span identChar (drop 1 rest) in resolveQual tok' rest'
      ('.' : d : _) | isOpChar d ->
        let (op, rest') = span isOpChar (drop 1 rest) in TOp (normOp op) : go rest'
      _ -> TId (T.pack tok) : go rest

-- | Indices of top-level (depth-0) relation operators in a shape-token
-- sequence.
relIndices :: [ShapeTok] -> [Int]
relIndices = go (0 :: Int) (0 :: Int)
  where
    relSet = Set.fromList ["≡", "≈", "=", "∼", "~"]
    go _ _ [] = []
    go d i (t : ts) = case t of
      TLParen                                 -> go (d + 1) (i + 1) ts
      TRParen                                 -> go (d - 1) (i + 1) ts
      TOp v | d == 0 && v `Set.member` relSet -> i : go d (i + 1) ts
      _                                       -> go d (i + 1) ts

-- | Recognise a goal conclusion's algebraic shape and return the
-- combinator token(s) it implies (empty when no shape is recognised).
shapeTokens :: Text -> Set Text
shapeTokens concl =
  case relIndices sq of
    [i] ->
      let lhs  = take i sq
          rhs  = drop (i + 1) sq
          lids = [ v | TId v <- lhs ]
          rids = [ v | TId v <- rhs ]
          lops = [ v | TOp v <- lhs ]
          rops = [ v | TOp v <- rhs ]
          -- one side a single term, the other that term combined with a
          -- literal identity element (@x ⊕ 0 ≡ x@, @xs ++ [] ≡ xs@).
          isIdent a b = length [ () | TId _ <- a ] == 1
                          && any (`Set.member` litSet) [ v | TId v <- b ]
          injIdent = isIdent lhs rhs || isIdent rhs lhs
          -- @a ⊕ b ≡ b ⊕ a@: one operator each side, same operands, swapped.
          injComm  = not (null lops) && lops == rops
                       && sort lids == sort rids && lids /= rids
                       && length (nub lops) == 1
          -- @(a ⊕ b) ⊕ c ≡ a ⊕ (b ⊕ c)@: same operator/operands, re-parenthesised.
          injAssoc = length (nub lops) == 1 && lops == rops
                       && lids == rids && length lops >= 2
          -- @f (f x) ≡ x@: rhs a single term, some head repeated on the lhs.
          injInvol = length rids == 1
                       && any (\h -> length (filter (== h) lids) >= 2) (nub lids)
          -- two distinct operators on one side: a distributivity law.
          injDist  = length (nub lops) >= 2 || length (nub rops) >= 2
      in Set.unions
           [ ifSet injIdent ["Identity", "RightIdentity", "LeftIdentity"]
           , ifSet injComm  ["Commutative"]
           , ifSet injAssoc ["Associative"]
           , ifSet injInvol ["Involutive"]
           , ifSet injDist  ["DistributesOver", "Distributive"] ]
    [] ->
      -- no relation operator: a bare relation applied, @R x x@ / @R x y z@.
      let ids = [ v | TId v <- sq ]
          ops = [ v | TOp v <- sq ]
      in if length ids == 2 && listSame ids && length ops == 1 then Set.singleton "Reflexive"
         else if length ids == 3 && length ops == 2           then Set.singleton "Transitive"
         else Set.empty
    _ -> Set.empty
  where
    sq       = flattenShape concl
    litSet   = Set.fromList ["0", "1", "zero", "[]", "true", "false", "ε", "∅"]
    ifSet b xs = if b then Set.fromList xs else Set.empty
    listSame (x : y : _) = x == y
    listSame _           = False

----------------------------------------------------------------------
-- Head symbol (find_lemma head-symbol pre-filter).

-- | The /head symbol/ of a (rendered) conclusion: the outermost thing the
-- goal is "about", used to keep an @_≤_@ goal from spending hint slots on
-- @_≡_@ lemmas. Precedence:
--
--   1. the first top-level (depth-0) __relation__ operator, if any
--      (@m + n ≡ n + m@ → @≡@, @xs ≤ ys@ → @≤@) — the connective binds
--      looser than the arithmetic beneath it, so it is the head;
--   2. else the first top-level operator (@a + b@ → @+@);
--   3. else the first top-level identifier — the applied predicate / type
--      constructor (@Even n@ → @Even@, @Sorted xs@ → @Sorted@).
--
-- Operators are underscore-normalised (so @_≤_@ matches @≤@) and qualifiers
-- stripped, reusing 'flattenShape'. Textual and lenient: 'Nothing' when the
-- conclusion flattens to nothing recognisable, so a caller comparing two
-- heads treats an unparsed side as "no signal" and never demotes on it.
headSymbol :: Text -> Maybe Text
headSymbol concl = listToMaybe (rels ++ topOps ++ topIds)
  where
    top    = topLevel (flattenShape concl)
    topOps = [ v | TOp v <- top ]
    topIds = [ v | TId v <- top ]
    rels   = [ v | v <- topOps, v `Set.member` headRelSet ]

-- | The depth-0 tokens of a shape-token stream (brackets drop the enclosed
-- run), so an arrow / operator nested inside @(…)@ never counts as the head.
topLevel :: [ShapeTok] -> [ShapeTok]
topLevel = go (0 :: Int)
  where
    go _ [] = []
    go d (t : ts) = case t of
      TLParen           -> go (d + 1) ts
      TRParen           -> go (d - 1) ts
      _ | d == 0        -> t : go d ts
        | otherwise     -> go d ts

-- | Operators that read as a goal's top-level relation (underscore-stripped,
-- so @_≡_@ ↦ @≡@). Curated and generous — a missed relation only costs a
-- head-match opportunity, never a wrong demotion, so erring toward inclusion
-- is safe.
headRelSet :: Set Text
headRelSet = Set.fromList
  [ "≡", "≢", "≈", "≉", "=", "≠", "∼", "~", "≅", "≃", "≡ᵇ"
  , "≤", "<", "≥", ">", "≮", "≰", "≱", "≲", "≳"
  , "∈", "∉", "∋", "⊆", "⊂", "⊇", "⊃", "⊈", "⊑", "⊒"
  , "↔", "⇔", "≟", "∣", "⇒", "⊢" ]
