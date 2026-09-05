{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE RecordWildCards   #-}
-- | The unused-import analysis, decoupled from input / output. Inputs
-- are the expanded JSON view ('ExpandedGraph') and source-side import
-- scans ('ImportLine'); outputs are 'Finding's that the renderer in
-- @Main@ formats.
module AgdaUnused.Analysis
  ( Finding(..)
  , FindingKind(..)
  , Confidence(..)
  , GroupBy(..)
  , parseGroupBy
  , parseConfidence
  , kindTag
  , confTag
  , analyse
  , renderFindingLine
  , argumentsJson
  , flaggedPositions
  , premiseFamilies
  ) where

import           Control.Applicative        ( (<|>) )
import           Control.DeepSeq            ( NFData(..), rnf )
import           Control.Parallel.Strategies ( parBuffer, rdeepseq, using )
import           Data.Graph      ( SCC(..), stronglyConnComp )
import qualified Data.Map.Strict as M
import           Data.Maybe      ( fromMaybe, isJust )
import qualified Data.Set        as S
import           Data.Text       ( Text )
import qualified Data.Text       as T

import qualified Data.Aeson        as A

import           AgdaGraph.Schema  ( ArgUsage(..), ArgBinder(..), BinderHiding(..)
                                   , abInserted, argRemovableAlone
                                   , argOnSignatureLine, argWritten
                                   , argLocalEdit, argRemovalBlocked
                                   , erasureEnabledFor, egDescribesArgBinders )
-- The producer's node-key naming convention has ONE owner; the source-text
-- lookups here must strip the @\@line@ tag with the same function the
-- daemon's name resolver uses, or they answer for a name no file contains.
import           AgdaGraph.Index   ( stripLineTag )
-- The premise-family grouping keys on the same "head symbol of a
-- proposition" the lemma ranker uses, rather than a second notion of it.
import           AgdaGraph.GoalCanon ( headSymbol, baseComponent )
import           AgdaUnused.Json   ( ExpandedGraph(..), Definition(..), Kind(..), Access(..), ReExport(..) )
import           AgdaUnused.Source ( ImportLine(..), scanImports, bodyTokensSplit )

-- | Per-finding payload. The 'fileFinding' is an absolute path; the
-- caller decides whether to display it relative to a project root.
data Finding = Finding
  { fileFinding   :: !FilePath
  , lineFinding   :: !Int
  , kindFinding   :: !FindingKind
  , moduleFinding :: !Text
  , symbolFinding :: !(Maybe Text)
  , noteFinding   :: !(Maybe Text)
  , confFinding   :: !Confidence
    -- ^ Confidence in the finding. Currently only the 'DefinedDead'
    -- branch ever downgrades to 'Low' (when the def's body is trivial,
    -- so the elaborator may have inlined it — see 'ctxTrivialBody');
    -- every other finding is 'High'.
  , argsFinding   :: !(Maybe ArgUsage)
    -- ^ The producer's per-argument evidence, on 'ArgRemovable' /
    -- 'ArgErasable' findings only ('Nothing' everywhere else). Carried so
    -- @--format=json@ can emit the /positions/, not just the prose note:
    -- a consumer that wants to act on a finding — the offline
    -- delete-and-retypecheck check, or a cascade loop — needs the indices
    -- and 'argRemovableAlone''s deletion set, and re-deriving them means
    -- re-reading the graph the report was built from.
    --
    -- The finding's 'kindFinding' selects which list applies: 'auRemovable'
    -- or 'auErasable'.
  } deriving (Show)

-- | How much trust to place in a finding. Surfaced as a parenthetical
-- in plain-text output and as a @"confidence"@ key in @--json-out@.
-- An agent should verify 'Low'-confidence @dead@ findings (they may be
-- inlined callees the dependency graph dropped) but can treat 'High'
-- ones as safe.
data Confidence = High | Low
  deriving (Show, Eq, Ord)

instance NFData Confidence where
  rnf c = c `seq` ()

data FindingKind
  = UnusedInUsing
    -- ^ A name in @open import M using (n₁; …; nₖ)@ is never referenced
    -- in the file body.
  | UnusedBlanketOpen
    -- ^ A blanket @open import M@ (no @using@) where every symbol M
    -- exports goes unused in the file body. Best-effort: relies on
    -- the agda-deps definition graph identifying any qname under M
    -- that's used by a definition in the current file.
  | DefinedDead
    -- ^ Defined here and has NO callers at all (not even intra-module).
    -- Strong signal for deletion.
  | DefinedInternalOnly
    -- ^ Defined here, has intra-module callers, but no cross-module
    -- user. Wrap in @private@ for scoping clarity, or leave as-is if
    -- intentionally public utility. NOT a deletion candidate.
  | FieldNeverProjected
    -- ^ A record-field projection ('KProjection') with no callers
    -- anywhere. Exactly the 'DefinedDead' evidence, but a different
    -- action: the fix is to remove the FIELD from its record, not to
    -- delete a definition — so it gets its own kind rather than a
    -- deletion suggestion the user cannot act on. Always 'Low'
    -- confidence: a no-eta record matched positionally reads its
    -- fields without ever applying the projection, and that use is
    -- invisible in the graph.
  | ArgRemovable
    -- ^ The definition has arguments Agda's own occurrence/polarity
    -- analysis proved it never uses: the binder and the argument at
    -- every call site can go. One finding per definition, not per
    -- position — the unit of action is the refactor, and positions that
    -- must be deleted together are named in the note.
    --
    -- Deleting a binder changes the definition's __type__, so this is a
    -- spec change rather than a refactor. For a theorem that is the win
    -- (a lemma with a dead hypothesis is a worse lemma); for an exported
    -- definition the arity is the contract, which is what the confidence
    -- grades — see 'containedDeletion'.
  | ArgErasable
    -- ^ Arguments unused in the body but still relevant to the type: an
    -- @\@0@ candidate rather than a removal. Far more common than
    -- 'ArgRemovable' (26.3% of definitions versus 0.87%, measured on the
    -- standard library), which is why it has its own @--kinds@ token and
    -- is not in the default set.
  | DuplicateUsingForModule
    -- ^ Two separate @open import M using (...)@ lines in the same
    -- file. Consolidation candidate.
  | PublicWithoutDownstream
    -- ^ @open import M using (n) public@ where @n@ has no user in any
    -- other module of the project. The re-export is dead.
  deriving (Show, Eq, Ord)

instance NFData FindingKind where
  rnf k = k `seq` ()

-- | The stable string tag for a 'FindingKind'. The single source of
-- truth shared by @--json-out@ (the @"kind"@ key) and grouping by
-- kind, so the two never drift apart.
kindTag :: FindingKind -> Text
kindTag UnusedInUsing           = "unused-in-using"
kindTag UnusedBlanketOpen       = "unused-blanket-open"
kindTag DefinedDead             = "defined-dead"
kindTag DefinedInternalOnly     = "defined-internal-only"
kindTag FieldNeverProjected     = "field-never-projected"
kindTag ArgRemovable            = "arg-removable"
kindTag ArgErasable             = "arg-erasable"
kindTag DuplicateUsingForModule = "duplicate-using"
kindTag PublicWithoutDownstream = "public-no-downstream"

-- | How to aggregate the flat finding list for @--group-by@. @GByDir@
-- buckets by the directory of each finding's (relativised) file path,
-- @GByFile@ by the whole file path, @GByKind@ by 'kindTag'.
data GroupBy = GByDir | GByFile | GByKind | GByPremise
  deriving (Show, Eq)

instance NFData GroupBy where
  rnf g = g `seq` ()

-- | The stable string tag for a 'Confidence' — the @confidence@ JSON key,
-- the @--min-confidence@ / @min-confidence:@ value, and the
-- @--show-defaults@ skeleton all spell it this way.
confTag :: Confidence -> Text
confTag High = "high"
confTag Low  = "low"

-- | Parse a @--min-confidence@ / @min-confidence:@ token. Beside
-- 'parseGroupBy' for the same reason: the CLI and the YAML loader must not
-- hand-roll one two-valued enum twice and disagree about a spelling.
parseConfidence :: String -> Either String Confidence
parseConfidence "low"  = Right Low
parseConfidence "high" = Right High
parseConfidence s      = Left $ "unknown confidence: " ++ s ++ " (want low|high)"

-- | Parse a @--group-by@ / @group-by:@ token. Mirrors 'parseKinds'
-- error style ("unknown …: <token>") so the CLI and YAML report the
-- same message on a bad value.
parseGroupBy :: String -> Either String GroupBy
parseGroupBy "dir"  = Right GByDir
parseGroupBy "file" = Right GByFile
parseGroupBy "kind" = Right GByKind
parseGroupBy "premise" = Right GByPremise
parseGroupBy s      = Left $ "unknown group-by: " ++ s

instance NFData Finding where
  rnf (Finding a b c d e f g h) =
    rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e `seq` rnf f
      `seq` rnf g `seq` rnf h

-- ** Top-level driver

analyse :: ExpandedGraph -> [(FilePath, Text)] -> [Finding]
-- ^ @analyse graph fileBodies@ — @fileBodies@ is the list of
-- @(absolute-path, raw-file-contents)@ pairs to inspect. The graph
-- carries the agda-deps definition/edge data the analyser needs.
analyse graph fileBodies =
  let ctx       = buildContext graph fileBodies
      perFile   = [ findingsForFile ctx fp | (fp, _) <- fileBodies ]
      sparked   = perFile `using` parBuffer 32 rdeepseq
  in concat sparked

-- ** Internal context shared across files

data Context = Context
  { ctxModuleByFile     :: !(M.Map FilePath (S.Set Text))
    -- ^ Reverse of 'egModuleFiles'. A single file can host several
    -- modules (e.g. @Lemma7.agda@ produces both
    -- @Protocol...Lemma7@ and the anonymous wrapper
    -- @Protocol...Lemma7._@); we keep all of them so the per-file
    -- checks consider defs across every hosted module.
  , ctxDefShortByModule :: !(M.Map Text (S.Set Text))
    -- ^ Module name -> set of *short* identifier names defined in it
    -- (last dot-component of the qname).
  , ctxUsersOfModule    :: !(M.Map Text (S.Set Text))
    -- ^ For each module M, the set of OTHER modules that reference any
    -- qname inside M. Used by the "no downstream user" check.
  , ctxUsedQNames       :: !(M.Map Text (S.Set (Text, Text)))
    -- ^ For each user-module M, the set of (target-module, short-name)
    -- pairs M references. Precise (module-qualified) usage: the analyser
    -- uses it where short-name ambiguity (same symbol exported by multiple
    -- modules) matters.
  , ctxUsersOfQName     :: !(M.Map (Text, Text) (S.Set Text))
    -- ^ For each (module, short-name) qname, the set of other modules
    -- that reference it. Used for the public-re-export check.
  , ctxIntraModUsedQ    :: !(M.Map (Text, Text) (S.Set Text))
    -- ^ For each (module, short-name) qname, the set of *intra-module*
    -- caller short-names. Lets the @defined@ check distinguish
    -- genuinely-dead names (no callers anywhere) from internal-only
    -- names (intra-module callers, no cross-module user). Self-edges
    -- are excluded (a def is not its own caller) — they land in
    -- 'ctxSelfRecursive' instead.
  , ctxSelfRecursive    :: !(S.Set (Text, Text))
    -- ^ (module, short-name) of every definition with a graph
    -- self-edge (a recursive call). The @dead@ check uses it to skip
    -- the in-file token-count fallback: a recursive def's own RHS
    -- mentions would otherwise read as evidence of use, shielding
    -- dead recursive defs from the deletion-candidate flag.
  , ctxDeadCycles       :: !(M.Map (Text, Text) (S.Set Text))
    -- ^ (module, short-name) -> the OTHER short-names in the same
    -- dead mutual-recursion cycle. A key is present iff the def
    -- belongs to an intra-module SCC of size >= 2 that no external
    -- entry reaches (no member has a cross-module / re-export user, or
    -- an intra-module caller from outside the SCC). One level up from
    -- 'ctxSelfRecursive': the members are only each other's callers, so
    -- the graph shows intra-module callers yet the cycle is dead as a
    -- unit. The @dead@ check treats a keyed def as 'DefinedDead' and
    -- names the mapped peers in the finding note.
  , ctxRxShortsByHost   :: !(M.Map Text (S.Set Text))
    -- ^ For each *host* module @H@ (the module that bears the
    -- @open … public@), the set of *short* names @H@ surfaces in its
    -- public namespace. Used by the blanket-open check: when a file
    -- imports @H@ blanket, anything in its body that overlaps these
    -- shorts is a real use of the open.
  , ctxRxBySourceQ      :: !(M.Map (Text, Text) (S.Set Text))
    -- ^ For each (source-module, short-name) qname, the set of host
    -- modules that re-export it. Used by the @defined@ check to widen
    -- the set of users via re-export chains.
  , ctxRxByHost         :: !(M.Map Text (S.Set Text))
    -- ^ For each *host* module @H@, the set of source modules @M@ such
    -- that @H@ has at least one public re-export sourced from M.
  , ctxRxShortsByPair   :: !(M.Map (Text, Text) (S.Set Text))
    -- ^ For each @(host, source)@ pair, the set of short names @host@
    -- surfaces from @source@. Used by the public-re-export blanket
    -- check.
  , ctxSourceTokens     :: !(M.Map FilePath (S.Set Text))
    -- ^ Per-file body tokens (the result of 'bodyTokens'). Used to
    -- suppress @dead@ false-positives when Agda's elaborator inlined
    -- the callee: the dependency graph loses the edge, but the source
    -- text still mentions the qname's short name. If any *other*
    -- source file mentions the flagged short name, the finding is
    -- demoted from "deletion candidate" to a kept false-positive.
  , ctxImportFreeTokens :: !(M.Map FilePath (S.Set Text))
    -- ^ Per-file body tokens with the __import lines removed__ — the
    -- haystack for the import-usage checks, which must not count a
    -- symbol's own @using (…)@ clause as a use of it. Derived from the
    -- same walk as 'ctxSourceTokens' (see 'bodyTokensSplit'), because the
    -- @dead@ suppression above wants the opposite answer: there an
    -- @import@ mention IS fair evidence of use.
  , ctxImports          :: !(M.Map FilePath [ImportLine])
    -- ^ Per-file @open import@ / @import@ statements ('scanImports').
    -- Kept here so the per-file check path does not re-scan text the
    -- context build already walked.
  , ctxTokenToFiles     :: !(M.Map Text (S.Set FilePath))
    -- ^ Inverted 'ctxSourceTokens': token -> the files whose body mentions
    -- it, so 'mentionedCrossFile' is an O(log) lookup.
  , ctxSourceBodies     :: !(M.Map FilePath Text)
    -- ^ Per-file raw body text. Used to count token occurrences in
    -- the def's own file (same-file inliner case: a name appearing
    -- both as its definition and as an inlined call mention is still
    -- used; the elaborated form just lost the edge).
  , ctxDefLineByQ       :: !(M.Map (Text, Text) Int)
    -- ^ (module, short-name) -> binding-site line, when the producer
    -- supplied one. Drives 'lineFinding' for def-level findings.
  , ctxDefAccessByQ     :: !(M.Map (Text, Text) Access)
    -- ^ (module, short-name) -> declared access. Absent entries default
    -- to 'Public'. Used to suppress the @internal-only@ "wrap in
    -- private" suggestion for names already declared @private@.
  , ctxTrivialBody      :: !(S.Set (Text, Text))
    -- ^ (module, short-name) of every definition with a *trivial body*,
    -- a proxy for "the elaborator may have inlined this callee" (the
    -- schema has no clause count). A def is trivial iff
    -- @defKind == KFunction@ AND its 'egSubtermHashes' row has length
    -- <= 1 AND the maximum 'egSubtermDepths' entry is <= 3. Empty when
    -- the producer wasn't run with @--with-term-hashes@ (the subterm
    -- arrays are absent) — in that case we never fabricate triviality,
    -- so every @dead@ finding stays 'High'. Drives both the Phase A
    -- confidence downgrade and the Phase B synthetic-user suppression.
  , ctxProjections      :: !(S.Set (Text, Text))
    -- ^ (module, short-name) of every 'KProjection' definition — a
    -- record field's projection function. A dead one is reported as
    -- 'FieldNeverProjected' rather than 'DefinedDead': same evidence,
    -- but the edit is to the record, not to the projection.
  , ctxProjectionLive   :: !(S.Set (Text, Text))
    -- ^ (module, short-name) of every 'KProjection' with a __real__ user.
    --
    -- The generic user set can never be empty for a projection, so
    -- 'FieldNeverProjected' could not fire without this: a record has a
    -- body edge to each of its own fields (its type mentions them), and
    -- the enclosing module re-exports them — 1,698 of agda-stdlib's 1,702
    -- projections sit in a @reexports@ row. Both are structure, not use.
    --
    -- This set drops exactly those two and nothing else: an edge from any
    -- source other than the owning record counts, and so does a re-export
    -- by any module other than the one that automatically surfaces the
    -- field. Scoped to projections deliberately — for an ordinary
    -- definition a re-export /is/ a use, and the generic path still says
    -- so.
  , ctxArgBindersKnown  :: !Bool
    -- ^ Does this graph's producer describe binders at all — any
    -- 'auBinders' entry or any 'auSyntacticArity'?
    --
    -- The first shipped @argUsage@ emitted @{removable, removableRequires,
    -- erasable, arity}@ and nothing else, and on such a graph a missing
    -- binder entry carries NO information: it cannot be read as "this
    -- position is past the signature line" the way it can on a modern one.
    -- Probed once over the whole graph rather than per definition, because
    -- per definition the two cases are identical — and a def whose every
    -- reported position is unwritten is exactly the case worth labelling.
  , ctxEffectiveOptions :: !(M.Map Text [Text])
    -- ^ The producer's @moduleEffectiveOptions@: which
    -- actionability-relevant Agda options are in force per top-level
    -- module. Read through 'erasureEnabledFor', which resolves a submodule
    -- against its enclosing modules; NOT a pragma scan, since @--erasure@
    -- normally lives in the @.agda-lib@'s @flags:@ line where no per-file
    -- scan can see it. Empty on a graph from a producer predating the
    -- field — the same answer as a project that enables it nowhere, and
    -- the conservative one for advice (@\@0@) that is otherwise a syntax
    -- error.
    --
    -- The MAP, deliberately, not a partially-applied 'egErasureFor': a
    -- closure here would keep the whole decoded graph — every definition,
    -- edge and subterm array — reachable for as long as the 'Context'
    -- lives, and would make this record un-'force'-able.
  , ctxArgUsage         :: !(M.Map (Text, Text) ArgUsage)
    -- ^ (module, short-name) -> the producer's per-argument usage
    -- evidence, for the definitions that have any. Absent for every def
    -- on a graph from a producer predating the field, so the
    -- 'ArgRemovable' \/ 'ArgErasable' checks yield nothing there rather
    -- than guessing.
  }

buildContext :: ExpandedGraph -> [(FilePath, Text)] -> Context
buildContext graph@ExpandedGraph{..} bodies =
  let moduleByFile = M.fromListWith S.union
        [ (p, S.singleton m) | (m, p) <- M.toList egModuleFiles ]

      -- ONE clean-and-walk per file, yielding the import statements and
      -- both token sets. This is the tool's heaviest per-file work
      -- (unpack → strip block comments → strip line comments → tokenise),
      -- so it happens exactly once rather than once per consumer.
      perFile = [ (p, (imps, bodyTokensSplit (S.fromList (map ilLine imps)) b))
                | (p, b) <- bodies, let imps = scanImports b ]
      sourceTokens = M.fromList [ (p, allToks) | (p, (_, (allToks, _))) <- perFile ]
      importFree   = M.fromList [ (p, freeToks) | (p, (_, (_, freeToks))) <- perFile ]
      importsByFile = M.fromList [ (p, imps) | (p, (imps, _)) <- perFile ]
      sourceBodies = M.fromList bodies

      -- Inverted index: token -> files that mention it (order-independent
      -- 'S.union' fold, determinism-safe), for an O(log) 'mentionedCrossFile'.
      tokenToFiles = M.fromListWith S.union
        [ (t, S.singleton p) | (p, toks) <- M.toList sourceTokens, t <- S.toList toks ]

      -- Index each definition by its module via the *qname's prefix*,
      -- not 'defModule', so we agree with how 'shortNameOf' splits.
      defShortByMod =
        foldl' (\ !acc d -> addDef d acc) M.empty egDefinitions
      addDef d =
        let m  = defModule d
            sh = shortNameOf (defName d) m
        in M.insertWith S.union m (S.singleton sh)

      -- (module, short-name) -> binding-site line, when the producer
      -- supplied one. Used to attach line numbers to defined / public
      -- findings without further source scanning.
      defLineByQ :: M.Map (Text, Text) Int
      defLineByQ = M.fromList
        [ ((defModule d, shortNameOf (defName d) (defModule d)), l)
        | d <- egDefinitions
        , Just l <- [defLine d]
        ]

      -- (module, short-name) -> producer-declared access. Absent
      -- entries are treated as 'Public' downstream (the schema default).
      defAccessByQ :: M.Map (Text, Text) Access
      defAccessByQ = M.fromList
        [ ((defModule d, shortNameOf (defName d) (defModule d)), defAccess d)
        | d <- egDefinitions
        ]

      -- (module, short-name) of every trivial-bodied function. Built by
      -- zipping each definition with its parallel 'egSubtermHashes' /
      -- 'egSubtermDepths' rows (index @i@ of every array describes the
      -- @i@-th definition). When the producer did not emit the subterm
      -- arrays they are @[]@; 'zip3' then yields no rows, the set stays
      -- empty, and NOTHING is treated as trivial — never fabricate
      -- triviality on older JSON. Order-preserving 'S.fromList' over a
      -- deterministic zip keeps this gate-safe.
      trivialBody :: S.Set (Text, Text)
      trivialBody = S.fromList
        [ (defModule d, shortNameOf (defName d) (defModule d))
        | (d, hs, ds) <- zip3 egDefinitions egSubtermHashes egSubtermDepths
        , defKind d == KFunction
        , length hs <= 1
        , maxDepth ds <= 3
        ]
      maxDepth :: [Int] -> Int
      maxDepth [] = 0
      maxDepth xs = maximum xs

      -- (module, short-name) of every record-field projection. Keyed
      -- the same way as 'defLineByQ' so the @dead@ check can ask
      -- "is this qname a field?" without a second name split.
      projections :: S.Set (Text, Text)
      projections = S.fromList
        [ (defModule d, shortNameOf (defName d) (defModule d))
        | d <- egDefinitions
        , defKind d == KProjection
        ]

      -- Projections with a user that is not their own record and not the
      -- automatic re-export by the module that encloses them. See
      -- 'ctxProjectionLive'. The edge half rides 'ingestEdge'; the
      -- re-export half reads 'rxBySrcQ', so both derive their short names
      -- exactly the way every other index does.
      projectionLive :: S.Set (Text, Text)
      projectionLive = S.union projLiveEdges $ S.fromList
        [ k
        | (k@(src, _sh), hosts) <- M.toList rxBySrcQ
        , k `S.member` projections
        -- The module enclosing the record surfaces its fields
        -- automatically; a re-export from anywhere else is a real user.
        , any (/= moduleOfQName src) (S.toList hosts)
        ]

      -- Only the defs that actually carry the optional per-def object,
      -- so the map is empty on a pre-field graph and the checks fire on
      -- nothing at all.
      argUsageByQ :: M.Map (Text, Text) ArgUsage
      argUsageByQ = M.fromList
        [ ((defModule d, shortNameOf (defName d) (defModule d)), au)
        | d <- egDefinitions
        , Just au <- [defArgUsage d]
        ]

      -- Per-edge ingest, building the usage indices in one pass.
      -- Intra-module edges populate 'intraModUsedQ' ((mod,callee) -> caller
      -- shorts), used by the @defined@ check to distinguish dead vs
      -- internal-only AND — since SCCs are transpose-invariant — as the
      -- call graph the dead-cycle pass ('computeDeadCycles') runs over.
      -- Self-edges are excluded (a recursive call is not a caller, so
      -- counting it would shield a dead recursive def from the @dead@
      -- check) and remembered in 'selfRec0' ('ctxSelfRecursive') instead.
      ingestEdge (src, dst) (!usersMod, !usedQ, !usersQ, !intraQ, !selfRec, !projLive) =
        let srcMod = moduleOfQName src
            dstMod = moduleOfQName dst
            dstSh  = shortNameOf dst dstMod
            srcSh  = shortNameOf src srcMod
            -- A record has a body edge to each of its own projections (its
            -- type mentions its fields); the owning record's qname IS the
            -- projection's module. That is structure, not use, so it is
            -- the one edge 'projectionLive' does not count. Accumulated
            -- here rather than in a second pass because it is the only
            -- consumer that needs the source QNAME, which the indices
            -- below discard.
            !pl | src /= dstMod
                , (dstMod, dstSh) `S.member` projections
                = S.insert (dstMod, dstSh) projLive
                | otherwise = projLive
        in if srcMod == dstMod
              then if src == dst
                then
                  let !s = S.insert (dstMod, dstSh) selfRec
                  in (usersMod, usedQ, usersQ, intraQ, s, pl)
                else
                  let !i = M.insertWith S.union (dstMod, dstSh)
                             (S.singleton srcSh) intraQ
                  in (usersMod, usedQ, usersQ, i, selfRec, pl)
              else
                let !u1 = M.insertWith S.union dstMod (S.singleton srcMod) usersMod
                    !u2 = M.insertWith S.union srcMod (S.singleton (dstMod, dstSh)) usedQ
                    !u3 = M.insertWith S.union (dstMod, dstSh)
                            (S.singleton srcMod) usersQ
                in (u1, u2, u3, intraQ, selfRec, pl)

      (usersMod0, usedQ0, usersQ0, intraModUsedQ0, selfRec0, projLiveEdges) =
        foldl' (\acc e -> ingestEdge e acc)
               (M.empty, M.empty, M.empty, M.empty, S.empty, S.empty) egDefinitionEdges

      -- Re-export indices. For every row @(host, source, [qualified-names])@
      -- we build three orientations: by source-module, by (source, short),
      -- and by host. The producer already collapses chains to the
      -- ultimate (host, source) pair, so the host/source modules are
      -- straight columns; only the per-name short-name extraction needs
      -- doing here.
      rxRows :: [(Text, Text, S.Set Text)]
      rxRows =
        [ (host, src, S.fromList shorts)
        | ReExport { rxFrom = host, rxTo = src, rxNames = qns } <- egReExports
        , let shorts = map (`shortNameOf` src) qns
        ]

      rxShortsByHost :: M.Map Text (S.Set Text)
      rxShortsByHost = M.fromListWith S.union
        [ (host, shorts) | (host, _src, shorts) <- rxRows ]

      rxBySrcQ :: M.Map (Text, Text) (S.Set Text)
      rxBySrcQ = M.fromListWith S.union
        [ ((src, sh), S.singleton host)
        | (host, src, shorts) <- rxRows
        , sh <- S.toList shorts
        ]

      rxByHost :: M.Map Text (S.Set Text)
      rxByHost = M.fromListWith S.union
        [ (host, S.singleton src) | (host, src, _) <- rxRows ]

      rxShortsByPair :: M.Map (Text, Text) (S.Set Text)
      rxShortsByPair = M.fromListWith S.union
        [ ((host, src), shorts) | (host, src, shorts) <- rxRows ]

      -- Dead mutual-recursion cycles: per-module SCC pass over the
      -- intra-module call graph (self-edges already excluded), keeping
      -- only SCCs no external entry reaches (see 'computeDeadCycles').
      deadCycles0 =
        computeDeadCycles intraModUsedQ0 usersQ0 rxBySrcQ

  in Context
       { ctxModuleByFile     = moduleByFile
       , ctxDefShortByModule = defShortByMod
       , ctxUsersOfModule    = usersMod0
       , ctxUsedQNames       = usedQ0
       , ctxUsersOfQName     = usersQ0
       , ctxIntraModUsedQ    = intraModUsedQ0
       , ctxSelfRecursive    = selfRec0
       , ctxDeadCycles       = deadCycles0
       , ctxRxShortsByHost   = rxShortsByHost
       , ctxRxBySourceQ      = rxBySrcQ
       , ctxRxByHost         = rxByHost
       , ctxRxShortsByPair   = rxShortsByPair
       , ctxSourceTokens     = sourceTokens
       , ctxImportFreeTokens = importFree
       , ctxImports          = importsByFile
       , ctxTokenToFiles     = tokenToFiles
       , ctxSourceBodies     = sourceBodies
       , ctxDefLineByQ       = defLineByQ
       , ctxDefAccessByQ     = defAccessByQ
       , ctxTrivialBody      = trivialBody
       , ctxProjections      = projections
       , ctxProjectionLive   = projectionLive
       , ctxArgBindersKnown  = egDescribesArgBinders graph
       , ctxEffectiveOptions = egModuleEffectiveOptions
       , ctxArgUsage         = argUsageByQ
       }

-- ** Per-file logic

-- Takes no body: every per-file input this needs (the import statements and
-- both token sets) was derived from ONE walk of the text in 'buildContext'.
findingsForFile :: Context -> FilePath -> [Finding]
findingsForFile ctx fp = case M.lookup fp (ctxModuleByFile ctx) of
  Nothing       -> []     -- file isn't in the graph; skip.
  Just thisMods ->
    -- A file can host multiple module names (the user-facing
    -- @Module.M@ plus anonymous wrappers @Module.M._@ that
    -- parameterised opens introduce). Source-level checks (imports,
    -- duplicate-using) run once against the body; graph-level checks
    -- (defined, public-reexport) run once per *user-facing* hosted
    -- module so each module's defs are surveyed for cross-module
    -- users — but skip anonymous-wrapper modules (qnames containing a
    -- @._@ segment) because their members are by construction
    -- internal section helpers, never intended to be cross-module
    -- used; flagging them is pure noise.
    -- Both the import list and the import-free token set come from ONE walk
    -- of the cleaned text in 'buildContext': this is the per-file hot path.
    let imports     = M.findWithDefault [] fp (ctxImports ctx)
        -- The import-usage checks need a haystack WITHOUT the import
        -- statements. 'bodyTokens' deliberately covers the whole file, so
        -- against it every symbol in a `using (…)` clause is trivially
        -- "mentioned" by that clause itself, and `unused-in-using` — a
        -- DEFAULT kind, and this tool's namesake check — cannot fire at all.
        importToks  = M.findWithDefault S.empty fp (ctxImportFreeTokens ctx)
        primary     = S.findMin thisMods  -- deterministic representative
        userFacing  = S.filter (not . isAnonymousModule) thisMods
    in concatMap (perImportFindings ctx fp primary importToks) imports
    ++ duplicateUsingFindings fp imports
    ++ concat
         [ definedButUnused ctx fp m shorts
         ++ unusedArguments ctx fp m shorts
         ++ publicReexportFindings ctx fp m imports
         | m <- S.toList userFacing
         , let shorts = M.findWithDefault S.empty m (ctxDefShortByModule ctx)
         ]

-- | A module name like @Foo.Bar._@ or @Foo._.Bar@ designates an
-- anonymous section wrapper Agda introduced (parameterised-module
-- application, anonymous @module _ where@). Its members are not part
-- of the user-facing API.
--
-- Only pre-v3 producer output carries @_@ segments; v3+ re-homes them into
-- the nearest named module.
isAnonymousModule :: Text -> Bool
isAnonymousModule m = "._" `T.isInfixOf` m || "._" `T.isSuffixOf` m

perImportFindings :: Context -> FilePath -> Text -> S.Set Text -> ImportLine -> [Finding]
perImportFindings ctx fp thisMod bodyToks (ImportLine{..}) =
  case ilUsing of
    Just syms -> concatMap (checkUsing ctx fp thisMod bodyToks ilLine ilModule) syms
    Nothing   -> checkBlanket ctx fp thisMod bodyToks ilLine ilModule

-- | A symbol in a @using (...)@ clause: report it if it does not occur
-- in the file body. We trust the source-level token check primarily;
-- the agda-deps usage index is consulted as a tie-breaker for the
-- (rarer) case where the symbol's short name is shared with other
-- identifiers in the file body. The token set is an over-approximation,
-- so a hit there suppresses the finding — false positives are worse
-- than a missed alert here.
checkUsing :: Context -> FilePath -> Text -> S.Set Text -> Int -> Text -> Text -> [Finding]
checkUsing ctx fp thisMod bodyToks lineNo modName sym
  -- 'mentionedInTokens', not membership: `using (_∷_)` is written whole in
  -- the clause but applied as `x ∷ xs`, so the whole name need not appear
  -- in the body at all. False positives are the failure mode here, so the
  -- wider test is the right one.
  | mentionedInTokens bodyToks sym = []
  | (modName, sym) `S.member` referenced = []
  | otherwise =
      [ Finding
          { fileFinding   = fp
          , lineFinding   = lineNo
          , kindFinding   = UnusedInUsing
          , moduleFinding = modName
          , symbolFinding = Just sym
          , noteFinding   = Nothing
          , confFinding   = High
          , argsFinding   = Nothing
          }
      ]
  where
    referenced = M.findWithDefault S.empty thisMod (ctxUsedQNames ctx)

-- | A blanket @open import M@ is flagged only if the graph says NO
-- qname from M is used by any definition in @thisMod@, AND M doesn't
-- publicly re-export any name @thisMod@ also references. The second
-- clause is the re-export widening: if M re-exports a name that
-- @thisMod@ actually uses (even if the underlying definition lives in
-- M's parent / source module and is external to the project graph),
-- the blanket open is the only thing in scope that makes that name
-- visible — so the import is real.
checkBlanket :: Context -> FilePath -> Text -> S.Set Text -> Int -> Text -> [Finding]
checkBlanket ctx _fp thisMod bodyToks lineNo modName =
  let usedQ       = M.findWithDefault S.empty thisMod (ctxUsedQNames ctx)
      directFromM = S.filter ((== modName) . fst) usedQ
      usedShorts  = S.map snd usedQ
      -- Names @modName@ surfaces via its own @open … public@ chain.
      -- Looked up by HOST (@modName@ is the module the file imports);
      -- the rows tell us what that module publishes in its public NS.
      reexShorts  = M.findWithDefault S.empty modName (ctxRxShortsByHost ctx)
      -- The file body may name something modName re-exports even when
      -- the underlying definition was dropped by '--no-externals' (so
      -- no edge survives in 'usedQ'). Falling back to source-side
      -- tokens is OK here because we're widening — false negatives,
      -- not false positives, are the failure mode for credits.
      --
      -- Matched through 'mentionedInTokens', not a set intersection: a
      -- re-exported name is very often line-tagged or mixfix (790 of 1549
      -- on the measured corpus), and neither spelling occurs verbatim in a
      -- body — so a plain intersection silently loses the credit and the
      -- blanket open is flagged although the file does use it.
      tokenShortsHit = any (mentionedInTokens bodyToks) (S.toAscList reexShorts)
      reexportedHit  = S.intersection usedShorts reexShorts
  in if S.null directFromM
       && not tokenShortsHit
       && S.null reexportedHit
        then [ Finding
                 { fileFinding   = _fp
                 , lineFinding   = lineNo
                 , kindFinding   = UnusedBlanketOpen
                 , moduleFinding = modName
                 , symbolFinding = Nothing
                 , noteFinding   = Just "no symbol from this module is referenced (best-effort)"
                 , confFinding   = High
                 , argsFinding   = Nothing
                 }
             ]
        else []

-- ** Bonus checks

-- | Defined in @thisMod@, never referenced from any other module in the
-- graph — and never re-exported through a chain into a module that has
-- a user. The check is short-name based (a defined symbol in
-- 'ctxDefShortByModule' is "used" if any other module's
-- 'ctxUsedQNames' contains @(thisMod, name)@, OR some host module
-- transitively re-exports it).
--
-- The closure is intentionally small: we accept a host as a user, then
-- iterate one more step in case a host is itself re-exported. In
-- practice the Agda elaborator collapses re-export chains to the
-- ultimate source module, so the iteration converges immediately for
-- almost every name.
definedButUnused :: Context -> FilePath -> Text -> S.Set Text -> [Finding]
definedButUnused ctx fp thisMod shorts =
  [ Finding
      { fileFinding   = fp
      , lineFinding   = M.findWithDefault 0 (thisMod, sh) (ctxDefLineByQ ctx)
      , kindFinding   = kind
      , moduleFinding = thisMod
      , symbolFinding = Just sh
      , noteFinding   = Just $
          -- A dead PROJECTION is a dead record field: the edit is one
          -- level up, in the record declaration. Said before the
          -- deletion-candidate wording so the user is never told to
          -- delete a generated projection function.
          if deadField
            then "remove the field from its record — a no-eta record \
                 \matched positionally uses fields without the projection"
          else if isCycle
            -- A mutual-recursion cycle no external entry reaches: the
            -- graph shows intra-module callers, but they are only each
            -- other, so the cycle is dead as a unit.
            then "deletion candidate (dead cycle with " <> peersText <> ")"
          else if S.null intra
            then if selfRec
                 -- The elaborator never inlines a recursive def, so the
                 -- Phase-A inlined-callee worry below doesn't apply here.
                 then "deletion candidate (recursive: its only callers are its own calls)"
                 else if trivial
                 -- PHASE A: a surviving dead finding whose body is
                 -- trivial is more likely an inlined callee than a
                 -- true orphan; say so and downgrade the confidence.
                        then "deletion candidate (trivial body, possibly inlined)"
                        -- The known edge gap, said on the finding rather
                        -- than left in the docs: the graph carries no edge
                        -- for a use in a `with` scrutinee, and the
                        -- source-text net only catches it when the name is
                        -- spelt the same way there.
                        else "deletion candidate (verify first: a use in a \
                             \`with` scrutinee leaves no edge)"
          else "intra-module callers only"
      , confFinding   = if deadField || (S.null intra && trivial && not selfRec)
                          then Low else High
      , argsFinding   = Nothing
      }
  | sh <- S.toAscList shorts
  , let isProj         = (thisMod, sh) `S.member` ctxProjections ctx
        trivial        = (thisMod, sh) `S.member` ctxTrivialBody ctx
        selfRec        = (thisMod, sh) `S.member` ctxSelfRecursive ctx
        deadCyclePeers = M.lookup (thisMod, sh) (ctxDeadCycles ctx)
        isCycle        = isJust deadCyclePeers
        peersText      = T.intercalate ", " (S.toAscList (fromMaybe S.empty deadCyclePeers))
  -- A projection needs the projection-only user view: its generic user set
  -- is never empty (own record + automatic re-export), so the plain test
  -- would filter every field out before it could be reported.
  , if isProj then (thisMod, sh) `S.notMember` ctxProjectionLive ctx
              else S.null (usersClosure ctx (thisMod, sh))
  , let intra = M.findWithDefault S.empty (thisMod, sh) (ctxIntraModUsedQ ctx)
  -- A def is reported 'DefinedDead' when it has NO intra-module caller
  -- OR it is a dead-cycle member (its only callers are the cycle's
  -- other members). 'internalOnly' is the complement: real intra-module
  -- users the deletion note must not claim away. 'dead' gates the
  -- source-text suppression below (both the plain-dead and cycle cases
  -- can be masked by a live inlined mention).
  , let dead         = S.null intra || isCycle
        internalOnly = not dead        -- the two are the halves of one partition
        -- A dead PROJECTION is a dead record field: it drives the kind,
        -- the note and the confidence below, so it is named once here.
        deadField    = dead && isProj
        kind | deadField = FieldNeverProjected
             | dead      = DefinedDead
             | otherwise = DefinedInternalOnly
  -- 'crossFile' (short name used in some OTHER file) and 'inFileUse'
  -- (occurs beyond the def's signature + LHS in THIS file) are the two
  -- halves of the elaborator-inlining suppression below. Bound once
  -- here so the two dead-branch guards share the single cross-file scan
  -- instead of each recomputing it. 'countsInFile' says whether the
  -- in-file count is meaningful: it is NOT for self-recursive or cycle
  -- members, whose own / mutual RHS calls inflate the count and are
  -- already explained by the graph's self / intra-cycle edges.
  , let crossFile    = mentionedCrossFile ctx fp sh
        -- Same normalisation as the cross-file half: the raw short name
        -- carries the producer's @\@line@ tag, and a mixfix name is
        -- normally written as its parts. Within one alternative every
        -- token must clear the signature+LHS allowance, since each of them
        -- appears in both.
        inFileUse     = anySpelling (\n -> countToken n body > 2) sh
        body          = M.findWithDefault T.empty fp (ctxSourceBodies ctx)
        countsInFile  = not selfRec && not isCycle
  -- PHASE B (the principled fix): a TRIVIAL-bodied def whose short
  -- name appears as a use in ANOTHER file is treated as having a
  -- synthetic external user — the elaborator inlined the callee and
  -- the dependency graph dropped the edge, but the source text still
  -- mentions it. Such a def is never dead. We gate this on
  -- trivial-bodied only (the inliner only inlines trivial RHSs) so we
  -- don't mask a genuinely-dead non-trivial def whose short name
  -- collides with an unrelated live identifier elsewhere. (The wider
  -- cross-file-or-in-file check still applies to all dead defs below.)
  , dead `implies` not (trivial && crossFile)
  -- Suppress dead false positives caused by Agda's elaborator
  -- inlining the callee: when the def reads as dead (no intra caller,
  -- or a dead cycle), double-check the source text. If the short name
  -- appears as a use in another file (or more than twice in this
  -- file's body, beyond the def's signature + LHS), it's a live
  -- reference the dep graph just lost. We only apply this to the
  -- DEAD branch; a genuine internal-only def already has graph evidence
  -- of intra-module use and doesn't need a source-text fallback.
  -- The in-file half is skipped for self-recursive and cycle members
  -- ('countsInFile'): their own / mutual RHS calls push the count past
  -- the sig+LHS allowance, and the graph edges already explain those
  -- mentions precisely. The cross-file half still applies.
  , dead `implies` not (crossFile || (countsInFile && inFileUse))
  -- Skip the @internal-only@ "wrap in @private@" suggestion for
  -- names the producer already reports as 'Private'. They're
  -- already wrapped; re-flagging them is noise. The 'DefinedDead'
  -- branch still fires for private names — a private with NO callers
  -- anywhere (or a private dead cycle) remains a deletion candidate,
  -- so this gate is on 'internalOnly', not merely on having a caller.
  , internalOnly `implies`
      (M.findWithDefault Public (thisMod, sh) (ctxDefAccessByQ ctx) /= Private)
  ]
  where
    implies True  x = x
    implies False _ = True

-- | Definitions carrying arguments Agda proved they never use.
--
-- One finding per definition per verdict, never one per position: the
-- unit of action is "refactor this definition", and a def with three
-- removable positions is one refactor, not three findings. Positions that
-- cannot be deleted on their own are named inline, so the report never
-- suggests a partial removal that would strand a later binder.
--
-- Silent on a graph whose producer predates @argUsage@ ('ctxArgUsage' is
-- then empty), and — because the producer filters both — never sees a
-- @with@-generated or pattern-lambda definition.
--
-- Four producer signals qualify the verdict rather than the report
-- re-deriving them (each is an /actionability/ fact Agda knows and we
-- cannot):
--
--   * 'auPartiallyApplied' — the definition is referenced unsaturated, so
--     its arity is part of its interface and no binder can go however dead
--     it is. Kept as a finding (the dead argument is real) but graded
--     'Low', because the @removable@ headline does not hold for it.
--   * 'argOnSignatureLine' — a position past the signature line is a
--     binder nobody wrote; the verdict is true and often interesting (\"the
--     proof never inspects this hypothesis\") but the edit target is the
--     unfolded definition.
--   * 'argLocalEdit' — a position the elaborated body still threads into a
--     callee is a multi-definition edit. A /cost/, not a doubt, so it lands
--     in the note and not in the confidence.
--   * 'egErasureFor' — without @--erasure@ the @\@0@ this kind suggests is
--     a syntax error (@[AttributeKindNotEnabled]@), so say so on the
--     finding. Not suppressed: the caller asked for this kind by name
--     (@all@ does not include it), and 'Low' + @--min-confidence=high@
--     is the volume lever.
unusedArguments :: Context -> FilePath -> Text -> S.Set Text -> [Finding]
unusedArguments ctx fp thisMod shorts = concat
  [ [ mk ArgRemovable $
        positions au (map (showRemovable au) removable)
        <> insertedNote au removable
        <> unwrittenNote written removable
        <> positionNote "passed on to a callee that discards it, so removing \
                        \it means editing that callee too"
                        (filter (not . argLocalEdit au) removable)
        <> partialNote (argRemovalBlocked au removable) au
        <> "; " <> radius
    | not (null removable) ]
    ++
    [ mk ArgErasable $
        positions au (map (showPosition au) erasable)
        <> insertedNote au erasable
        <> unwrittenNote written erasable
        <> erasureNote
        <> "; " <> radius
    | not (null erasable) ]
  | sh <- S.toAscList shorts
  , Just au <- [M.lookup (thisMod, sh) (ctxArgUsage ctx)]
  , let removable = flaggedPositions ArgRemovable au
        erasable  = flaggedPositions ArgErasable  au
        intra    = M.findWithDefault S.empty (thisMod, sh) (ctxIntraModUsedQ ctx)
        -- The module's one "who uses this qname" accessor, so the blast
        -- radius and the confidence gate agree with `defined-dead` and
        -- `public-no-downstream` on the same graph. Reading
        -- 'ctxUsersOfQName' directly would drop the re-export widening
        -- and call a def reached only through an `open … public` host
        -- uncalled here while the other checks call it used.
        outside  = usersClosure ctx (thisMod, sh)
        -- The cost of the edit: every caller's argument list changes too.
        -- Counted in definitions here and in MODULES elsewhere, because
        -- that is what the graph actually knows — edges are def-to-def, so
        -- there is no call-site count to report and we do not invent one.
        radius
          | S.null intra && S.null outside = "no callers"
          | otherwise = tshow (S.size intra) <> " caller(s) here, "
                          <> tshow (S.size outside) <> " other module(s)"
        -- Agda's verdict ("the body does not depend on this argument") is
        -- certain and is NOT what the confidence grades. What it grades is
        -- whether the edit the finding names is one a reader can actually
        -- make: an API break we cannot scope, a binder that is not on the
        -- line, an arity that is part of an interface, or advice that is a
        -- syntax error in this module all mean "verify before acting".
        contained = M.findWithDefault Public (thisMod, sh) (ctxDefAccessByQ ctx)
                      == Private
                    || S.null outside
        -- The module's `--erasure` answer, from the producer's effective
        -- options (not a pragma scan — the flag normally lives in the
        -- .agda-lib). An older graph carries no map, which reads as "off".
        erasureOn = erasureEnabledFor (ctxEffectiveOptions ctx) thisMod
        -- "The reader can find this binder on the signature line." On a
        -- graph whose producer describes no binders at all we do not
        -- claim either way: no label, no confidence penalty.
        written = argWritten (ctxArgBindersKnown ctx) au
        erasureNote
          | erasureOn = ""
          | otherwise = " — but `--erasure` is not enabled for this module, \
                        \so `@0` here is a syntax error"
        mk k note = Finding
          { fileFinding   = fp
          , lineFinding   = M.findWithDefault 0 (thisMod, sh) (ctxDefLineByQ ctx)
          , kindFinding   = k
          , moduleFinding = thisMod
          , symbolFinding = Just sh
          , noteFinding   = Just note
          , confFinding   =
              let reported = flaggedPositions k au
              in if contained
                    && all written reported
                    -- An unsaturated reference blocks a REMOVAL (the arity
                    -- is the interface); it says nothing about whether a
                    -- position can be marked `@0`, so it does not grade
                    -- erasable down.
                    && (k /= ArgRemovable || not (argRemovalBlocked au reported))
                    && (k /= ArgErasable  || erasureOn)
                   then High else Low
          , argsFinding   = Just au
          }
  ]
  where
    commaSep = T.intercalate ", "
    tshow :: Show a => a -> Text
    tshow = T.pack . show
    -- "argument 0 of 2" / "arguments 0 (with 1, 3), 1, 3 of 4". Positions
    -- are 0-based telescope indices with implicits counted, over the
    -- definition's own REDUCED telescope — never read off 'defSig', which
    -- disagrees in both directions (it carries the binders a section
    -- lifted in, and stops short of the ones an unfolding introduces).
    positions au rendered =
      (if length rendered == 1 then "argument " else "arguments ")
        <> commaSep rendered <> " of " <> tshow (auArity au)
    -- A position that cannot go alone drags its forward closure with it;
    -- offering the partial removal would strand a later binder.
    showRemovable au i = case M.findWithDefault [] i (auRemovableRequires au) of
      [] -> showPosition au i
      js -> showPosition au i <> " (with " <> commaSep (map tshow js) <> ")"

    -- The index plus the binder, spelled with Agda's own brackets so the
    -- line reads like the signature: @0 {a}@, @3 ⦃d⦄@, @0 m@. An
    -- implicit rendered as a bare index is the misread this exists to
    -- prevent — "argument 0" of @{a : Set} → List a → …@ is the @{a}@,
    -- not the first list. A position the producer had no binder for
    -- stays a bare index rather than getting a guess.
    showPosition au i = case M.lookup i (auBinders au) >>= bracket of
      Nothing -> tshow i
      Just b  -> tshow i <> " " <> b

    -- An unnamed binder falls back to its TYPE, which is the only name it
    -- has: this project style writes premises unnamed
    -- (@∙ premise₁ ∙ premise₂ ─── conclusion@), and two thirds of the
    -- actionable removable positions on the measured corpus are unnamed
    -- explicit binders. "argument 5 of 11" is the hardest possible thing
    -- to act on in an eleven-premise signature; "argument 5 (GST ≤ s)" is
    -- not. Needs a producer run with @--with-signatures@ ('abType');
    -- without it an unnamed explicit binder still renders as the bare
    -- index, since "0 _" tells a reader nothing.
    bracket b = case abHiding b of
      BHExplicit -> abName b <|> fmap paren (abType b)
      BHImplicit -> Just ("{" <> nm <> "}")
      BHInstance -> Just ("⦃" <> nm <> "⦄")
      where
        nm = fromMaybe "_" (abName b <|> abType b)
    -- Only a rendered TYPE needs the brackets, to keep a multi-token type
    -- from reading as several arguments.
    paren t = "(" <> t <> ")"

    -- Generalisation-inserted binders have no signature line to edit.
    -- Said once per finding rather than per position: the deletion is
    -- still well defined, because an inserted binder can only be
    -- removable when the written argument that mentions it is removable
    -- too and sits in its closure — so the set always contains something
    -- the user can actually delete. This just stops them hunting for a
    -- binder that was never written.
    insertedNote au ixs =
      positionNote "inserted by a `variable`, not on the signature line"
        [ i | i <- ixs, Just b <- [M.lookup i (auBinders au)], abInserted b ]

    -- "(0, 3 <what is true of them>)", or nothing at all for an empty set.
    -- The one parenthesised-positions renderer: every qualifier the report
    -- appends has this shape, and three copies of it drifted apart on
    -- whether they took their positions as an argument.
    positionNote what ixs
      | null ixs  = ""
      | otherwise = " (" <> commaSep (map tshow ixs) <> " " <> what <> ")"

    -- A position past the signature line has no binder to strike out: it
    -- exists because a type in the signature UNFOLDS into more binders
    -- (`f : (xs : List A) → xs ⊆ ys` unfolds to `{x} → x ∈ xs → x ∈ ys`).
    -- The verdict is still true and worth reading — a premise the proof
    -- never inspects means the statement could be strengthened — so it is
    -- labelled, never dropped. Both renderings of a bare index would
    -- otherwise be indistinguishable from an unnamed written binder.
    unwrittenNote written ixs =
      positionNote "not on the signature line — introduced by unfolding a \
                   \type in it, so the edit target is that definition"
                   (filter (not . written) ixs)

    -- Referenced unsaturated somewhere in the graph, so the arity is part
    -- of the interface (`Eager ∩¹ AfterT t` needs `AfterT t` to stay
    -- unary) and the "the binder can go" headline does not hold.
    partialNote blocks au
      | not (auPartiallyApplied au) = ""
      | blocks =
          " — but this definition is used unsaturated, so its arity is part \
          \of its interface and no binder can go"
      | otherwise =
          " (this definition is used unsaturated, but every flagged position \
          \is hidden, so no call site's argument list shifts)"

-- | Which telescope positions a given argument-finding kind flags.
--
-- The one owner of that mapping: the report line, the confidence rule, the
-- @--format=json@ payload and @--group-by=premise@ all ask it, and three
-- hand-written copies had already drifted (one answered with the erasable
-- positions for a non-argument kind). A kind that flags nothing yields
-- @[]@, so a new kind cannot silently inherit another's positions.
flaggedPositions :: FindingKind -> ArgUsage -> [Int]
flaggedPositions ArgRemovable = auRemovable
flaggedPositions ArgErasable  = auErasable
flaggedPositions _            = const []

-- | The __premise families__ an argument finding belongs to: the head
-- symbol of each flagged position's type, base name only.
--
-- This is the report-shape half of "which hypotheses has this development
-- stopped using". A dead `Reachable s` premise appearing on six lemmas is
-- one review item, not six lines, and the family is what names it. The key
-- is 'AgdaGraph.GoalCanon.headSymbol' — the same "top-level relation or
-- type constructor" the lemma ranker keys conclusions on, since a premise
-- IS a proposition — so a relational premise groups under its relation
-- (@≥@) and a predicate under its constructor (@Reachable@).
--
-- Deliberately NOT a name heuristic. Keying on binder names like @Rs@ or
-- @GST≤@ would be one project's convention dressed up as an analysis; the
-- type is the fact.
--
-- One entry per distinct family, so a definition dropping two premises of
-- the same family counts once and one dropping two different families
-- appears under both — rows can therefore sum above the finding total.
-- Positions whose binder the producer did not describe (no entry, or no
-- @type@ because the graph was built without @--with-signatures@) land in
-- one honest bucket rather than being guessed at.
premiseFamilies :: Finding -> [Text]
premiseFamilies f = case argsFinding f of
  Nothing -> ["(not an argument finding)"]
  Just au -> case flaggedPositions (kindFinding f) au of
    [] -> ["(no flagged position)"]
    ps -> S.toAscList (S.fromList (map (familyAt au) ps))
  where
    familyAt au i = case M.lookup i (auBinders au) >>= abType of
      Nothing -> "(no binder type)"
      Just t  -> maybe "(no head symbol)" baseComponent
                       (headSymbol (dropSectionPlaceholder t))
    -- The producer prints an anonymous enclosing-section parameter as a
    -- lone U+22EF, and 'headSymbol' prefers a top-level OPERATOR over an
    -- identifier — so `AwaitingGS \8943 s` came back headed by the
    -- placeholder rather than by the predicate. It is an artefact of
    -- signature rendering, not a token of the type, so it is dropped here
    -- rather than in the shared canonicaliser (which also serves
    -- interaction goal types, where it never appears).
    dropSectionPlaceholder = T.replace "\8943" " "

-- | The __source spellings__ of a producer short name: every token a
-- reader would actually see in a body that uses it.
--
-- Two normalisations, and both are load-bearing — the source-text
-- suppression below is a no-op without them:
--
--   * The @\@\<line\>@ disambiguator the producer appends to
--     @where@-\/anonymous-module helpers is not source text.
--     @PreEnoughV?\@240@ appears in no file, so every lookup keyed on the
--     raw short name answered \"never mentioned\" for /every/ module-local
--     definition — 87 of 157 @dead@ findings on the measured corpus.
--   * A __mixfix__ name is applied as its parts: @_:InitTC?@ is written
--     @𝔹 :InitTC?@, so the whole name never occurs either. 'bodyTokens'
--     splits on the same boundaries, so the parts are exactly what it
--     holds.
--
-- Underscores mark the holes, so splitting on them yields the name parts.
-- The result is a list of __alternatives__, each a list of tokens that must
-- all occur together: matching any one alternative is a mention. The
-- whole-name alternative comes first and is not optional — @_@ and the
-- bracket runes are 'bodyTokens' identifier characters, so a mixfix name
-- /does/ appear verbatim in a @using (…)@ list or a fixity declaration, and
-- dropping that spelling turned two suppressed findings back on.
sourceSpellings :: Text -> [[Text]]
sourceSpellings sh = [base] : [ parts | not (null parts), parts /= [base] ]
  where
    base  = stripLineTag sh
    parts = filter (not . T.null) (T.splitOn "_" base)

-- | True if @sh@ is mentioned in the body tokens of some file OTHER than
-- @fp@. 'definedButUnused' combines this (the cross-file half of the
-- elaborator-inlining dead-FP suppression) with an in-file
-- occurrence-count check.
--
-- A mixfix name must have __all__ of its parts in the /same/ other file,
-- which is how an application of it reads (@𝔹 :InitTC?@). Requiring one
-- file to carry the whole spelling is what keeps a one-part operator like
-- @_+_@ from being suppressed by the @+@ that appears everywhere.
--
-- The first part still goes through the inverted 'ctxTokenToFiles' index,
-- so the common single-spelling case costs exactly what it did before;
-- the remaining parts are checked against that candidate's own token set.
-- Iterates key-ordered sets so it stays determinism-safe.
-- | Is @sh@ mentioned in this token set, under any of its source
-- spellings? The single-file analogue of 'mentionedCrossFile': one
-- alternative must be present in full ('sourceSpellings' — whole name, or
-- every mixfix part).
--
-- Used wherever a __graph-side__ name is checked against __source__ tokens.
-- Half the names in a real graph cannot be found any other way: on the
-- measured corpus 790 of 1549 distinct re-export shorts and 2153 of 5301
-- used shorts are line-tagged or mixfix, and neither spelling ever appears
-- verbatim in a body.
mentionedInTokens :: S.Set Text -> Text -> Bool
mentionedInTokens toks = anySpelling (`S.member` toks)

-- | Does some spelling of @sh@ match @p@ __in full__? The one encoding of
-- the alternatives rule ('sourceSpellings'), so a caller cannot
-- accidentally require only part of a mixfix name.
anySpelling :: (Text -> Bool) -> Text -> Bool
anySpelling p = any (all p) . sourceSpellings

mentionedCrossFile :: Context -> FilePath -> Text -> Bool
mentionedCrossFile ctx fp sh = any spelt (sourceSpellings sh)
  where
    spelt []       = False
    spelt (n : ns) =
      let others = S.delete fp (M.findWithDefault S.empty n (ctxTokenToFiles ctx))
          hasAll f = case M.lookup f (ctxSourceTokens ctx) of
            Nothing -> False
            Just ts -> all (`S.member` ts) ns
      in any hasAll (S.toAscList others)

-- | Count whole-token occurrences of @needle@ in @haystack@. A
-- "whole token" occurrence requires that the character before the
-- match (if any) is not an Agda identifier character, and same for
-- the character after. Cheaper than re-tokenising per candidate.
countToken :: Text -> Text -> Int
countToken needle haystack
  | T.null needle = 0
  | otherwise     = go (T.splitOn needle haystack)
  where
    -- For N parts the needle appears N-1 times. Each occurrence is
    -- between parts[i] and parts[i+1]: keep it iff parts[i]'s last
    -- char and parts[i+1]'s first char are token-boundary chars.
    go []           = 0
    go [_]          = 0
    go (a : rest@(b : _)) =
      (if endsBoundary a && startsBoundary b then 1 else 0) + go rest

    endsBoundary t   = T.null t || not (isIdChar (T.last t))
    startsBoundary t = T.null t || not (isIdChar (T.head t))

    isIdChar c = c == '_' || c == '\'' || c > '~'
              || (c >= 'A' && c <= 'Z')
              || (c >= 'a' && c <= 'z')
              || (c >= '0' && c <= '9')
              || c `elem` ("<>=+*/!?#$%&^~|:.-" :: String)

-- | Closure of the user set for @(M, sh)@. Direct users come from
-- 'ctxUsersOfQName'. Re-export widening: every host module that
-- publicly re-exports @(M, sh)@ is itself a user (it's surfacing the
-- symbol in its public namespace), and any module using @(host, sh)@
-- joins via the direct-user path. Iteration is cycle-protected by a
-- 'Set' visit log.
usersClosure :: Context -> (Text, Text) -> S.Set Text
usersClosure ctx = usersClosureCore (ctxUsersOfQName ctx) (ctxRxBySourceQ ctx)

-- | The pure map-driven core of 'usersClosure', taking the two indices
-- it reads directly instead of a whole 'Context'. Shared with the
-- dead-cycle pass ('computeDeadCycles'), which runs during context
-- construction (before a 'Context' exists to hand around).
usersClosureCore
  :: M.Map (Text, Text) (S.Set Text)   -- ^ 'ctxUsersOfQName'
  -> M.Map (Text, Text) (S.Set Text)   -- ^ 'ctxRxBySourceQ'
  -> (Text, Text) -> S.Set Text
usersClosureCore usersQ rxBySrcQ start = go S.empty S.empty [start]
  where
    go _visited !users [] = users
    go !visited !users (k@(_m, sh) : rest)
      | S.member k visited = go visited users rest
      | otherwise =
          let !visited' = S.insert k visited
              !direct   = M.findWithDefault S.empty k usersQ
              !hosts    = M.findWithDefault S.empty k rxBySrcQ
              !users'   = S.union users (S.union direct hosts)
              -- Walk one level into the re-export DAG: every host might
              -- itself be a re-export site for the same short name. The
              -- producer collapses chains, so this rarely matters; the
              -- guard keeps us correct on any future grammar surprises.
              !next     = [ (h, sh) | h <- S.toList hosts ]
          in go visited' users' (next ++ rest)

-- | Dead mutual-recursion cycles, one level up from 'ctxSelfRecursive'.
-- Per module, run 'stronglyConnComp' over the intra-module call graph. The
-- graph is read straight off 'ctxIntraModUsedQ' (@(mod,callee) -> caller
-- shorts@, self-edges already excluded): its edges are @callee -> callers@,
-- the transpose of the call graph — and SCCs are invariant under transpose,
-- so the components are identical. A 'CyclicSCC' of size >= 2 is dead as a
-- unit iff NO member is reachable from outside the cycle — no member has a
-- cross-module / re-export user ('usersClosureCore' empty) and none has an
-- intra-module caller from OUTSIDE the SCC. Each member of a dead cycle maps
-- to its OTHER members' short names (for the finding note). Deterministic:
-- modules iterated in key order, SCC input built from sorted node lists.
computeDeadCycles
  :: M.Map (Text, Text) (S.Set Text)   -- ^ intra-module callers ('ctxIntraModUsedQ')
  -> M.Map (Text, Text) (S.Set Text)   -- ^ cross-module users ('ctxUsersOfQName')
  -> M.Map (Text, Text) (S.Set Text)   -- ^ re-export hosts ('ctxRxBySourceQ')
  -> M.Map (Text, Text) (S.Set Text)
computeDeadCycles intraCallers usersQ rxBySrcQ =
  M.fromList
    [ ((m, sh), S.delete sh members)
    | (m, calleeCallers) <- M.toList byModule
    , CyclicSCC vs <- stronglyConnComp (sccInput calleeCallers)
    , length vs >= 2
    , let members = S.fromList vs
    , cycleIsDead m members
    , sh <- S.toAscList members
    ]
  where
    -- Regroup 'intraCallers' (keyed by (module, callee)) by module.
    byModule :: M.Map Text (M.Map Text (S.Set Text))
    byModule = M.fromListWith M.union
      [ (m, M.singleton callee callers)
      | ((m, callee), callers) <- M.toList intraCallers ]

    -- Adjacency (callee -> its callers, the transpose) for one module, with
    -- every node (callee key OR caller value) emitted in sorted order.
    sccInput cc =
      let nodes = S.fromList (M.keys cc ++ concatMap S.toList (M.elems cc))
      in [ (n, n, S.toAscList (M.findWithDefault S.empty n cc))
         | n <- S.toAscList nodes ]

    cycleIsDead m members = all memberDead (S.toAscList members)
      where
        memberDead sh =
             S.null (usersClosureCore usersQ rxBySrcQ (m, sh))
          && S.null (M.findWithDefault S.empty (m, sh) intraCallers
                       `S.difference` members)

-- | An @open import M … public@ where the re-export looks dead.
--
-- For @open import M using (n) public@ we check that @n@ has *some*
-- downstream consumer reachable through the re-export chain rooted at
-- @(thisMod, n)@. Otherwise we report the symbol.
--
-- For @open import M public@ (no @using@), we report the whole import
-- when no name @M@ surfaces in @thisMod@'s public namespace has any
-- downstream user — i.e. nothing the project actually consumes flows
-- through the re-export. The producer's @reexports@ rows tell us which
-- @(thisMod, M, names)@ pairs Agda recorded; if none of those names
-- has a user, the @public@ keyword is dead weight.
publicReexportFindings :: Context -> FilePath -> Text -> [ImportLine] -> [Finding]
publicReexportFindings ctx fp thisMod imports =
  let usingFindings =
        [ Finding
            { fileFinding   = fp
            , lineFinding   = ilLine il
            , kindFinding   = PublicWithoutDownstream
            , moduleFinding = ilModule il
            , symbolFinding = Just sym
            , noteFinding   = Just "no other module references this re-export"
            , confFinding   = High
            , argsFinding   = Nothing
            }
        | il <- imports
        , ilPublic il
        , Just syms <- [ilUsing il]
        , not (null syms)
        , sym <- syms
        , let downstream =
                S.delete thisMod $
                  S.union
                    (M.findWithDefault S.empty (ilModule il, sym) (ctxUsersOfQName ctx))
                    (usersClosure ctx (thisMod, sym))
        , S.null downstream
        ]

      -- For blanket @open import M public@ (or elided-using-clause
      -- '⋯', which we normalise to @Just []@), report the import as
      -- a whole when nothing M re-exports through thisMod has a
      -- downstream user. We look up the (thisMod, M)-rooted shorts in
      -- 'ctxRxByHost' / 'ctxRxShortsByHost' and ask each user-of-q
      -- closure for any non-thisMod consumer.
      blanketRows = case M.lookup thisMod (ctxRxShortsByHost ctx) of
        Nothing      -> []
        Just _shorts -> [ Finding
                            { fileFinding   = fp
                            , lineFinding   = ilLine il
                            , kindFinding   = PublicWithoutDownstream
                            , moduleFinding = ilModule il
                            , symbolFinding = Nothing
                            , noteFinding   =
                                Just "blanket re-export with no downstream user"
                            , confFinding   = High
                            , argsFinding   = Nothing
                            }
                        | il <- imports
                        , ilPublic il
                        , maybe True null (ilUsing il)
                        , let mShorts =
                                shortsThisModSurfacesFrom ctx thisMod (ilModule il)
                        , not (S.null mShorts)
                        , let usersOfAny =
                                S.delete thisMod $ S.unions
                                  [ usersClosure ctx (ilModule il, sh)
                                  | sh <- S.toList mShorts
                                  ]
                        , S.null usersOfAny
                        ]
  in usingFindings ++ blanketRows

-- | Set of short names @host@ re-exports that originated in @src@.
-- O(log n) lookup into the pre-built 'ctxRxShortsByPair'.
shortsThisModSurfacesFrom :: Context -> Text -> Text -> S.Set Text
shortsThisModSurfacesFrom ctx host src =
  M.findWithDefault S.empty (host, src) (ctxRxShortsByPair ctx)

-- | Two or more separate @open import M …@ lines targeting the SAME
-- module @M@ /within the same lexical scope/ in the same file. Almost
-- always a consolidation candidate: the project convention is one
-- import line per module. Reports the second-and-subsequent line(s);
-- the first is the canonical site to merge into.
--
-- Scope is approximated by the enclosing @module … where@ block's
-- indent column (see 'AgdaUnused.Source.scanImports'). Two opens with
-- the same @ilModule@ but different @ilScope@ values live in different
-- @module … where@ blocks and are NOT duplicates of each other.
duplicateUsingFindings :: FilePath -> [ImportLine] -> [Finding]
duplicateUsingFindings fp imports =
  let -- Bucket by (module name, scope tag); later occurrences are
      -- flagged.
      -- 'ilPublic' is part of the key, not a detail: two opens of the same
      -- module that differ in `public`-ness are not consolidation
      -- candidates, because merging them would change the file's
      -- re-export surface. (Observed: one `using (a; b)` beside one
      -- `using (c) public`.)
      byMod = foldr bucket M.empty imports
      bucket il acc =
        M.insertWith (++) (ilModule il, ilScope il, ilPublic il) [il] acc
  in [ Finding
         { fileFinding   = fp
         , lineFinding   = ilLine il
         , kindFinding   = DuplicateUsingForModule
         , moduleFinding = m
         , symbolFinding = Nothing
         , noteFinding   = Just $ "another `open import` of this module already exists in the file"
         , confFinding   = High
         , argsFinding   = Nothing
         }
     | ((m, _scope, _public), ils) <- M.toList byMod
     , length ils > 1
     , il <- drop 1 (reverse ils)  -- 'reverse' restores source order; skip first
     ]

-- ** Render

renderFindingLine :: Finding -> String
renderFindingLine f =
  let lineCol  = fileFinding f ++ ":" ++ show (lineFinding f) ++ ":"
      sym      = case symbolFinding f of
                   Just s  -> T.unpack (moduleFinding f) ++ "." ++ T.unpack s
                   Nothing -> T.unpack (moduleFinding f)
      tag      = case kindFinding f of
                   UnusedInUsing           -> "unused in file"
                   UnusedBlanketOpen       -> "blanket open with no observed use"
                   DefinedDead             -> "defined here, no callers anywhere"
                   DefinedInternalOnly     -> "defined here, intra-module callers only"
                   FieldNeverProjected     -> "record field never projected"
                   ArgRemovable            -> "unused argument(s), removable"
                   ArgErasable             -> "unused argument(s), erasable (mark @0)"
                   DuplicateUsingForModule -> "duplicate `using` clause for module"
                   PublicWithoutDownstream -> "re-export with no downstream user"
      note     = case noteFinding f of
                   Just n  -> " (" ++ T.unpack n ++ ")"
                   Nothing -> ""
      -- Confidence has ONE spelling in the human report, and this is it —
      -- no note may say "low confidence:" in prose, or a plain-text reader
      -- gets two spellings that can disagree. Only 'Low' is marked:
      -- 'High' is the default and needs no ink.
      conf     = case confFinding f of
                   Low  -> "  [low confidence]"
                   High -> ""
  in lineCol ++ " " ++ sym ++ "   -- " ++ tag ++ note ++ conf

-- | The actionable payload of an argument finding, emitted under
-- @"arguments"@ by @--format=json@: the flagged positions, the binder at
-- each (so a consumer need not re-read the graph to render or locate one),
-- the arity, and — for 'ArgRemovable' — @delete@, mapping each position to
-- the full set that must go with it ('argRemovableAlone', itself
-- included).
--
-- __Acting on @delete[i]@ rather than on @i@ is the difference between a
-- valid edit and a stranded binder__, which is the whole reason this is on
-- the wire rather than left to prose. A public contract: the offline
-- delete-and-retypecheck check and any cascade loop read it.
argumentsJson :: Bool -> FindingKind -> ArgUsage -> A.Value
argumentsJson bindersKnown k au = A.object $
  [ "positions" A..= ps
  , "arity"     A..= auArity au
    -- Encoded through aeson's 'ToJSONKey' for 'Int', the same instance
    -- 'Schema.auBinders' / 'auRemovableRequires' already round-trip on,
    -- so the decimal-string key convention has one spelling rather than
    -- a hand-rolled second one here.
  , "binders"   A..= M.restrictKeys (auBinders au) (S.fromList ps)
  ]
  ++ [ "delete" A..= M.fromList [ (i, argRemovableAlone au i) | i <- ps ]
     | k == ArgRemovable ]
  -- The actionability qualifiers, so a machine consumer reaches the same
  -- verdict the human line states instead of re-deriving it from the
  -- absence of a `binders` key (which it cannot do for `arity`-equal
  -- graphs) or missing it entirely.
  --
  -- `unwritten` are positions with no binder on the signature line;
  -- `nonLocal` are removable positions the elaborated body threads into a
  -- callee, so the edit is multi-definition; `partiallyApplied` says the
  -- arity is part of the interface and NO position is removable. Each is
  -- omitted when it has nothing to say, so a clean finding's payload is
  -- unchanged.
  ++ [ "unwritten" A..= unwritten | not (null unwritten) ]
  ++ [ "nonLocal"  A..= nonLocal
     | k == ArgRemovable, not (null nonLocal) ]
  ++ [ "partiallyApplied" A..= True | auPartiallyApplied au ]
  -- The raw flag above is the producer's fact; this is the verdict the
  -- human line states. They differ: an unsaturated reference blocks a
  -- removal only for an EXPLICIT position, so a hidden one stays
  -- actionable. Emitting only the fact left a machine consumer burying
  -- findings the report calls High.
  ++ [ "removalBlocked" A..= True
     | k == ArgRemovable, argRemovalBlocked au ps ]
  where
    ps = flaggedPositions k au
    -- Same gate as the human line ('ctxArgBindersKnown'): on a graph whose
    -- producer describes no binders, an absent entry is not evidence, so
    -- claim nothing rather than calling every position unwritten.
    unwritten
      | bindersKnown = filter (not . argOnSignatureLine au) ps
      | otherwise    = []
    nonLocal  = filter (not . argLocalEdit au) ps

-- ** Qname helpers

moduleOfQName :: Text -> Text
moduleOfQName qn =
  case T.breakOnEnd "." qn of
    (pre, _) | not (T.null pre) -> T.dropEnd 1 pre  -- drop trailing '.'
    _                           -> T.empty

shortNameOf :: Text -> Text -> Text
shortNameOf qn modName
  | T.null modName              = qn
  | modName `T.isPrefixOf` qn
  , T.length qn > T.length modName
  , T.index qn (T.length modName) == '.'
                                = T.drop (T.length modName + 1) qn
  | otherwise                   =
      -- Fall back to the last dot component if the agda-deps module
      -- label disagrees with the qname's prefix (can happen for record
      -- field projections that live in submodules).
      let rev = T.reverse qn
          idx = T.findIndex (== '.') rev
      in case idx of
           Just i  -> T.reverse (T.take i rev)
           Nothing -> qn
