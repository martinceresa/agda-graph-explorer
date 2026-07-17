{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The point queries the @agda-explore@ daemon answers over a loaded
-- graph. Everything here works off the in-memory 'Index' (and the raw
-- 'ExpandedGraph' for module→file lookups); only 'readSignature' touches
-- the filesystem, to recover a definition's type from source.
--
-- These are the queries Claude would otherwise approximate with @grep@:
-- /where is X/, /who calls X/, /what does X use/, /what breaks if I
-- change X/, /what's the type of X/, /what resembles X/.
module AgdaMcp.Query
  ( OutFmt(..)
  , parseFmt
  , queryLocate
  , queryBrief
  , queryCallers
  , queryCallees
  , queryImpact
  , queryPath
  , queryRoots
  , querySimilarTypes
  , querySimilarBodies
  , queryFindLemma
  , goalHintCands
  , querySearch
  , queryStats
  , readSignature
  , suggestions
  , nameInSnapshot
  , notInGraph
  , orphanWarning
  , listEnvelope
  ) where

import           Control.Exception  (SomeException, try)
import           Data.Aeson         (Value, object, (.=))
import           Data.Aeson.Types   (Pair)
import           Data.Aeson.Text    (encodeToLazyText)
import           Data.Char          (isDigit, isSpace)
import           Data.Maybe         (isJust)
import qualified Data.Set           as Set
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS
import           Data.List          (isPrefixOf, isSuffixOf, sortBy,
                                     sortOn)
import qualified Data.Map.Strict    as M
import           Data.Ord           (Down (..), comparing)
import qualified Data.Sequence      as Seq
import           Data.Sequence      (ViewL (..), (|>))
import           Data.Text          (Text)
import qualified Data.Text          as T
import qualified Data.Text.Lazy     as TL
import qualified Data.Vector        as V

import           AgdaGraph.Index
import           AgdaGraph.Schema   (Access (..), Definition (..),
                                     Kind (..),
                                     Provenance (..), State (..))
import           AgdaGraph.Similarity (SigBodyFingerprints (..), fingerprintSize)
import           AgdaGraph.WL       (weightedJaccard)
import           AgdaGraph.GoalCanon (conclusionOf, matchTokens,
                                     shapeTokens, stripQualifiers, baseComponent)
import           AgdaGraph.LemmaRank (RankEnv (..), LemmaScore,
                                     rankLemmaCandidates, goalCarrierSegments,
                                     moduleSegments)

import           AgdaMcp.State      (Loaded (..))

-- ---------------------------------------------------------------------
-- Small renderers
-- ---------------------------------------------------------------------

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Output format for the list queries ('querySearch' / 'queryCallers' /
-- 'queryCallees'). 'FmtText' (default) is the prose; 'FmtJson' a structured
-- envelope for scripting.
data OutFmt = FmtText | FmtJson
  deriving (Eq)

-- | @format@ arg → 'OutFmt' (anything but the literal @"json"@ is text).
parseFmt :: Maybe Text -> OutFmt
parseFmt (Just f) | T.toLower f == "json" = FmtJson
parseFmt _                                = FmtText

-- | Encode a JSON 'Value' to compact strict 'Text' (the text content of a
-- tool result under @format:json@).
jsonText :: Value -> Text
jsonText = TL.toStrict . encodeToLazyText

-- | One definition as a JSON object: the fields a list result carries, plus
-- an optional edge 'Provenance' (direct callers/callees only) and the
-- overlay origin tag when present. Mirrors the columns of 'oneLine'.
defItem :: Definition -> Maybe Provenance -> Value
defItem d mp = object $
  [ "name"   .= defName d
  , "module" .= defModule d
  , "kind"   .= renderKind (defKind d)
  , "state"  .= renderState (defState d)
  , "access" .= renderAccess (defAccess d)
  ]
  ++ [ "line"       .= l          | Just l <- [defLine d] ]
  ++ [ "unsafe"     .= defUnsafe d | not (null (defUnsafe d)) ]
  ++ [ "origin"     .= og         | Just og <- [defOrigin d] ]
  ++ [ "provenance" .= renderProv p | Just p <- [mp] ]

-- | The shared list-result JSON envelope: tool, echoed query, resolved
-- canonical name (if any), total match count, shown count (after @limit@),
-- and rows. @total@/@shown@ keep the @…and N more@ affordance. @extras@
-- appends tool-specific top-level pairs (e.g. @search@'s closure-coverage
-- count).
listEnvelope :: Text -> Value -> Maybe Text -> Int -> [Pair] -> [Value] -> Text
listEnvelope tool q resolved total extras items = jsonText $ object $
  [ "tool"  .= tool
  , "query" .= q
  , "total" .= total
  , "shown" .= length items
  , "items" .= items
  ]
  ++ [ "resolved" .= r | Just r <- [resolved] ]
  ++ extras

renderState :: State -> Text
renderState Defined   = "Defined"
renderState Postulate = "Postulate"
renderState Hole      = "Hole"
renderState Failed    = "Failed"

renderKind :: Kind -> Text
renderKind KFunction    = "function"
renderKind KProjection  = "projection"
renderKind KDatatype    = "datatype"
renderKind KRecord      = "record"
renderKind KConstructor = "constructor"
renderKind KPostulate   = "postulate"
renderKind KPrimitive   = "primitive"
renderKind KOther       = "other"

renderAccess :: Access -> Text
renderAccess Public  = "public"
renderAccess Private = "private"

-- | @L<line>@ locator (empty when unknown). The module is deliberately
-- omitted — it is already the prefix of the qualified name printed on the
-- same row, so repeating it wastes tokens on every list line.
loc :: Definition -> Text
loc d = maybe "" (("L" <>) . tshow) (defLine d)

-- | @/State@ suffix, empty for the common 'Defined' case — the signal is
-- the exception (Postulate / Hole / Failed), not the norm.
stateSuffix :: State -> Text
stateSuffix Defined = ""
stateSuffix s       = "/" <> renderState s

-- | @[external: <label>]@ tag for a def federated in from an overlay graph
-- (its 'defOrigin'); empty for a project def. Signals it needs an @open
-- import@, and that edge queries (callers/impact/path) don't reach it.
originSuffix :: Definition -> Text
originSuffix d = maybe "" (\o -> "  [external: " <> o <> "]") (defOrigin d)

-- | @[unsafe: non-terminating, trustme]@ tag for a def carrying a soundness
-- escape ('defUnsafe') — a direct @NON_TERMINATING@ / @primTrustMe@ escape,
-- or a file-level OPTIONS escape ('egModuleOptionEscapes', e.g.
-- @--type-in-type@) 'buildIndex' folded in from its module; empty for a safe
-- def. Makes an @agda --safe@-relevant escape visible wherever a def is
-- listed.
unsafeSuffix :: Definition -> Text
unsafeSuffix d = case defUnsafe d of
  [] -> ""
  us -> "  [unsafe: " <> T.intercalate ", " us <> "]"

oneLine :: Definition -> Text
oneLine d =
  "- `" <> defName d <> "` [" <> renderKind (defKind d)
        <> stateSuffix (defState d) <> "] " <> loc d
        <> unsafeSuffix d <> originSuffix d

-- | The distinct soundness-escape kinds ('defUnsafe') carried by a set of
-- node ids, sorted. Backs the transitive-taint banners.
escapeKinds :: Index -> [Int] -> [Text]
escapeKinds ix = Set.toAscList . Set.fromList . concatMap (defUnsafe . defAt ix)

-- | Render escape kinds for a banner: @non-terminating@ or
-- @non-terminating / trustme@.
renderKinds :: [Text] -> Text
renderKinds = T.intercalate " / "

-- | ⚠ transitive soundness-taint banner for @roots@: names the escapes a
-- definition rests on through its /dependency/ cone ('unsafeDeps'). A def's
-- own direct escape is deliberately left out — it already shows on the
-- @locate@ line and the 'unsafeSuffix' tag; the new, non-obvious signal is
-- a clean-looking theorem that reaches a @non-terminating@ / @trustme@ def
-- transitively. Empty when the cone is clean. Trailing blank line so it
-- sits above the answer body.
rootsTaintBanner :: Index -> Definition -> Text
rootsTaintBanner ix d = case unsafeDeps ix (defId d) of
  []           -> ""
  ids@(i0 : _) -> "⚠ soundness taint: `" <> defName d <> "` transitively rests on "
           <> tshow (length ids) <> " definition(s) using "
           <> renderKinds (escapeKinds ix ids)
           <> " (e.g. `" <> defName (defAt ix i0) <> "`), so it is not "
           <> "`agda --safe`. Run `roots " <> defName d
           <> " unsafe=any` for the witnessed chain(s).\n\n"

-- | ⚠ soundness-taint banner for @impact@: if the subject carries a direct
-- escape /or/ rests on one transitively, every definition that depends on
-- it inherits that unsoundness. Folds in the subject's own 'defUnsafe' (a
-- @NON_TERMINATING@ subject spreads even with a clean dependency cone),
-- unlike 'rootsTaintBanner'. Empty when the whole cone is clean.
impactTaintBanner :: Index -> Definition -> Text
impactTaintBanner ix d
  | not tainted = ""
  | otherwise   =
      "⚠ soundness taint: `" <> defName d <> "` "
        <> (if null (defUnsafe d) then "rests on a " else "carries a ")
        <> renderKinds (escapeKinds ix (defId d : depIds)) <> " escape — every "
        <> "dependent listed below transitively inherits it (not `agda --safe`).\n\n"
  where
    depIds  = unsafeDeps ix (defId d)
    tainted = not (null (defUnsafe d)) || not (null depIds)

-- | Bullet list of definitions, each annotated with its enclosing owner
-- when it's a @where@-/anonymous helper, truncated to @lim@ with a
-- trailing "…and N more". A provenance-free view of 'provBulletList'.
bulletList :: Loaded -> Int -> [Definition] -> Text
bulletList ld lim ds = provBulletList ld lim [ (d, Nothing) | d <- ds ]

-- ---------------------------------------------------------------------
-- Index helpers
-- ---------------------------------------------------------------------

-- | The real (non-synthetic) defs. Materialised once at snapshot
-- construction ('AgdaMcp.State.ldRealDefs') and read back here, rather
-- than re-sliced from the def vector on every query that scans it
-- (rankedMatches / resolveDefNote's fallback / querySearch / queryStats).
realDefs :: Loaded -> [Definition]
realDefs = ldRealDefs

directOut, directIn :: Index -> Int -> IS.IntSet
directOut ix i = IM.findWithDefault IS.empty i (idxForward ix)
directIn  ix i = IM.findWithDefault IS.empty i (idxReverse ix)

defsOf :: Loaded -> IS.IntSet -> [Definition]
defsOf ld is = [ defAt (ldIndex ld) i | i <- IS.toList is ]

notFound :: Loaded -> Text -> Text
notFound ld name =
  ("No definition named `" <> name <> "`.\n" <>
   case suggestions ld name 8 of
     []  -> "No similarly-named definitions found. Try the `search` tool with a substring."
     sug -> "Did you mean one of:\n" <> bulletList ld 8 sug)
  <> coverageNote ld

-- | The closure-coverage warning body for a set of orphan files (empty when
-- there are none). Shared by the empty-result note here ('coverageNote') and
-- the @status@ report, so the phrasing and the 3-file sample stay identical.
orphanWarning :: [FilePath] -> Text
orphanWarning [] = ""
orphanWarning fs =
  "⚠ " <> tshow (length fs) <> " source file(s) under the include roots are outside \
  \every entry's import closure, so their definitions are invisible to every query \
  \(e.g. " <> T.intercalate ", " (map T.pack (take 3 fs)) <> "). Add them to a barrel / \
  \entry root, or list them under `coverage-ignore:` in .agda-explore.yml."

-- | Appended to an /empty/ lookup result when the snapshot knows of source
-- files outside every entry's closure: an absent name is then "not in any
-- entry's closure", not "does not exist" (see 'orphanWarning'). Silent when
-- nothing is orphaned (the common case), so it stays high-signal.
coverageNote :: Loaded -> Text
coverageNote ld = case orphanWarning (ldOrphanFiles ld) of
  "" -> ""
  w  -> "\n\n" <> w

-- | Compact one-line closure-coverage footer for /non-empty/ answers of the
-- enumeration / cone tools (@search@ / @callers@ / @callees@ / @impact@ /
-- @roots@): results over a partial closure are still a partial answer, but
-- repeating the full 'orphanWarning' on every result would drown them.
-- Count-only; @status@ carries the detail. Empty when nothing is orphaned
-- (the common case), like 'coverageNote'.
coverageFootnote :: Loaded -> Text
coverageFootnote ld = case ldOrphanFiles ld of
  [] -> ""
  fs -> "\n(⚠ " <> tshow (length fs)
          <> " source file(s) outside the entry closure are invisible to "
          <> "this query — see `status`)"

-- | The structured JSON counterpart of 'coverageFootnote': the closure-
-- coverage count as an @unsearched_files@ envelope field, or @[]@ when
-- nothing is orphaned. Passed as 'listEnvelope' extras by the JSON branches
-- of @search@ / @callers@ / @callees@ so the signal is defined once.
orphanExtras :: Loaded -> [Pair]
orphanExtras ld = [ "unsearched_files" .= length fs | let fs = ldOrphanFiles ld, not (null fs) ]

-- | Does @name@ resolve to a definition in this snapshot? Uses the full
-- 'resolveDefNote' resolver (not bare 'lookupDef'), so a legitimately
-- resolvable short/dotted-suffix name (e.g. a bare @sq@ ↦ @Where.sq\@15@)
-- or a unique near-match (auto-resolve) counts as present. This is the
-- @type_of@ fast-path predicate ('AgdaMcp.Tools.withFreshFailFast'): when
-- it is 'False' against the already-loaded snapshot, the daemon answers
-- 'notInGraph' instantly instead of paying the 'ensureFresh' barrier.
nameInSnapshot :: Loaded -> Text -> Bool
nameInSnapshot ld name = isJust (resolveDefNote ld name)

-- | The @type_of@ fast-path "not in the current graph" message. Unlike
-- 'notFound' (used by @locate@), this names the configured entry
-- module(s) and explains import-closure scoping — a name absent here may
-- simply live outside the entries' reachable closure — pointing the user
-- at @search@ or a multi-entry configuration. The 'suggestions' /
-- "Did you mean" block is reused verbatim from 'notFound' so the
-- candidate list is identical. @entries@ is 'cfgEntries' from the live
-- config; empty in preloaded mode.
notInGraph :: Loaded -> [FilePath] -> Text -> Text
notInGraph ld entries name =
  notFound ld name <> "\n\n" <> scopeNote
  where
    scopeNote =
      "This name is not in the graph reachable from " <> entryDesc
        <> ". It may live outside the configured entries' import closure — "
        <> "try the `search` tool for a substring, or add the module to the "
        <> "graph (configure multiple entry roots / `--entry`)."
    entryDesc = case map T.pack entries of
      []  -> "(no entry configured — preloaded graph)"
      [e] -> "entry `" <> e <> "`"
      es  -> "entries " <> T.intercalate ", " (map (\e -> "`" <> e <> "`") es)

-- | Definitions whose (lower-cased) qualified name contains the query,
-- ranked by how tightly they match. Untruncated — callers take what they
-- need.
rankedMatches :: Loaded -> Text -> [Definition]
rankedMatches ld q =
  let q'  = T.toLower q
      base d = lastComp (defName d)
      hit d = q' `T.isInfixOf` T.toLower (defName d)
      score d
        | T.toLower (base d) == q'              = 0 :: Int
        | q' `T.isPrefixOf` T.toLower (base d)  = 1
        | q' `T.isInfixOf`  T.toLower (base d)  = 2
        | otherwise                             = 3
      -- defName is the final tiebreak so the order is a strict total order
      -- (independent of input order), not merely stable — the "did you mean"
      -- list and the unique-candidate auto-resolve both read this.
  in sortOn (\d -> (score d, T.length (defName d), defName d))
            (filter hit (realDefs ld))

-- | Top @lim@ ranked matches — the 'notFound' "did you mean" candidate list.
suggestions :: Loaded -> Text -> Int -> [Definition]
suggestions ld q lim = take lim (rankedMatches ld q)

-- | A where-block / anonymous-module local helper. As of producer
-- @nodeKeyVersion@ 3 such helpers are lifted into their named parent
-- module — the @._.@ anonymous-module marker is stripped — but the
-- @\@\<binding-line\>@ disambiguator the producer appends to them (and
-- only to them; 'AgdaDeps.Deps.nodeKey') survives, so that trailing tag
-- is the node-local signal. Keying on the tag (via 'stripLineTag') also
-- recognises pre-v3 names like @Mod._.helper\@15@, which carry it too.
-- 'querySearch' can drop these on request, since they crowd out
-- top-level results.
isLocalName :: Definition -> Bool
isLocalName d = stripLineTag (defName d) /= defName d

lastComp :: Text -> Text
lastComp t = let (_, suf) = T.breakOnEnd "." t in if T.null suf then t else suf

-- | Drop the @"\@<line>"@ disambiguator the producer appends to
-- @where@-/anonymous-module helper names ('AgdaDeps.Deps.nodeKey'), for
-- name-matching purposes only. @Mod.QED\@388@ ↦ @Mod.QED@ (v3; pre-v3
-- @Mod._.QED\@388@ ↦ @Mod._.QED@); names with no such suffix are returned
-- unchanged.
stripLineTag :: Text -> Text
stripLineTag t = case T.breakOnEnd "@" t of
  (pre, suf) | not (T.null pre), not (T.null suf), T.all isDigit suf
             -> T.dropEnd 1 pre
  _          -> t

-- | Is @needle@ a segment-aligned dotted suffix of @hay@? True for an
-- exact match or when @hay@ ends in @"." <> needle@ (so @liveness′@ and
-- @Theorem3.liveness′@ both match @…Theorem3.liveness′@, but @ness′@
-- does not).
isDottedSuffix :: Text -> Text -> Bool
isDottedSuffix needle hay =
  hay == needle || ("." <> needle) `T.isSuffixOf` hay

-- | Resolve a query name to a single definition, plus a one-line,
-- newline-terminated breadcrumb to prepend to the result. Tiers, in order:
--
--   1. exact fully-qualified match ('lookupDef');
--   2. a /unique/ segment-aligned dotted-suffix match (the documented "or
--      unique name" contract), with the helper @\@<line>@ disambiguator
--      stripped before comparison so a bare @sq@ still resolves
--      @Where.sq\@15@;
--   3. (gated by 'ldAutoResolveUnique', default on) a /unique near-match/:
--      resolve iff 'rankedMatches' — the very list the 'notFound' "Did you
--      mean" block draws from — has exactly one element, i.e. the only
--      thing standing between the user and an answer was a single
--      suggestion.
--
-- The breadcrumb is empty for the byte-identical exact (tier 1) and
-- unique-dotted-suffix (tier 2) tiers, so existing precise behaviour is
-- unchanged. Tier 3 emits @(auto-resolved \`<input>\` to \`<FQN>\`)@ so an
-- agent that typed a short or differently-cased name learns the canonical
-- name. Reusing 'rankedMatches' makes "auto-resolved" exactly "the
-- Did-you-mean block would have shown a single candidate"; ambiguity
-- (>= 2 candidates) stays ambiguous — tier 3 declines and the caller
-- renders the unchanged multi-candidate 'notFound'.
--
-- 'defId' of the returned definition equals its node id (see 'buildIndex'),
-- so callers can feed it straight into 'idxForward' / 'idxReverse' without
-- a second 'lookupId'.
resolveDefNote :: Loaded -> Text -> Maybe (Text, Definition)
resolveDefNote ld name = case lookupDef (ldIndex ld) name of
  Just d  -> Just ("", d)
  Nothing ->
    let name' = stripLineTag name
        matches d = let nm = stripLineTag (defName d)
                    in isDottedSuffix name' nm
        -- Any dotted-suffix match of @name'@ shares its final component, so
        -- look up just that base-name bucket instead of scanning every def.
        candidates = M.findWithDefault [] (lastComp name') (ldBaseNameIndex ld)
    in case filter matches candidates of
         [d] -> Just ("", d)
         _   -> aliasOrFuzzy
  where
    -- Tier 2.5: a @renaming@ re-export alias ('ldAliases') — not a
    -- graph node itself — resolves to the canonical def it renames. An
    -- exact alias hit beats the tier-3 fuzzy near-match below.
    aliasOrFuzzy
      | Just canonical <- M.lookup name (ldAliases ld)
      , Just d <- lookupDef (ldIndex ld) canonical
          = Just ("(`" <> name <> "` is a `renaming` alias for `" <> canonical <> "`)\n", d)
      -- Tier 3 (gated by 'ldAutoResolveUnique'): a unique near-match.
      | ldAutoResolveUnique ld, [d] <- rankedMatches ld name
          = Just ("(auto-resolved `" <> name <> "` to `" <> defName d <> "`)\n", d)
      | otherwise = Nothing

-- | The enclosing top-level definition of a @where@-/anonymous-module
-- helper: the nearest non-local def at or above the helper's start line,
-- in the helper's own module or an enclosing one. As of v3 the producer
-- re-homes such a helper into its nearest /named/ module (@Where.sq\@15@
-- lives in @Where@), so the owner is found
-- in the helper's own module or a prefix of it.
-- 'Nothing' for a non-local def, or when lines are unavailable.
ownerOf :: Loaded -> Definition -> Maybe Definition
ownerOf ld d
  | not (isLocalName d) = Nothing
    -- The owner relation is keyed by the local def's id and precomputed
    -- once per snapshot ('AgdaMcp.State.buildOwnerMap'), so this is an
    -- O(log n) lookup per rendered result line. 'defId' equals the node id
    -- (see 'buildIndex'), the same key the map is built under.
  | otherwise           = IM.lookup (defId d) (ldOwnerMap ld)

-- | @"  (in `owner`)"@ suffix for a local helper, else empty. Appended to
-- 'locate' / 'callers' / 'callees' lines so the enclosing top-level
-- definition is visible without opening the file.
ownerNote :: Loaded -> Definition -> Text
ownerNote ld d = case ownerOf ld d of
  Just o  -> " (in `" <> defName o <> "`)"
  Nothing -> ""

-- ** Filter-value parsers (Text -> enum), for the tool layer

parseKind :: Text -> Maybe Kind
parseKind t = case T.toLower t of
  "function"    -> Just KFunction
  "projection"  -> Just KProjection
  "datatype"    -> Just KDatatype
  "record"      -> Just KRecord
  "constructor" -> Just KConstructor
  "postulate"   -> Just KPostulate
  "primitive"   -> Just KPrimitive
  "other"       -> Just KOther
  _             -> Nothing

parseState :: Text -> Maybe State
parseState t = case T.toLower t of
  "defined"   -> Just Defined
  "postulate" -> Just Postulate
  "hole"      -> Just Hole
  "failed"    -> Just Failed
  _           -> Nothing

-- | Parse a user-facing @provenance@ filter value. @where@ is kept as a
-- legacy alias for @module-local@ (the v3 rename) and canonicalises onto
-- 'ProvModuleLocal', so a filter written either way matches edges of
-- either graph vintage (see 'provFilterEq').
parseProv :: Text -> Maybe Provenance
parseProv t = case T.toLower t of
  "signature"    -> Just ProvSignature
  "body"         -> Just ProvBody
  "module-local" -> Just ProvModuleLocal
  "where"        -> Just ProvModuleLocal  -- legacy alias
  "with"         -> Just ProvWith
  "unknown"      -> Just ProvUnknown
  _              -> Nothing

renderProv :: Provenance -> Text
renderProv ProvSignature   = "signature"
renderProv ProvBody        = "body"
renderProv ProvModuleLocal = "module-local"
renderProv ProvWhere       = "where"        -- only seen on v2 cache edges
renderProv ProvWith        = "with"
renderProv ProvUnknown     = "unknown"

-- | Edge-provenance equality for the user filter, collapsing the legacy
-- 'ProvWhere' tag (pre-v3 caches) onto its v3 rename 'ProvModuleLocal' so
-- a @provenance:module-local@ (or legacy @provenance:where@) filter
-- matches edges emitted by either producer vintage.
provFilterEq :: Provenance -> Provenance -> Bool
provFilterEq a b = norm a == norm b
  where norm ProvWhere = ProvModuleLocal
        norm x         = x

-- | @Just bad@ when a filter string was supplied but didn't parse.
badParse :: (Text -> Maybe a) -> Maybe Text -> Maybe Text
badParse p mt = mt >>= \t -> maybe (Just t) (const Nothing) (p t)

-- | Validate optional @kind@/@state@ filter strings shared by @search@
-- and @roots@; 'Just' a user-facing error naming the bad value, or
-- 'Nothing' when both parse (or are absent).
filterError :: Maybe Text -> Maybe Text -> Maybe Text
filterError mKindTxt mStateTxt =
  case (badParse parseKind mKindTxt, badParse parseState mStateTxt) of
    (Just bad, _) -> Just $ "Unknown kind filter `" <> bad <> "` — use one of function / "
                       <> "projection / datatype / record / constructor / postulate / primitive / other."
    (_, Just bad) -> Just $ "Unknown state filter `" <> bad
                       <> "` — use one of defined / postulate / hole / failed."
    _             -> Nothing

-- | @unsafe=@ escape-kind predicate shared by @search@ and @roots@:
-- @any@\/@true@\/empty ⇒ any escape present; a concrete tag ⇒ that tag.
unsafeMatches :: Text -> Definition -> Bool
unsafeMatches u d
  | u `elem` ["any", "true", ""] = not (null (defUnsafe d))
  | otherwise                    = u `elem` defUnsafe d

-- | Validate the optional @unsafe@ escape-kind filter shared by @search@
-- and @roots@: the enumerate-all aliases (@any@ / @true@ / empty) or a
-- concrete tag. 'Just' a user-facing error, or 'Nothing' when it parses
-- (or is absent).
unsafeFilterError :: Maybe Text -> Maybe Text
unsafeFilterError Nothing  = Nothing
unsafeFilterError (Just u)
  | u `elem` ["any", "true", "", "non-terminating", "trustme"] = Nothing
  -- A file-level OPTIONS escape flag ('egModuleOptionEscapes', folded into
  -- 'defUnsafe' by 'buildIndex') is any @--…@ token. Accepted structurally so
  -- the producer can add flags without a consumer edit; one no module uses
  -- simply matches nothing rather than erroring.
  | "--" `T.isPrefixOf` u = Nothing
  | otherwise = Just $ "Unknown unsafe filter `" <> u
      <> "` — use `any` (every escape), a declaration kind (non-terminating \
      \/ trustme), or a module OPTIONS flag (e.g. --type-in-type)."

-- | Module-subtree predicate: keep a definition when no prefix is given,
-- or its module starts with it. Shared by @search@ / @callers@ /
-- @callees@ / @roots@ / @path@.
modulePrefixPred :: Maybe Text -> Definition -> Bool
modulePrefixPred mp d = maybe True (`T.isPrefixOf` defModule d) mp

-- ---------------------------------------------------------------------
-- locate / callers / callees / impact
-- ---------------------------------------------------------------------

queryLocate :: Loaded -> Text -> Text
queryLocate ld name = case resolveDefNote ld name of
  Nothing -> notFound ld name
  Just (note, d)  -> (note <>) $
    let ix      = ldIndex ld
        i       = defId d
        synth   = i >= idxRealCount ix
        file    = M.lookup (defModule d) (ldModFiles ld)
        outI    = directOut ix i
        recursive = IS.member i outI
        nIn     = IS.size (IS.delete i (directIn  ix i))
        nOut    = IS.size (IS.delete i outI)
        transUp   = IS.size (ancestors   ix (IS.singleton i))
        transDown = IS.size (descendants ix (IS.singleton i))
    in T.unlines $
         [ "`" <> defName d <> "`"
         , "  location: " <> maybe (defModule d <> " (line unknown)")
                                   (\f -> T.pack f <> maybe "" ((":" <>) . tshow) (defLine d))
                                   file
         , "  kind:     " <> renderKind (defKind d)
                          <> ", state: " <> renderState (defState d)
                          <> ", access: " <> renderAccess (defAccess d)
                          <> (if recursive then " (recursive)" else "")
         ] ++
         [ "  unsafe:   " <> T.intercalate ", " (defUnsafe d)
             <> " (direct soundness escape — breaks `agda --safe`)"
         | not (null (defUnsafe d)) ] ++
         [ "  owner:    " <> defName o <> maybe "" ((":" <>) . tshow) (defLine o)
         | Just o <- [ownerOf ld d] ] ++
         [ "  origin:   external overlay `" <> og <> "` — needs an `open import` before use; \
           \graph-edge queries (callers/impact/path) do not cross into it"
         | Just og <- [defOrigin d] ] ++
         [ "  used by:  " <> tshow nIn <> " direct caller(s)"
         , "  uses:     " <> tshow nOut <> " direct dependency(ies)"
         , "  blast radius: " <> tshow transUp <> " transitive caller(s), "
                              <> tshow transDown <> " transitive dependency(ies)"
         ] ++
         [ "  note:     referenced but has no definition record "
             <> "(external, or compiler-generated)" | synth ]

-- | A one-call orientation bundle for a definition: the 'queryLocate' block,
-- its type signature, direct callers and callees (each capped at @lim@), and
-- its top body-twins. Pure composition of the point queries; resolves the name
-- once and drives every section off the canonical FQN, so the "(auto-resolved
-- …)" note appears at most once. Type comes from 'defSig' (else points at
-- @type_of@).
queryBrief :: Loaded -> Int -> Text -> Text
queryBrief ld lim name = case resolveDefNote ld name of
  Nothing        -> notFound ld name
  Just (note, d) ->
    let fqn = defName d
        cov = coverageFootnote ld
        -- The embedded callers/callees sub-blocks each append 'cov' when
        -- non-empty; strip it there so the orientation bundle carries the
        -- closure-coverage footer once, at the end, not per section.
        dropCov = if T.null cov then id else T.replace cov ""
        sig = case defSig d of
                Just t | not (T.null (T.strip t)) -> t
                _ -> "(no signature in the graph — run `type_of name=" <> fqn <> "`)"
        section h b = "── " <> h <> " ──\n" <> T.stripEnd b
        blocks =
          [ T.stripEnd (queryLocate ld fqn)
          , section "type"             sig
          , section "callers (direct)" (dropCov (queryCallers ld False Nothing Nothing False lim FmtText fqn))
          , section "callees (direct)" (dropCov (queryCallees ld False Nothing Nothing False lim FmtText fqn))
          , section "similar bodies"   (querySimilarBodies ld 3 0.3 fqn)
          ]
    in note <> T.intercalate "\n\n" blocks <> cov

queryCallers :: Loaded -> Bool -> Maybe Text -> Maybe Text -> Bool -> Int -> OutFmt -> Text -> Text
queryCallers = edgesQuery True

queryCallees :: Loaded -> Bool -> Maybe Text -> Maybe Text -> Bool -> Int -> OutFmt -> Text -> Text
queryCallees = edgesQuery False

-- | Provenance of the edge @s -> t@, if the graph carries per-edge tags.
edgeProv :: Index -> Int -> Int -> Maybe Provenance
edgeProv ix s t = idxEdgeProvenance ix >>= IM.lookup s >>= IM.lookup t

-- | Shared implementation of callers (reverse edges) and callees
-- (forward edges), direct or transitive. @mPrefix@ keeps only results
-- whose module starts with the given prefix; @mProvTxt@ keeps only direct
-- edges of a given provenance (signature/body/module-local/with/unknown;
-- @where@ is a legacy alias for @module-local@) and annotates each direct
-- line with its tag; @byMod@ renders a per-module
-- count summary instead of a flat list.
edgesQuery :: Bool -> Loaded -> Bool -> Maybe Text -> Maybe Text -> Bool -> Int -> OutFmt -> Text -> Text
edgesQuery wantReverse ld transitive mPrefix mProvTxt byMod lim fmt name =
  case mProvTxt of
    Just p | parseProv p == Nothing ->
      "Unknown provenance filter `" <> p
        <> "` — use one of signature / body / module-local / with / unknown \
           \(`where` accepted as a legacy alias for module-local)."
    _ -> case resolveDefNote ld name of
      Nothing        -> case fmt of
        FmtText -> notFound ld name
        FmtJson -> listEnvelope tool queryObj Nothing 0 [] []
      Just (note, d) -> render note d
  where
    tool  = if wantReverse then "callers" else "callees"
    queryObj = object $
      [ "name" .= name, "direction" .= tool, "transitive" .= transitive, "limit" .= lim ]
      ++ [ "module_prefix" .= p | Just p <- [mPrefix] ]
      ++ [ "provenance"    .= p | Just p <- [mProvTxt] ]
      ++ [ "by_module"     .= True | byMod ]
    mProv = mProvTxt >>= parseProv
    render note d =
      let ix  = ldIndex ld
          i   = defId d
          -- Direction-dependent pair: the subject's direct neighbours and
          -- the matching transitive closure (callers/reverse vs callees/
          -- forward). Picked once so the transitive branches don't repeat.
          (direct, closure)
            | wantReverse = (IS.delete i (directIn  ix i), ancestors   ix)
            | otherwise   = (IS.delete i (directOut ix i), descendants ix)
          -- provenance of the edge between neighbour j and the subject i
          provOf j | wantReverse = edgeProv ix j i
                   | otherwise   = edgeProv ix i j
          set
            -- Transitive + provenance: apply the filter to the *first
            -- hop* only — the frontier of direct edges of the requested
            -- kind — then take the closure of that frontier. Answers
            -- "who term-depends on X, transitively" (body) vs. mere
            -- type-level reachability.
            | transitive, Just p <- mProv =
                let frontier = IS.filter (\j -> maybe False (provFilterEq p) (provOf j)) direct
                in IS.delete i (IS.union frontier (closure frontier))
            | transitive  = closure (IS.singleton i)
            | otherwise   = direct
          -- Direct (non-transitive) provenance filter; the transitive
          -- case already folded the first-hop filter into 'set'.
          set' = case (transitive, mProv) of
            (False, Just p) -> IS.filter (\j -> maybe False (provFilterEq p) (provOf j)) set
            _               -> set
          ds  = sortOn defName
                  $ filter (modulePrefixPred mPrefix)
                  $ defsOf ld set'
          n   = length ds
          what | wantReverse = if transitive then "transitive callers (depend on)" else "direct callers (use)"
               | otherwise   = if transitive then "transitive dependencies (uses)" else "direct dependencies (uses)"
          scopeNote = maybe "" (\p -> " under `" <> p <> "`") mPrefix
          provNote  = case mProv of
            Just p | transitive -> " via first-hop `" <> renderProv p
                                     <> "` edges (then transitive)"
                   | otherwise  -> " with `" <> renderProv p <> "` provenance"
            Nothing             -> ""
          -- annotate direct lines with their edge provenance
          body
            | byMod      = moduleSummary 20 ds
            | transitive = bulletList ld lim ds
            | otherwise  = provBulletList ld lim [ (dx, provOf (defId dx)) | dx <- ds ]
      in case fmt of
           FmtText ->
             note <> (if n == 0
                        then "`" <> name <> "` has no " <> what <> scopeNote <> provNote <> "."
                        else tshow n <> " " <> what <> scopeNote <> provNote <> " of `" <> name <> "`:\n" <> body
                                 <> coverageFootnote ld)
           FmtJson ->
             -- provenance is a direct-edge notion (matches 'provBulletList'
             -- being used only on the direct, non-by_module branch).
             let wantProv = not transitive && not byMod
                 items = [ defItem dx (if wantProv then provOf (defId dx) else Nothing)
                         | dx <- take lim ds ]
             in listEnvelope tool queryObj (Just (defName d)) n (orphanExtras ld) items

-- | Like 'bulletList' but annotates each line with its edge provenance
-- (when the graph carries tags). Used for direct callers/callees.
provBulletList :: Loaded -> Int -> [(Definition, Maybe Provenance)] -> Text
provBulletList ld lim xs =
  let shown = take lim xs
      extra = length xs - length shown
      line (d, mp) = oneLine d <> ownerNote ld d
                       <> maybe "" (\p -> " {" <> renderProv p <> "}") mp
  in T.intercalate "\n" (map line shown)
       <> (if extra > 0 then "\n  …and " <> tshow extra <> " more" else "")

queryImpact :: Loaded -> Int -> Text -> Text
queryImpact ld lim name = case resolveDefNote ld name of
  Nothing -> notFound ld name
  Just (note, d) -> (note <>) $
    let ix     = ldIndex ld
        i      = defId d
        direct = IS.delete i (directIn ix i)
        trans  = ancestors ix (IS.singleton i)
        ds     = defsOf ld trans
        byMod  = countByModule ds
        topMods = take 12 (sortBy (comparing (Down . snd)) byMod)
    in if IS.null trans
         then "Changing `" <> name <> "` is safe: nothing depends on it."
         else (impactTaintBanner ix d <>) $ (<> coverageFootnote ld) $ T.unlines $
           [ "Changing `" <> name <> "` (its type/signature) could affect:"
           , "  " <> tshow (IS.size trans) <> " definition(s) transitively, "
                  <> tshow (IS.size direct) <> " directly."
           , ""
           , "Affected definitions by module (top " <> tshow (length topMods) <> "):"
           ] ++
           [ "  " <> m <> "  (" <> tshow n <> ")" | (m, n) <- topMods ] ++
           [ "", "Definitions:", bulletList ld lim (sortOn defName ds) ]

-- ---------------------------------------------------------------------
-- path  (why does A depend on B?)
-- ---------------------------------------------------------------------

-- | Shortest dependency chain(s) @from ⇝ to@ along forward (uses) edges:
-- the sequence @A → … → B@ that shows /why/ A transitively depends on B.
-- Each hop is annotated with its edge provenance, so
-- the chain reads e.g. @A —{body}→ H —{module-local}→ B@. With @k > 1@, up to
-- @k@ distinct shortest paths are returned (handy when the first runs
-- through a helper you don't care about); a non-positive @k@ is clamped
-- to 1 with an explicit note. @mPrefix@ constrains the
-- intermediate nodes to a module subtree.
queryPath :: Loaded -> Int -> Maybe Text -> Text -> Text -> Text
queryPath ld k mPrefix fromName toName =
  case (resolveDefNote ld fromName, resolveDefNote ld toName) of
    (Nothing, _) -> notFound ld fromName
    (_, Nothing) -> notFound ld toName
    (Just (noteA, a), Just (noteB, b)) -> (<>) (sideNote "from" noteA <> sideNote "to" noteB) $
      if defId a == defId b
      then
          "`" <> defName a <> "` and `" <> defName b <> "` are the same definition."
      -- A path answer (found or "no path") is only as complete as the closure:
      -- a real dependency link through an out-of-closure file would be missed,
      -- so flag partial coverage the same as the cone tools.
      else (<> coverageFootnote ld) $
          let ix    = ldIndex ld
              allow n = maybe True (`T.isPrefixOf` defModule (defAt ix n)) mPrefix
              paths = kShortestPathsVia ix allow (defId a) (defId b) kEff
              scope = maybe "" (\p -> " staying within `" <> p <> "`") mPrefix
          in kNote <> case paths of
            []       -> "No dependency path from `" <> defName a <> "` to `"
                          <> defName b <> "`" <> scope <> ": it does not "
                          <> "transitively use it" <> maybe "" (const " under that prefix") mPrefix
                          <> ".\n(Try `path` with the arguments swapped, "
                          <> (if mPrefix == Nothing then "or `impact`.)"
                                                    else "without `module_prefix`, or `impact`.)")
            (p0 : _) ->
              let multi  = length paths > 1
                  header = tshow (length p0 - 1) <> "-step shortest path"
                             <> (if multi then " (" <> tshow (length paths)
                                                    <> " distinct shown)" else "")
                             <> scope <> " (`" <> defName a <> "` uses … uses `"
                             <> defName b <> "`):\n"
              in header <> T.intercalate "\n\n"
                   [ (if multi then "[" <> tshow (j :: Int) <> "]\n" else "")
                       <> renderChain ix p
                   | (j, p) <- zip [1 ..] paths ]
  where
    kEff  = max 1 k
    kNote = if k < 1 then "(k=" <> tshow k <> " ≤ 0; clamped to 1)\n" else ""
    -- 'path' takes two names that resolve independently; tag the
    -- breadcrumb with which side ("from"/"to") was auto-resolved so the
    -- two cannot be confused. Empty note (exact / suffix tier) ⇒ no tag.
    sideNote side note
      | T.null note = ""
      | otherwise   = T.replace "(auto-resolved "
                                ("(auto-resolved " <> side <> "-name ") note

-- | Render a node-id path as an indented chain. Hops after the first are
-- prefixed with the provenance of the edge that justifies them
-- (@{body}@/@{module-local}@/@{signature}@/@{with}@/@?@ when untagged). Consecutive
-- @(source, target)@ pairs are taken once via @zip path (drop 1 path)@.
renderChain :: Index -> [Int] -> Text
renderChain ix path = case map (defAt ix) path of
  []         -> ""
  (d0 : drest) ->
    let provs = zipWith (\s t -> maybe "?" renderProv (edgeProv ix s t))
                        path (drop 1 path)
        first = "  `" <> defName d0 <> "`  " <> loc d0
        rest  = zipWith (\pv d -> "  —{" <> pv <> "}→ `" <> defName d <> "`  " <> loc d)
                        provs drest
    in T.intercalate "\n" (first : rest)

-- | Forward BFS distances from a single source, expanding only into
-- nodes the @ok@ predicate admits (pass @const True@ for an unfiltered walk).
bfsDistFiltered :: IM.IntMap IS.IntSet -> (Int -> Bool) -> Int -> IM.IntMap Int
bfsDistFiltered adj ok src = go (IM.singleton src 0) (Seq.singleton src)
  where
    go !acc q = case Seq.viewl q of
      EmptyL      -> acc
      cur :< rest ->
        let d            = IM.findWithDefault 0 cur acc
            nbrs         = IM.findWithDefault IS.empty cur adj
            (acc', next) = IS.foldl' step (acc, rest) nbrs
            step (!m, !qq) n
              | IM.member n m = (m, qq)
              | not (ok n)    = (m, qq)
              | otherwise     = (IM.insert n (d + 1) m, qq |> n)
        in go acc' next

-- | Forward BFS from @src@ returning a predecessor map (each reachable
-- node to its parent on a shortest path; @src@ maps to itself). One pass
-- serves many shortest-path reconstructions that share the source — see
-- 'queryRoots', which witnesses every root from a single tree.
bfsParents :: IM.IntMap IS.IntSet -> Int -> IM.IntMap Int
bfsParents adj src = go (IM.singleton src src) (Seq.singleton src)
  where
    go !parent q = case Seq.viewl q of
      EmptyL      -> parent
      cur :< rest ->
        let nbrs            = IM.findWithDefault IS.empty cur adj
            (parent', next) = IS.foldl' step (parent, rest) nbrs
            step (!p, !qq) n
              | IM.member n p = (p, qq)
              | otherwise     = (IM.insert n cur p, qq |> n)
        in go parent' next

-- | Reconstruct the shortest path @src ⇝ dst@ from a 'bfsParents' map.
-- 'Nothing' when @dst@ wasn't reached.
tracePath :: IM.IntMap Int -> Int -> Int -> Maybe [Int]
tracePath parent src dst
  | dst == src           = Just [src]
  | IM.member dst parent = Just (reverse (walk dst))
  | otherwise            = Nothing
  where
    walk n | n == src  = [src]
           | otherwise = n : walk (parent IM.! n)

-- | Up to @k@ distinct shortest paths @src ⇝ dst@, restricted to
-- intermediate nodes satisfying @allow@ (the endpoints are always
-- admitted). Enumerated by DFS over the BFS distance layers — only
-- following edges that advance exactly one layer toward @dst@ — so every
-- returned path is of minimal length; 'take k' bounds the lazy
-- enumeration. Powers @path@'s @k@ + @module_prefix@; @[]@ when
-- @dst@ is unreachable within @allow@.
kShortestPathsVia :: Index -> (Int -> Bool) -> Int -> Int -> Int -> [[Int]]
kShortestPathsVia ix allow src dst k =
  let okNode n = n == src || n == dst || allow n
      dist     = bfsDistFiltered (idxForward ix) okNode src
  in case IM.lookup dst dist of
       Nothing -> []
       Just l  -> take k (go dist l 0 src [src])
  where
    go dist l depth u acc
      | depth == l = [reverse acc | u == dst]
      | otherwise  =
          let nbrs = IM.findWithDefault IS.empty u (idxForward ix)
              next = [ w | w <- IS.toList nbrs
                         , IM.lookup w dist == Just (depth + 1) ]
          in concat [ go dist l (depth + 1) w (w : acc) | w <- next ]

-- ---------------------------------------------------------------------
-- roots  (which assumptions does T rest on?)
-- ---------------------------------------------------------------------

-- | The "assumptions" a definition ultimately rests on: its transitive
-- dependencies (callees) that are postulates / primitives — or that
-- match a supplied @kind@/@state@ — each with a shortest witnessing
-- chain. Turns "which axioms does theorem T depend
-- on?" into one call instead of hand-filtering @callees --transitive@
-- against the postulate list.
--
-- With @unsafe=@ it becomes a transitive soundness audit: the escapes the
-- subject rests on through its dependency cone ('unsafeDeps') — an
-- @agda --safe@-style check rooted at one theorem, each escape witnessed
-- by the chain that reaches it. Without a filter, a passive
-- 'rootsTaintBanner' still flags the taint so it is never silent.
queryRoots :: Loaded -> Int -> Bool -> Bool -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Text -> Text
queryRoots ld lim byMod chains mModPrefix mKindTxt mStateTxt mUnsafe name =
  case filterError mKindTxt mStateTxt of
    Just err -> err
    Nothing  -> case unsafeFilterError mUnsafe of
     Just err -> err
     Nothing  -> case resolveDefNote ld name of
      Nothing -> notFound ld name
      Just (note, d) -> (note <>) $
        let ix    = ldIndex ld
            i     = defId d
            reach = descendants ix (IS.singleton i)
            roots = sortOn defName
                      [ dx | j <- IS.toList reach
                           , let dx = defAt ix j
                           , isRoot dx
                           , modulePrefixPred mModPrefix dx ]
            n     = length roots
            descr = filterDescr mKindTxt mStateTxt mModPrefix
            -- No explicit filter ⇒ surface the transitive escape taint
            -- passively; with `unsafe=` the body already enumerates it.
            banner = if isJust mUnsafe then "" else rootsTaintBanner ix d
            -- One forward BFS from the subject builds the shortest-path
            -- tree; every root's witness chain is then a cheap backtrace
            -- through it, instead of a fresh BFS per root.
            parents = bfsParents (idxForward ix) i
            -- shortest forward chain i ⇝ root, backtraced through the
            -- shared BFS tree, indented under its bullet.
            witness ri = case tracePath parents i ri of
              Just p  -> "\n  " <> T.replace "\n" "\n  " (renderChain ix p)
              Nothing -> ""
            -- A per-module summary (byMod) and a chains-off list
            -- both trade the witness chains for a faster scan; chains
            -- are the default.
            body
              | byMod      = moduleSummary 25 roots
              | not chains = bulletList ld lim roots
              | otherwise  =
                  T.intercalate "\n\n"
                    [ "- `" <> defName r <> "`  [" <> renderKind (defKind r) <> "/"
                        <> renderState (defState r) <> "]  " <> loc r
                        <> witness (defId r)
                    | r <- take lim roots ]
                  <> (if n > lim then "\n\n  …and " <> tshow (n - lim) <> " more" else "")
            -- The per-module view leads with the grand total and
            -- the module count so the summary is self-contained.
            across = if byMod
                       then " across " <> tshow (length (countByModule roots)) <> " module(s)"
                       else ""
            tail'
              | n == 0    = "`" <> name <> "` transitively rests on no " <> descr <> "."
              | otherwise = tshow n <> " " <> descr <> across <> " under `" <> name
                              <> "` (transitive)"
                              <> (if byMod || not chains then ":"
                                                         else ", each with a witnessing chain:")
                              <> "\n" <> body <> coverageFootnote ld
        in banner <> selfNote d <> tail'
  where
    mKind  = mKindTxt  >>= parseKind
    mState = mStateTxt >>= parseState
    -- `unsafe=` (transitive soundness audit) takes precedence over the
    -- kind/state assumption predicate; kind/state still narrow it if both
    -- are given. No filter at all ⇒ paper-level assumptions.
    isRoot dx = case mUnsafe of
      Just u  -> unsafeMatches u dx
                   && maybe True (== defKind dx) mKind
                   && maybe True (== defState dx) mState
      Nothing -> case (mKind, mState) of
        (Nothing, Nothing) ->
          defState dx == Postulate || defKind dx `elem` [KPostulate, KPrimitive]
        _ -> maybe True (== defKind dx) mKind && maybe True (== defState dx) mState
    filterDescr mk ms mp =
      let core = case mUnsafe of
            Just u
              | u `elem` ["any", "true", ""] -> "soundness escape(s)"
              | otherwise                    -> u <> " escape(s)"
            Nothing -> case (mk, ms) of
              (Nothing, Nothing) -> "assumption(s) (postulate/primitive)"
              _ -> T.intercalate " " $ filter (not . T.null)
                     [ maybe "" ("kind=" <>) mk, maybe "" ("state=" <>) ms, "definition(s)" ]
      in core <> maybe "" (\p -> " in `" <> p <> "`") mp
    -- Flag when the queried node itself matches the assumption
    -- predicate — it won't appear among its own roots (a node is not its
    -- own transitive dependency), which would otherwise read oddly.
    selfNote d
      | not (isRoot d) = ""
      | Just _ <- mUnsafe =
          "(note: `" <> defName d <> "` itself carries [unsafe: "
            <> T.intercalate ", " (defUnsafe d)
            <> "]; a definition is not its own transitive dependency.)\n"
      | otherwise =
          "(note: `" <> defName d <> "` is itself ["
            <> renderKind (defKind d) <> "/" <> renderState (defState d)
            <> "]; a definition is not its own transitive dependency.)\n"

-- ---------------------------------------------------------------------
-- similar_types / similar_bodies
-- ---------------------------------------------------------------------

-- | Definitions whose type-signature /shape/ resembles the subject's,
-- ranked by weighted Jaccard of their Weisfeiler–Leman signature
-- fingerprints. The fingerprints are 'ldSigBodyFp' — the very same core
-- ('AgdaGraph.Similarity.buildSigBodyFingerprints') the batch @silhouette@
-- analysis clusters on — so a high-similarity pair here is exactly a
-- structural-twin candidate there (an equal fingerprint scores 1.0).
-- | The WL fingerprint sees only signature-graph topology, so unrelated
-- defs whose types merely share a shape (any @X → X → X@) collapse to
-- identical fingerprints and would score a confident 100%. When both
-- rendered signatures are present and differ (whitespace-insensitively),
-- cap the score just below 1 so only a true type match reads as exact
-- ('pctOf' rounds to one decimal, so anything above 0.99 could render
-- as 100%). No-op when either signature is absent — nothing to compare.
capDifferingSig :: Definition -> Definition -> Double -> Double
capDifferingSig a b s = case (norm <$> defSig a, norm <$> defSig b) of
  (Just x, Just y) | x /= y -> min 0.99 s
  _                         -> s
  where norm = T.unwords . T.words

-- | Shared Weisfeiler–Leman signature-fingerprint scoring behind
-- 'querySimilarTypes' and @find_lemma@'s anchor mode. Given an already-resolved
-- subject definition and a candidate predicate, returns either a
-- too-small-footprint message (keyed by @label@) or the scored candidates
-- (UNSORTED — each caller imposes its own ordering and rendering) plus the
-- provenance note. Both callers thus rank by the identical metric the
-- @silhouette@ analysis uses, by construction rather than by copy.
sigSimilarCands
  :: Loaded -> Text -> Definition -> Double -> (Definition -> Bool)
  -> Either Text ([(Double, Definition)], Text)
sigSimilarCands ld label d minSim keep =
  let ix   = ldIndex ld
      sbf  = ldSigBodyFp ld
      i    = defId d
      mine = sbfSig sbf V.! i
      size = fingerprintSize mine
  in if size < 2
       then Left ("`" <> label <> "` has too small a type-signature footprint ("
                    <> tshow size <> " WL-fingerprint node(s)) for a meaningful "
                    <> "type-similarity comparison.")
       else
         let cands = [ (s, dj)
                     | j <- [0 .. idxRealCount ix - 1], j /= i
                     , let dj = defAt ix j
                     , defKind dj /= KOther
                     , keep dj
                     , let s = capDifferingSig d dj
                                 (weightedJaccard mine (sbfSig sbf V.! j))
                     , s >= minSim ]
             provNote = if sbfHasProvenance sbf then ""
                        else "\n(note: graph lacks edge provenance, so the "
                             <> "signature/body split is unavailable — fingerprints "
                             <> "cover all edges, like `silhouette`'s fallback)"
         in Right (cands, provNote)

querySimilarTypes :: Loaded -> Int -> Double -> Text -> Text
querySimilarTypes ld lim minSim name = case resolveDefNote ld name of
  Nothing -> notFound ld name
  Just (note, d) -> (note <>) $
    case sigSimilarCands ld name d minSim (const True) of
      Left msg -> msg
      Right (cands, provNote) ->
        let ranked = take lim (sortBy (comparing (Down . fst)) cands)
        in if null ranked
             then "No definitions with signature-shape similarity ≥ "
                    <> tshow minSim <> " for `" <> name <> "`." <> provNote
             else "Definitions with a similar type-signature shape to `" <> name
                    <> "` (Weisfeiler–Leman signature fingerprint — the `silhouette` "
                    <> "metric):\n"
                    <> rankedList lim ranked <> provNote

-- | Definitions whose elaborated body shares canonical subterms with the
-- subject's, ranked by occurrence-weighted Jaccard of their subterm-hash
-- multisets. The multisets are 'ldSubtermFp' — the same per-def view the
-- batch @term-cluster@ analysis buckets over — so counting occurrences
-- (not mere membership) matches @term-cluster@'s notion of body structure.
querySimilarBodies :: Loaded -> Int -> Double -> Text -> Text
querySimilarBodies ld lim minSim name = case resolveDefNote ld name of
  Nothing -> notFound ld name
  Just (note, d) -> (note <>) $ case ldSubtermFp ld of
    Nothing ->
      "This graph carries no AST term-hashes, so body similarity is unavailable.\n"
        <> "Rebuild with term hashes enabled (the daemon does this by default; if you "
        <> "loaded a fixed --graph, regenerate it with `agda-deps --with-term-hashes`)."
    Just fps ->
      let ix = ldIndex ld
          i  = defId d
      in if i >= idxRealCount ix
           then "`" <> name <> "` is a referenced-only / synthetic node, so it has no "
                  <> "body to compare."
           else
             let mine = fps V.! i
                 size = fingerprintSize mine
             in if size < 2
                  then "`" <> name <> "` has too few hashed subterms ("
                         <> tshow size <> ") for a meaningful body comparison "
                         <> "(it may be a postulate, a trivial def, or below --min-term-depth)."
                  else
                    let cands = [ (s, defAt ix j)
                                | j <- [0 .. idxRealCount ix - 1], j /= i
                                , let s = weightedJaccard mine (fps V.! j)
                                , s >= minSim ]
                        ranked = take lim (sortBy (comparing (Down . fst)) cands)
                    in if null ranked
                         then "No definitions with AST-body overlap ≥ " <> tshow minSim
                                <> " for `" <> name <> "`."
                         else "Definitions with structurally similar bodies to `" <> name
                                <> "` (occurrence-weighted Jaccard of canonical subterm "
                                <> "hashes — the `term-cluster` view):\n"
                                <> rankedList lim ranked

rankedList :: Int -> [(Double, Definition)] -> Text
rankedList lim xs =
  T.intercalate "\n"
    [ "- " <> pctOf s <> "  `" <> defName d <> "`  ["
            <> renderKind (defKind d) <> "]  " <> loc d <> originSuffix d
    | (s, d) <- take lim xs ]

pctOf :: Double -> Text
pctOf s = T.pack (show (fromIntegral (round (s * 1000) :: Int) / 10 :: Double)) <> "%"

-- ---------------------------------------------------------------------
-- find_lemma  (goal-directed lemma search)
-- ---------------------------------------------------------------------

-- | Goal-directed lemma search: given /either/ a free-text goal type
-- /or/ an existing definition (the @anchor@) whose result type is the
-- goal shape, surface existing definitions whose conclusion (result
-- type) resembles the goal, so a proving agent can reuse a lemma rather
-- than hand-maintaining a memory inventory. Exactly one of @goal@ /
-- @anchor@ must be supplied; the @find_lemma@ tool enforces this before
-- calling here (this function trusts the precondition and treats
-- @anchor@-given as anchor mode, otherwise free-text mode keyed on
-- @goal@).
--
-- Two complementary code paths, both grounded in existing machinery:
--
--   * __Anchor mode__ (Weisfeiler–Leman fingerprints) reuses
--     'querySimilarTypes'' exact ranking core — weighted Jaccard over
--     the shared 'ldSigBodyFp' signature fingerprints — restricted by an
--     optional @kind@/@module_prefix@ filter, and annotates each hit
--     with its conclusion text. A WL fingerprint requires a graph node
--     with edges, which a free-text string is not, so only this path is
--     WL-based.
--
--   * __Free-text mode__ (goal→lemma retrieval) tokenises the goal's
--     'conclusionOf' with 'matchTokens' (qualifier-stripped, keeping
--     lowercase head symbols that are known definition names), augments
--     it with the goal's algebraic 'shapeTokens' (so @a+b ≡ b+a@ carries
--     @Commutative@), and ranks every real def carrying a 'defSig' by
--     operator-'weightedCoverage' of the goal tokens against the
--     candidate's conclusion tokens ∪ its 'nameTokens' (the def's own
--     name — often the stronger signal for stdlib's combinator-stated
--     lemmas). Ties break on 'tokenJaccard' then tighter signature. This
--     is a recall-first name/shape overlap proxy — NOT a proof a lemma
--     applies (use @anchor@ for WL type-shape). If /every/ def's 'defSig'
--     is 'Nothing' (graph built without @--with-signatures@) it returns
--     an explicit rebuild note, not a silent empty list.
--
-- All ranking sorts are total orders (similarity then name) so output is
-- reproducible.
queryFindLemma
  :: Loaded
  -> Int            -- ^ limit
  -> Double         -- ^ min similarity
  -> Maybe Text     -- ^ kind filter
  -> Maybe Text     -- ^ module_prefix filter
  -> Maybe Text     -- ^ goal (free-text mode)
  -> Maybe Text     -- ^ anchor (anchor mode)
  -> [Text]         -- ^ live context binder types (carrier affinity; @[]@ read-side)
  -> Text
queryFindLemma ld lim minSim mKindTxt mModPrefix mGoal mAnchor ctxTypes =
  case filterError mKindTxt Nothing of
    Just err -> err
    Nothing  -> case mAnchor of
      Just anchor -> anchorMode anchor
      Nothing     -> case mGoal of
        Just goal -> freeTextMode goal
        Nothing   -> "find_lemma requires exactly one of `goal` or `anchor`."
  where
    mKind = mKindTxt >>= parseKind
    -- shared candidate filter: optional kind + optional module prefix.
    candKeep d = maybe True (== defKind d) mKind && modulePrefixPred mModPrefix d
    filterNote = T.concat
      [ maybe "" (\k -> " kind=" <> k) mKindTxt
      , maybe "" (\p -> " module_prefix=" <> p) mModPrefix ]
    -- conclusion text annotation for a candidate (blank when no sig);
    -- module-qualifier-stripped for display (the shape is what matters).
    concSuffix d = case defSig d of
      Just sig -> let c = T.strip (stripQualifiers (conclusionOf sig))
                  in if T.null c then "" else " ⊢ " <> c
      _        -> ""

    -- ----------------------------------------------------------------
    -- Anchor mode: WL signature fingerprints (querySimilarTypes core).
    anchorMode anchor = case resolveDefNote ld anchor of
      Nothing        -> notFound ld anchor
      Just (note, d) -> (note <>) $
        case sigSimilarCands ld anchor d minSim candKeep of
          Left msg -> msg
          Right (cands, provNote) ->
            let ranked = take lim
                           (sortBy (comparing (\(s, dj) -> (Down s, defName dj))) cands)
            in if null ranked
                 then "No lemmas with signature-shape similarity ≥ "
                        <> tshow minSim <> " to `" <> anchor <> "`"
                        <> filterNote <> "." <> provNote
                 else "Candidate lemmas matching the type shape of `" <> anchor
                        <> "`" <> filterNote
                        <> " (Weisfeiler–Leman signature fingerprint — the `similar_types`/"
                        <> "`silhouette` metric):\n"
                        <> lemmaList Set.empty ranked <> provNote

    -- ----------------------------------------------------------------
    -- Free-text mode: qualifier-stripped name/shape tokens + operator-
    -- weighted coverage (see 'rankGoalCandidates'). Ranking lives in the
    -- shared top-level 'rankGoalCandidates' so `auto`'s Mimer-hint seeding
    -- ('goalHintCands') scores identically; this only renders it.
    freeTextMode goal =
      let vocab    = Set.fromList [ baseComponent (defName d) | d <- realDefs ld ]
          keep t   = t `Set.member` vocab
          concl    = conclusionOf goal
          gbase    = matchTokens keep concl        -- for the note only
          gshape   = shapeTokens concl             -- for the note only
          -- does ANY real def carry a signature at all? (ignores filters,
          -- so the "rebuild" note fires only on a truly sig-less graph.)
          anySig   = any (isJust . defSig) (realDefs ld)
          ranked   = take lim (rankGoalCandidates ld candKeep minSim goal ctxTypes)
          carrier  = goalCarrierSegments (RankEnv (realDefs ld) (ldAliases ld)) goal ctxTypes
          shapeNote
            | Set.null gshape = ""
            | otherwise       = "; shape: " <> renderTokens gshape
          weakNote = case ranked of
            ((sc, _) : _) | jac3 sc < 0.12 ->
              "\n(Weak lexical overlap — if none fit, try `search <name>` or "
                <> "ripgrep the goal fragment over the sources.)"
            _ -> ""
      in if not anySig
           then "This graph carries no type signatures, so free-text lemma "
                  <> "search is unavailable.\nRebuild with signatures enabled "
                  <> "(the daemon does this by default; if you loaded a fixed "
                  <> "--graph, regenerate it with `agda-deps --with-signatures`)."
           else if null ranked
             then "No lemma's conclusion or name resembles goal `" <> goal <> "`"
                    <> filterNote <> ".\nTry `search <name>` for a name substring, or "
                    <> "ripgrep the goal fragment over the sources.\n"
                    <> "(goal tokens: " <> renderTokens gbase <> shapeNote <> ")"
             else "Candidate lemmas for `" <> goal <> "`" <> filterNote
                    <> " (name/shape/coverage rank — a suggestion, not a proof; "
                    <> "`anchor` for WL type-shape):\n"
                    <> lemmaList carrier [ (prim3 sc, d) | (sc, d) <- ranked ]
                    <> "\n(goal tokens: " <> renderTokens gbase <> shapeNote <> ")"
                    <> weakNote

    -- score-tuple accessors: (weighted coverage, jaccard, affinity, -bagsize).
    prim3 (a, _, _, _) = a
    jac3  (_, b, _, _) = b

    renderTokens ts
      | Set.null ts = "(none)"
      | otherwise   = T.intercalate ", " [ "`" <> t <> "`" | t <- Set.toAscList ts ]

    -- one ranked bullet, with the matched conclusion annotation and, when
    -- the candidate's module shares a carrier segment with the goal, a
    -- `[carrier: …]` marker that differentiates an otherwise-flat menu.
    lemmaList carrierSegs ranked = T.intercalate "\n"
      [ "- " <> pctOf s <> " `" <> defName d <> "` ["
              <> renderKind (defKind d) <> stateSuffix (defState d)
              <> "] " <> loc d <> concSuffix d <> carrierSuffix carrierSegs d <> originSuffix d
      | (s, d) <- ranked ]

    carrierSuffix segs d
      | Set.null hit = ""
      | otherwise    = "  [carrier: " <> T.intercalate ", " (Set.toAscList hit) <> "]"
      where hit = Set.intersection segs (moduleSegments (defModule d))

-- | Ranked free-text goal candidates — the shared ranking core behind
-- free-text `find_lemma` (rendering, in 'queryFindLemma') and `auto`'s
-- Mimer-hint seeding ('goalHintCands'), so the two never diverge. A thin
-- adapter over 'rankLemmaCandidates' (in the shared @agda-graph@ library,
-- so the test-suite can exercise it): supplies the snapshot's defs +
-- @renaming@ aliases as a 'RankEnv'. @ctxTypes@ are the goal's live context
-- binder types (@[]@ on the read side); they steer carrier affinity only.
-- Empty when the graph carries no signatures.
rankGoalCandidates
  :: Loaded -> (Definition -> Bool) -> Double -> Text -> [Text]
  -> [(LemmaScore, Definition)]
rankGoalCandidates ld candKeep minSim goal ctxTypes =
  rankLemmaCandidates (RankEnv (realDefs ld) (ldAliases ld)) candKeep minSim goal ctxTypes

-- | Ranked @(base-name, source def)@ pairs to seed Mimer hints for a goal,
-- most relevant first, deduped on the base name (keeping the first, i.e.
-- highest-ranked, def). The base name is what Mimer takes (2.9 rejects a
-- qualified hint, and an out-of-scope hint aborts the whole search — so
-- `auto` tries them one at a time); the paired 'Definition' lets `auto`
-- name the defining module of an out-of-scope hint without a second
-- graph query. A modest coverage floor keeps junk out. Context-free
-- (@ctxTypes = []@) — but inherits the carrier-affinity tiebreak, so the
-- carrier-matching instance is tried first. Empty on a signature-less graph.
goalHintCands :: Loaded -> Int -> Text -> [(Text, Definition)]
goalHintCands ld n goal =
  take n (ordNubOn fst [ (baseComponent (defName d), d)
                       | (_, d) <- rankGoalCandidates ld (const True) 0.4 goal [] ])
  where
    ordNubOn key = go Set.empty
      where
        go _    []       = []
        go seen (x : xs)
          | key x `Set.member` seen = go seen xs
          | otherwise               = x : go (Set.insert (key x) seen) xs

-- | Base (final dotted component) of a qualified name
-- (@Data.Nat.Properties.+-comm@ → @+-comm@).

-- ---------------------------------------------------------------------
-- search / stats
-- ---------------------------------------------------------------------

-- | Substring search with optional structural filters. @q@ may be empty
-- when at least one of @mKind@ / @mState@ / @mUnsafe@ / @mModPrefix@ is
-- given — that lists every definition matching the filter (e.g.
-- @unsafe=any@ enumerates every soundness escape, an @agda --safe@-style
-- audit). @topLevelOnly@ drops @where@-/anonymous locals. Bad
-- kind/state filter values produce an explicit error.
querySearch :: Loaded -> Bool -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Int -> OutFmt -> Text -> Text
querySearch ld topLevelOnly mModPrefix mKindTxt mStateTxt mUnsafe lim fmt q =
  case filterError mKindTxt mStateTxt of
    Just err -> err
    Nothing
      | T.null q && mKind == Nothing && mState == Nothing
                 && mModPrefix == Nothing && mUnsafe == Nothing ->
          "Provide a `query` substring, or a `kind`/`state`/`module_prefix`/`unsafe` filter to list by."
      | otherwise ->
          let base   = if T.null q then realDefs ld else rankedMatches ld q
              kept   = filter keep base
              keep d = (not topLevelOnly || not (isLocalName d))
                         && maybe True (== defKind d)  mKind
                         && maybe True (== defState d) mState
                         && maybe True (\u -> unsafeMatches u d) mUnsafe
                         && modulePrefixPred mModPrefix d
              notes  = T.concat
                         [ if topLevelOnly then " (top-level only)" else ""
                         , maybe "" (\p -> " module_prefix=" <> p) mModPrefix
                         , maybe "" (\k -> " kind=" <> k) mKindTxt
                         , maybe "" (\s -> " state=" <> s) mStateTxt
                         , maybe "" (\u -> " unsafe=" <> u) mUnsafe ]
              subj   = if T.null q then "definitions" <> notes
                                   else "match(es)" <> notes <> " for `" <> q <> "`"
          in case fmt of
               FmtJson -> listEnvelope "search" queryObj Nothing (length kept)
                            (orphanExtras ld ++ aliasExtra)
                            [ defItem d Nothing | d <- take lim kept ]
               FmtText -> (<> aliasSection) $ case kept of
                 [] -> "No definitions" <> (if T.null q then "" else " matching `" <> q <> "`")
                         <> notes <> "." <> coverageNote ld
                 _  -> tshow (length kept) <> " " <> subj <> ":\n" <> bulletList ld lim kept
                         <> coverageFootnote ld
  where
    mKind  = mKindTxt  >>= parseKind
    mState = mStateTxt >>= parseState
    -- Re-export aliases ('ldAliases') whose host-qualified name matches
    -- the (non-empty) query as a substring — surfaced so `search combine`
    -- reveals a `Reexports.combine` alias for `Core.Base.merge` instead of
    -- silently returning only the unrelated real def of that short name.
    aliasHits
      | T.null q  = []
      | otherwise = [ (a, c) | (a, c) <- M.toList (ldAliases ld)
                             , T.toLower q `T.isInfixOf` T.toLower a ]
    aliasSection
      | null aliasHits = ""
      | otherwise = "\nrenaming re-export alias(es):\n"
          <> T.unlines [ "- `" <> a <> "` → `" <> c <> "`" | (a, c) <- aliasHits ]
    aliasExtra
      | null aliasHits = []
      | otherwise = [ "aliases" .= [ object [ "alias" .= a, "renames" .= c ]
                                   | (a, c) <- aliasHits ] ]
    queryObj = object $
      [ "query" .= q, "limit" .= lim, "top_level_only" .= topLevelOnly ]
      ++ [ "module_prefix" .= p | Just p <- [mModPrefix] ]
      ++ [ "kind"  .= k | Just k <- [mKindTxt] ]
      ++ [ "state" .= s | Just s <- [mStateTxt] ]
      ++ [ "unsafe" .= u | Just u <- [mUnsafe] ]

-- | Group definitions by their defining module, with a count each.
-- Shared by 'queryImpact' and 'moduleSummary'.
countByModule :: [Definition] -> [(Text, Int)]
countByModule ds =
  M.toList $ foldl' (\m dx -> M.insertWith (+) (defModule dx) (1 :: Int) m) M.empty ds

-- | Per-module count summary (the navigable view for large fan-out),
-- highest-count modules first. Used on request by 'queryCallers' /
-- 'queryCallees'.
moduleSummary :: Int -> [Definition] -> Text
moduleSummary topN ds =
  let byMod = countByModule ds
      tops  = take topN (sortBy (comparing (Down . snd)) byMod)
      extra = length byMod - length tops
  in T.intercalate "\n" [ "  " <> m <> "  (" <> tshow n <> ")" | (m, n) <- tops ]
       <> (if extra > 0 then "\n  …and " <> tshow extra <> " more module(s)" else "")

queryStats :: Loaded -> Text
queryStats ld =
  let ix      = ldIndex ld
      rds     = realDefs ld
      synth   = idxSyntheticCount ix
      nEdges  = IM.foldl' (\ !a s -> a + IS.size s) 0 (idxForward ix)
      mods    = ldModuleCount ld
      -- One pass over the defs: total count + per-state + per-kind tallies,
      -- rather than ~11 separate O(n) filters.
      (!n, !stateM, !kindM) =
        foldl' (\(!c, !sm, !km) d ->
                  ( c + 1
                  , M.insertWith (+) (defState d) (1 :: Int) sm
                  , M.insertWith (+) (defKind  d) (1 :: Int) km ))
               (0 :: Int, M.empty, M.empty) rds
      byState s = M.findWithDefault 0 s stateM
      byKind  k = M.findWithDefault 0 k kindM
  in T.unlines
       [ "Graph statistics:"
       , "  modules:      " <> tshow mods
       , "  definitions:  " <> tshow n <> " (+" <> tshow synth <> " referenced-only)"
       , "  edges:        " <> tshow nEdges
       , "  by state:     Defined " <> tshow (byState Defined)
                        <> ", Postulate " <> tshow (byState Postulate)
                        <> ", Hole " <> tshow (byState Hole)
                        <> ", Failed " <> tshow (byState Failed)
       , "  by kind:      function " <> tshow (byKind KFunction)
                        <> ", datatype " <> tshow (byKind KDatatype)
                        <> ", record " <> tshow (byKind KRecord)
                        <> ", constructor " <> tshow (byKind KConstructor)
                        <> ", projection " <> tshow (byKind KProjection)
                        <> ", postulate " <> tshow (byKind KPostulate)
       , "  failed mods:  " <> (if null (ldFailed ld) then "none"
                                 else T.intercalate ", " (ldFailed ld))
       ]

-- ---------------------------------------------------------------------
-- type_of  (reads source at the recorded line)
-- ---------------------------------------------------------------------

-- | A definition's type signature. By default returns the elaborated
-- type the producer reified into the graph (@--with-signatures@, the
-- daemon's default); @preferSource@ forces the as-written source text
-- instead (useful when the reified form expands numeric literals
-- and instance dictionaries). When no reified type is recorded we fall
-- back to source either way. @normalised@ / @showImplicit@ describe how
-- the reified type was built (daemon-level — they're baked into the
-- graph, so the disclaimer reports the mode rather than re-reifying).
--
-- @entries@ are the configured entry modules ('cfgEntries'), used only to
-- enrich the not-in-graph message so it matches the @type_of@ fast-path
-- ('AgdaMcp.Tools.withFreshFailFast') byte-for-byte — a name that vanishes
-- between the fast-path check and this call still renders the same text.
readSignature :: Loaded -> [FilePath] -> Bool -> Bool -> Bool -> Text -> IO (Either Text Text)
readSignature ld entries preferSource normalised showImplicit name = case resolveDefNote ld name of
  -- "Name not found" is a normal lookup outcome, not a tool error —
  -- return it as ordinary output so `type_of` matches `locate`. The
  -- genuine failures below (no source file, unreadable, no isolable
  -- signature) stay as 'Left'. The auto-resolution breadcrumb prefixes
  -- the 'Right' output only (a 'Left' is a genuine failure, no result
  -- to annotate).
  Nothing -> pure (Right (notInGraph ld entries name))
  Just (arNote, d) -> fmap (fmap (arNote <>)) $ case if preferSource then Nothing else defSig d of
    -- Authoritative path: the producer emitted the reified type. The
    -- disclaimer reflects the daemon's signature settings.
    Just t0 ->
      let t       = desugarLiterals t0
          locTxt  = maybe "" (\l -> "  (L" <> tshow l <> ")") (defLine d)
          normTxt = if normalised then "normalised" else "not normalised"
          impTxt  = if showImplicit then ", implicits shown" else ""
          litTxt  = if t /= t0 then ", literals de-sugared" else ""
      in pure (Right $ "`" <> defName d <> "`" <> locTxt <> "\n\n" <> t
                        <> "\n\n(elaborated, " <> normTxt <> impTxt <> litTxt
                        <> "; `source=true` for surface syntax)")
    -- Source path: forced by @preferSource@, or the fallback when no
    -- reified type was recorded. The disclaimer distinguishes the two.
    Nothing -> case M.lookup (defModule d) (ldModFiles ld) of
      Nothing -> pure (Left ("No source file recorded for module " <> defModule d <> "."))
      Just fp -> do
        e <- try (readFile fp) :: IO (Either SomeException String)
        case e of
          Left err -> pure (Left ("Cannot read " <> T.pack fp <> ": " <> T.pack (show err)))
          Right contents ->
            let ls    = lines contents
                baseS = T.unpack (lastComp (stripLineTag (defName d)))
                hdr   = "`" <> defName d <> "`  (" <> T.pack fp
                          <> maybe "" ((":" <>) . tshow) (defLine d) <> ")"
                note  = if preferSource
                          then "\n\n(from source; omit `source` for the elaborated type)"
                          else "\n\n(source-derived, best-effort; rebuild "
                                 <> "--with-signatures for the elaborated type)"
            in case extractSignature ls (defLine d) baseS of
                 Just sig -> pure (Right (hdr <> "\n\n" <> sig <> note))
                 Nothing  -> pure (Left
                   (hdr <> "\nCould not isolate a type signature from source"
                        <> " (it may be a generated projection/constructor, or a"
                        <> " definition without an explicit signature)."))

-- | Pull the signature block out of the file's lines. @mline@ is the
-- 1-based start line the producer recorded (may be 'Nothing').
extractSignature :: [String] -> Maybe Int -> String -> Maybe Text
extractSignature ls mline baseS =
  let arr        = V.fromList ls
      n          = V.length arr
      atIdx k    = arr V.!? k
      isSig l    = sigLineMatches baseS l
      -- candidate start indices: near the recorded line first, else scan all
      candidates = case mline of
        Just l  -> let i0 = l - 1
                   in [i0, i0 - 1, i0 + 1, i0 - 2, i0 + 2]
        Nothing -> [0 .. n - 1]
      starts     = [ k | k <- candidates, Just l <- [atIdx k], isSig l ]
  in case starts of
       (s : _) -> Just (grab arr n s)
       []      -> case [ k | k <- [0 .. n - 1], Just l <- [atIdx k], isSig l ] of
                    (s : _) -> Just (grab arr n s)
                    []      -> Nothing
  where
    grab arr n s =
      let startLine = arr V.! s
          ind0      = indentOf startLine
          body      = takeWhile (\k -> k == s || moreIndented arr ind0 k)
                                [s .. min (n - 1) (s + 40)]
          block     = [ arr V.! k | k <- body ]
      in T.stripEnd (T.pack (unlines block))
    moreIndented arr ind0 k =
      let l = arr V.! k
      in not (null (dropWhile isSpace l)) && indentOf l > ind0

indentOf :: String -> Int
indentOf = length . takeWhile (== ' ')

-- | Does this source line begin the signature for @baseS@?
-- Matches @name : …@, @data name …@, and @record name …@.
sigLineMatches :: String -> String -> Bool
sigLineMatches baseS line =
  let t = dropWhile isSpace line
  in nameThenColon t
       || ("data "   ++ baseS) `isPrefixOf` t
       || ("record " ++ baseS) `isPrefixOf` t
  where
    nameThenColon t = case stripPrefix' baseS t of
      Just rest -> let rest' = dropWhile (== ' ') rest
                   in ":" `isPrefixOf` rest' && not ("::" `isPrefixOf` rest')
      Nothing   -> False
    stripPrefix' p s = if p `isPrefixOf` s then Just (drop (length p) s) else Nothing

-- ---------------------------------------------------------------------
-- Literal de-sugaring for the elaborated type_of view
-- ---------------------------------------------------------------------

-- | Collapse @Number@-instance literal expansions in a reified type back
-- to the numeral. The elaborated printer renders @1@ as e.g.
-- @Fromℕ.fromℕ (mkFromℕ′ (fromℕ∶ id)) 1@; this rewrites that whole
-- application back to @1@.
--
-- Deliberately conservative and heuristic (no parser): it works over
-- space-separated /atoms/ (balanced @()@\/@{}@\/@[]@ groups kept whole),
-- and only rewrites a @…fromℕ@\/@…fromNat@\/@…fromInt@ head applied to a
-- few argument atoms terminating in a digit literal. Anything it doesn't
-- recognise is returned byte-for-byte unchanged, so a false negative is
-- the worst case.
desugarLiterals :: Text -> Text
desugarLiterals = T.pack . desugarStr . T.unpack

desugarStr :: String -> String
desugarStr = unwords . rewrite . map recurse . atomize
  where
    -- Recurse into balanced groups so a nested @(… fromℕ … 3)@ is
    -- de-sugared too; drop the now-redundant parens around a bare
    -- numeral so @(3)@ collapses to @3@.
    recurse a = case a of
      ('(' : r) | not (null r), last r == ')' -> wrap '(' ')' (init r)
      ('{' : r) | not (null r), last r == '}' -> wrap '{' '}' (init r)
      ('[' : r) | not (null r), last r == ']' -> wrap '[' ']' (init r)
      _                                        -> a
    wrap op cl inner =
      let inner' = desugarStr inner
      in if op == '(' && isNum inner' then inner' else op : inner' ++ [cl]
    rewrite [] = []
    rewrite (a : as)
      | isFromNat a = case collapse (0 :: Int) as of
          Just (numAtom, rest) -> numAtom : rewrite rest
          Nothing              -> a : rewrite as
      | otherwise   = a : rewrite as
    -- Consume up to a few argument atoms, terminating at a digit literal.
    collapse n xs
      | n > 4     = Nothing
      | otherwise = case xs of
          (y : ys) | isNum y   -> Just (y, ys)
                   | isArg y   -> collapse (n + 1) ys
                   | otherwise -> Nothing
          []                   -> Nothing
    isFromNat s = s `elem` ["fromℕ", "fromNat", "fromInt"]
                    || any (`isSuffixOf` s) [".fromℕ", ".fromNat", ".fromInt"]
    isNum s = not (null s) && all isDigit s
    isArg s = case s of
      (c : _) -> c `elem` ("({[" :: String) || isIdentStart c
      []      -> False
    -- An identifier-ish leading char: not a bracket, operator, space or
    -- digit. Operators (e.g. ≥, →, |) abort the collapse — we never eat
    -- across them.
    isIdentStart c = c == '_'
      || not (c `elem` (opChars ++ "({[)}]") || isSpace c || isDigit c)
    opChars = "=<>:;,|→≥≤" :: String

-- | Split a string on spaces while keeping balanced @()@\/@{}@\/@[]@
-- groups together as single atoms. Input is already single-space
-- normalised by the producer, so re-joining atoms with 'unwords' is
-- faithful.
atomize :: String -> [String]
atomize = go (0 :: Int) ""
  where
    go _ acc [] = [reverse acc | not (null acc)]
    go d acc (c : cs)
      | c == ' ' && d <= 0 = (if null acc then id else (reverse acc :)) (go 0 "" cs)
      | otherwise          = go (d + delta c) (c : acc) cs
    delta c | c `elem` ("({[" :: String) =  1
            | c `elem` (")}]" :: String) = -1
            | otherwise                  =  0
