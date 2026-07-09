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
  , kindTag
  , analyse
  , renderFindingLine
  ) where

import           Control.DeepSeq            ( NFData(..), rnf )
import           Control.Parallel.Strategies ( parBuffer, rdeepseq, using )
import           Data.Graph      ( SCC(..), stronglyConnComp )
import           Data.List       ( foldl' )
import qualified Data.Map.Strict as M
import           Data.Maybe      ( fromMaybe, isJust )
import qualified Data.Set        as S
import           Data.Text       ( Text )
import qualified Data.Text       as T

import           AgdaUnused.Json   ( ExpandedGraph(..), Definition(..), Kind(..), Access(..), ReExport(..) )
import           AgdaUnused.Source ( ImportLine(..), scanImports, bodyTokens )

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
kindTag DuplicateUsingForModule = "duplicate-using"
kindTag PublicWithoutDownstream = "public-no-downstream"

-- | How to aggregate the flat finding list for @--group-by@. @GByDir@
-- buckets by the directory of each finding's (relativised) file path,
-- @GByFile@ by the whole file path, @GByKind@ by 'kindTag'.
data GroupBy = GByDir | GByFile | GByKind
  deriving (Show, Eq)

instance NFData GroupBy where
  rnf g = g `seq` ()

-- | Parse a @--group-by@ / @group-by:@ token. Mirrors 'parseKinds'
-- error style ("unknown …: <token>") so the CLI and YAML report the
-- same message on a bad value.
parseGroupBy :: String -> Either String GroupBy
parseGroupBy "dir"  = Right GByDir
parseGroupBy "file" = Right GByFile
parseGroupBy "kind" = Right GByKind
parseGroupBy s      = Left $ "unknown group-by: " ++ s

instance NFData Finding where
  rnf (Finding a b c d e f g) =
    rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e `seq` rnf f
      `seq` rnf g

-- ** Top-level driver

analyse :: ExpandedGraph -> [(FilePath, Text)] -> [Finding]
-- ^ @analyse graph fileBodies@ — @fileBodies@ is the list of
-- @(absolute-path, raw-file-contents)@ pairs to inspect. The graph
-- carries the agda-deps definition/edge data the analyser needs.
analyse graph fileBodies =
  let ctx       = buildContext graph fileBodies
      perFile   = [ findingsForFile ctx fp body | (fp, body) <- fileBodies ]
      sparked   = perFile `using` parBuffer 32 rdeepseq
  in concat sparked ++ duplicateUsingsAcrossFiles ctx

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
  , ctxUsedNamesInMod   :: !(M.Map Text (S.Set Text))
    -- ^ For each module M (the user-side), the set of short names of
    -- qnames it pulls in from *any* other module (i.e. the right-hand
    -- side of every definitionEdge whose lhs lives in M, projected to
    -- (referenced-module, short-name)). Currently aggregated as a
    -- flat set of short names. The unused-using check uses this plus
    -- a per-import-module restriction.
  , ctxUsedQNames       :: !(M.Map Text (S.Set (Text, Text)))
    -- ^ For each user-module M, the set of (target-module, short-name)
    -- pairs M references. This is the precise version of
    -- 'ctxUsedNamesInMod'; the analyser uses it where short-name
    -- ambiguity (same symbol exported by multiple modules) matters.
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
  , ctxAllModules       :: !(S.Set Text)
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
  }

buildContext :: ExpandedGraph -> [(FilePath, Text)] -> Context
buildContext ExpandedGraph{..} bodies =
  let moduleByFile = M.fromListWith S.union
        [ (p, S.singleton m) | (m, p) <- M.toList egModuleFiles ]

      sourceTokens = M.fromList [ (p, bodyTokens b) | (p, b) <- bodies ]
      sourceBodies = M.fromList bodies

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

      -- Per-edge ingest, building the usage indices in one pass.
      -- Intra-module edges still populate 'intraModUsedQ' (used by the
      -- @defined@ check to distinguish dead vs internal-only) — except
      -- self-edges: a recursive call is not a caller, so counting it
      -- would shield a dead recursive def from the @dead@ check. Those
      -- are remembered in 'selfRec0' instead ('ctxSelfRecursive').
      -- Non-self intra edges ALSO feed 'intraEs' — a per-module directed
      -- caller->callee short-name edge list — which the SCC pass below
      -- ('computeDeadCycles') needs to find dead mutual-recursion cycles
      -- (the 'intraModUsedQ' map loses the source structure a graph
      -- needs).
      ingestEdge (src, dst) (!usersMod, !usedQ, !usersQ, !intraQ, !selfRec, !intraEs) =
        let srcMod = moduleOfQName src
            dstMod = moduleOfQName dst
            dstSh  = shortNameOf dst dstMod
            srcSh  = shortNameOf src srcMod
        in if srcMod == dstMod
              then if src == dst
                then
                  let !s = S.insert (dstMod, dstSh) selfRec
                  in (usersMod, usedQ, usersQ, intraQ, s, intraEs)
                else
                  let !i  = M.insertWith S.union (dstMod, dstSh)
                             (S.singleton srcSh) intraQ
                      !ie = M.insertWith (++) dstMod [(srcSh, dstSh)] intraEs
                  in (usersMod, usedQ, usersQ, i, selfRec, ie)
              else
                let !u1 = M.insertWith S.union dstMod (S.singleton srcMod) usersMod
                    !u2 = M.insertWith S.union srcMod (S.singleton (dstMod, dstSh)) usedQ
                    !u3 = M.insertWith S.union (dstMod, dstSh)
                            (S.singleton srcMod) usersQ
                in (u1, u2, u3, intraQ, selfRec, intraEs)

      (usersMod0, usedQ0, usersQ0, intraModUsedQ0, selfRec0, intraEdges0) =
        foldl' (\acc e -> ingestEdge e acc)
               (M.empty, M.empty, M.empty, M.empty, S.empty, M.empty) egDefinitionEdges

      usedShortInMod = M.map (S.map snd) usedQ0

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
        computeDeadCycles intraEdges0 intraModUsedQ0 usersQ0 rxBySrcQ

  in Context
       { ctxModuleByFile     = moduleByFile
       , ctxDefShortByModule = defShortByMod
       , ctxUsersOfModule    = usersMod0
       , ctxUsedNamesInMod   = usedShortInMod
       , ctxUsedQNames       = usedQ0
       , ctxUsersOfQName     = usersQ0
       , ctxIntraModUsedQ    = intraModUsedQ0
       , ctxSelfRecursive    = selfRec0
       , ctxDeadCycles       = deadCycles0
       , ctxAllModules       = S.fromList egModules
       , ctxRxShortsByHost   = rxShortsByHost
       , ctxRxBySourceQ      = rxBySrcQ
       , ctxRxByHost         = rxByHost
       , ctxRxShortsByPair   = rxShortsByPair
       , ctxSourceTokens     = sourceTokens
       , ctxSourceBodies     = sourceBodies
       , ctxDefLineByQ       = defLineByQ
       , ctxDefAccessByQ     = defAccessByQ
       , ctxTrivialBody      = trivialBody
       }

-- ** Per-file logic

findingsForFile :: Context -> FilePath -> Text -> [Finding]
findingsForFile ctx fp body = case M.lookup fp (ctxModuleByFile ctx) of
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
    let imports     = scanImports body
        bodyToks    = bodyTokens body
        primary     = S.findMin thisMods  -- deterministic representative
        userFacing  = S.filter (not . isAnonymousModule) thisMods
    in concatMap (perImportFindings ctx fp primary bodyToks) imports
    ++ duplicateUsingFindings fp imports
    ++ concat
         [ definedButUnused ctx fp m
             (M.findWithDefault S.empty m (ctxDefShortByModule ctx))
         ++ publicReexportFindings ctx fp m imports
         | m <- S.toList userFacing
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
  | sym `S.member` bodyToks = []
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
checkBlanket ctx _fp thisMod _bodyToks lineNo modName =
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
      tokenShortsHit = S.intersection _bodyToks reexShorts
      reexportedHit  = S.intersection usedShorts reexShorts
  in if S.null directFromM
       && S.null tokenShortsHit
       && S.null reexportedHit
        then [ Finding
                 { fileFinding   = _fp
                 , lineFinding   = lineNo
                 , kindFinding   = UnusedBlanketOpen
                 , moduleFinding = modName
                 , symbolFinding = Nothing
                 , noteFinding   = Just "no symbol from this module is referenced (best-effort)"
                 , confFinding   = High
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
      , kindFinding   = if dead then DefinedDead else DefinedInternalOnly
      , moduleFinding = thisMod
      , symbolFinding = Just sh
      , noteFinding   = Just $
          if isCycle
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
                        then "deletion candidate (low confidence: trivial body, possibly inlined)"
                        else "deletion candidate"
          else "intra-module callers only"
      , confFinding   = if S.null intra && trivial && not selfRec then Low else High
      }
  | sh <- S.toAscList shorts
  , let trivial        = (thisMod, sh) `S.member` ctxTrivialBody ctx
        selfRec        = (thisMod, sh) `S.member` ctxSelfRecursive ctx
        deadCyclePeers = M.lookup (thisMod, sh) (ctxDeadCycles ctx)
        isCycle        = isJust deadCyclePeers
        peersText      = T.intercalate ", " (S.toAscList (fromMaybe S.empty deadCyclePeers))
  , S.null (usersClosure ctx (thisMod, sh))
  , let intra = M.findWithDefault S.empty (thisMod, sh) (ctxIntraModUsedQ ctx)
  -- A def is reported 'DefinedDead' when it has NO intra-module caller
  -- OR it is a dead-cycle member (its only callers are the cycle's
  -- other members). 'internalOnly' is the complement: real intra-module
  -- users the deletion note must not claim away. 'dead' gates the
  -- source-text suppression below (both the plain-dead and cycle cases
  -- can be masked by a live inlined mention).
  , let dead         = S.null intra || isCycle
        internalOnly = not (S.null intra) && not isCycle
  -- 'crossFile' (short name used in some OTHER file) and 'inFileUse'
  -- (occurs beyond the def's signature + LHS in THIS file) are the two
  -- halves of the elaborator-inlining suppression below. Bound once
  -- here so the two dead-branch guards share the single cross-file scan
  -- instead of each recomputing it. 'countsInFile' says whether the
  -- in-file count is meaningful: it is NOT for self-recursive or cycle
  -- members, whose own / mutual RHS calls inflate the count and are
  -- already explained by the graph's self / intra-cycle edges.
  , let crossFile    = mentionedCrossFile ctx fp sh
        inFileUse     = countToken sh (M.findWithDefault T.empty fp (ctxSourceBodies ctx)) > 2
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

-- | True if @sh@ appears in the body tokens of some file OTHER than
-- @fp@. 'definedButUnused' combines this (the cross-file half of the
-- elaborator-inlining dead-FP suppression) with an in-file
-- occurrence-count check. Iterates the key-ordered 'M.toList' so it
-- stays determinism-safe.
mentionedCrossFile :: Context -> FilePath -> Text -> Bool
mentionedCrossFile ctx fp sh =
  any (\(p, toks) -> p /= fp && S.member sh toks)
      (M.toList (ctxSourceTokens ctx))

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
-- Per module, run 'stronglyConnComp' over the intra-module directed
-- call graph (@caller -> callee@ short names; self-edges are already
-- excluded upstream). A 'CyclicSCC' of size >= 2 is dead as a unit iff
-- NO member is reachable from outside the cycle — i.e. no member has a
-- cross-module / re-export user ('usersClosureCore' empty) and no member
-- has an intra-module caller from OUTSIDE the SCC. Each member of a dead
-- cycle maps to the set of its OTHER members' short names (for the
-- finding note). Deterministic: modules iterated in key order, the SCC
-- input built from sorted node / adjacency lists.
computeDeadCycles
  :: M.Map Text [(Text, Text)]         -- ^ per-module intra edges (caller, callee)
  -> M.Map (Text, Text) (S.Set Text)   -- ^ intra-module callers ('ctxIntraModUsedQ')
  -> M.Map (Text, Text) (S.Set Text)   -- ^ cross-module users ('ctxUsersOfQName')
  -> M.Map (Text, Text) (S.Set Text)   -- ^ re-export hosts ('ctxRxBySourceQ')
  -> M.Map (Text, Text) (S.Set Text)
computeDeadCycles intraEdges intraCallers usersQ rxBySrcQ =
  M.fromList
    [ ((m, sh), S.delete sh members)
    | (m, edges)  <- M.toList intraEdges
    , CyclicSCC vs <- stronglyConnComp (sccInput edges)
    , length vs >= 2
    , let members = S.fromList vs
    , cycleIsDead m members
    , sh <- S.toAscList members
    ]
  where
    -- Directed adjacency for one module, nodes emitted in sorted order.
    sccInput edges =
      let nodes = S.fromList (concat [ [s, d] | (s, d) <- edges ])
          adj   = M.fromListWith S.union [ (s, S.singleton d) | (s, d) <- edges ]
      in [ (n, n, S.toAscList (M.findWithDefault S.empty n adj))
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

-- ** Cross-file duplicate detection

duplicateUsingsAcrossFiles :: Context -> [Finding]
duplicateUsingsAcrossFiles _ = []

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
      byMod = foldr bucket M.empty imports
      bucket il acc =
        M.insertWith (++) (ilModule il, ilScope il) [il] acc
  in [ Finding
         { fileFinding   = fp
         , lineFinding   = ilLine il
         , kindFinding   = DuplicateUsingForModule
         , moduleFinding = m
         , symbolFinding = Nothing
         , noteFinding   = Just $ "another `open import` of this module already exists in the file"
         , confFinding   = High
         }
     | ((m, _scope), ils) <- M.toList byMod
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
                   DuplicateUsingForModule -> "duplicate `using` clause for module"
                   PublicWithoutDownstream -> "re-export with no downstream user"
      note     = case noteFinding f of
                   Just n  -> " (" ++ T.unpack n ++ ")"
                   Nothing -> ""
  in lineCol ++ " " ++ sym ++ "   -- " ++ tag ++ note

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
