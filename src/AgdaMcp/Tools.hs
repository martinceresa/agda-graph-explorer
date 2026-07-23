{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The MCP surface of the @agda-explore@ daemon: the lifecycle handlers
-- (@initialize@ / @ping@ / @tools\/list@ / @tools\/call@) and the tool
-- catalogue itself. Each tool turns a point query (or a rebuild) into a
-- block of text the model reads — these are the calls that replace
-- @grep@-driven exploration of an Agda corpus.
module AgdaMcp.Tools
  ( dispatch
  , enabledTools
  ) where

import           Data.Aeson         (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap  as KM
import           Data.IORef         (modifyIORef', readIORef, writeIORef)
import           Data.List          (isPrefixOf, sortOn)
import qualified Data.Map.Strict    as M
import           Data.Maybe         (fromMaybe)
import           Data.Ord           (Down (..))
import           Data.Text          (Text)
import qualified Data.Text          as T
import qualified Data.Set           as Set
import           Data.Time.Clock    (NominalDiffTime, diffUTCTime,
                                     getCurrentTime)
import           Data.Time.Format.ISO8601 (iso8601Show)
import           System.Directory   (doesPathExist)
import           System.Exit        (ExitCode (..))
import           System.FilePath    (isAbsolute, normalise, (</>))
import           Text.Read          (readMaybe)
import           System.Process     (CreateProcess (..), proc,
                                     readCreateProcessWithExitCode)

import           AgdaInteract.Tools (interactTools)
import           AgdaMcp.Inspect    (InspectEvent (..), emitInspect)
import           AgdaMcp.Query
import           AgdaMcp.Rpc
import           AgdaMcp.State
import           AgdaMcp.ToolDef
import qualified BuildInfo

-- ---------------------------------------------------------------------
-- Tool catalogue
-- ---------------------------------------------------------------------

-- | The tool catalogue available for this server state: the read-side
-- graph queries always, plus the write-side interaction-bridge tools
-- ('interactTools') only when started with @--enable-interact@. Under
-- @--tool-tier core@ the catalogue is narrowed to 'coreToolNames' (the
-- measured-used subset) to cut the agent's per-choice decision-load; every
-- tool stays reachable through the one-shot @query@ CLI regardless.
enabledTools :: ServerState -> [Tool]
enabledTools ss = tierFilter (graphTools ++ interact)
  where
    interact = [ t | cfgEnableInteract (ssConfig ss), t <- interactTools ]
    tierFilter = case cfgToolTier (ssConfig ss) of
      TierFull -> id
      TierCore -> filter ((`Set.member` coreToolNames) . tName)

-- | The tools advertised under @--tool-tier core@: the read + validate/diagnose
-- surface agents were measured to actually use (2026-07 telemetry), plus
-- @brief@/@goal_brief@ (the designed one-call orientation entry points). The
-- authoring tools (auto/construct/scratch/give_file/new_module) and the
-- rarely-hit reads (path/roots/similar_*) are @full@-only. Keep in sync with
-- the plugin skill and the PreToolUse routing message.
coreToolNames :: Set.Set Text
coreToolNames = Set.fromList
  [ -- read
    "brief", "locate", "search", "callers", "callees", "type_of"
  , "find_lemma", "impact", "unused", "status", "rebuild"
    -- interaction (validate / diagnose loop)
  , "load", "goal_brief", "inspect", "check", "repair", "lemmas"
  ]

-- | The @format@ property, shared by the list tools (search / callers /
-- callees). Kept terse — the structured-output contract is in the skill.
fmtProp :: (Text, Value)
fmtProp = ("format", ep "`text` (default) or `json` (structured envelope)." ["text", "json"])

graphTools :: [Tool]
graphTools =
  [ Tool "brief"
      "[orient] One-call orientation on a definition: location + blast radius, type, \
      \direct callers/callees (capped), and closest body-twins. Lead with this; \
      \use the individual tools to go deeper on a section."
      (objSchema [ ("name", sp "FQN or unique dotted-suffix (resolved as `locate`).")
                 , ("limit", ip "Max callers/callees per section (default 10).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryBrief ld (argInt a "limit" 10) n))

  , Tool "locate"
      "[find] Where a definition lives: module, file:line, kind, state, visibility, \
      \caller/dependency counts, blast radius, and enclosing owner for a \
      \where-helper. Use instead of grepping for a definition site. Needs a \
      \resolvable name — if a short or operator name misses, run `search` \
      \first to get the fully-qualified name."
      (objSchema [("name", sp "FQN or unique dotted-suffix; a unique near-match is auto-resolved, ambiguous names list candidates.")] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryLocate ld n))

  , Tool "callers"
      "[trace] Who uses a definition (reverse dependency edges); `transitive` walks the \
      \whole upstream cone. Replaces `grep -rn '\\bname\\b'`."
      (objSchema [ ("name", sp "Definition to find callers of.")
                 , ("transitive", bp "Walk all transitive callers (default false).")
                 , ("module_prefix", sp "Only callers whose module starts with this prefix.")
                 , ("provenance", sp "Keep only direct edges of this provenance: signature|body|module-local|with|unknown (where=module-local).")
                 , ("by_module", bp "Per-module count summary instead of a flat list (default false).")
                 , ("limit", ip "Max results (default 50).")
                 , fmtProp
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryCallers ld (argBool a "transitive" False)
                                 (argText a "module_prefix") (argText a "provenance")
                                 (argBool a "by_module" False) (argInt a "limit" 50)
                                 (parseFmt (argText a "format")) n))

  , Tool "callees"
      "[trace] What a definition depends on (forward dependency edges); `transitive` \
      \walks the whole downstream cone."
      (objSchema [ ("name", sp "Definition to find dependencies of.")
                 , ("transitive", bp "Walk all transitive dependencies (default false).")
                 , ("module_prefix", sp "Only dependencies whose module starts with this prefix.")
                 , ("provenance", sp "Keep only direct edges of this provenance: signature|body|module-local|with|unknown (where=module-local).")
                 , ("by_module", bp "Per-module count summary instead of a flat list (default false).")
                 , ("limit", ip "Max results (default 50).")
                 , fmtProp
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryCallees ld (argBool a "transitive" False)
                                 (argText a "module_prefix") (argText a "provenance")
                                 (argBool a "by_module" False) (argInt a "limit" 50)
                                 (parseFmt (argText a "format")) n))

  , Tool "impact"
      "[trace] Blast radius of changing a definition's type: everything that \
      \transitively depends on it, by module. Answers \"what breaks if I change X?\". \
      \Leads with a ⚠ soundness-taint line when the subject carries or rests on a \
      \non-terminating/trustme escape (every dependent inherits it)."
      (objSchema [ ("name", sp "Definition you intend to change.")
                 , ("limit", ip "Max affected definitions (default 60).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryImpact ld (argInt a "limit" 60) n))

  , Tool "path"
      "[trace] Shortest dependency chain `from → … → to` along uses-edges, each hop \
      \tagged with its provenance — why `from` transitively needs `to`. `k>1` \
      \returns several distinct paths."
      (objSchema [ ("from", sp "Start definition (the dependent).")
                 , ("to", sp "End definition (the dependency to reach).")
                 , ("k", ip "Max distinct shortest paths (default 1).")
                 , ("module_prefix", sp "Only route through intermediate nodes under this module prefix (endpoints exempt).")
                 ] ["from", "to"])
      (\ss a -> case (argText a "from", argText a "to") of
          (Just f, Just t) -> withFresh ss (\ld ->
              queryPath ld (argInt a "k" 1) (argText a "module_prefix") f t)
          _                -> pure (Left "path requires both `from` and `to` arguments."))

  , Tool "roots"
      "[trace] Which assumptions a definition rests on: its transitive postulate/primitive \
      \(or a given kind/state) dependencies, each with a witness chain. Answers \
      \\"what axioms does theorem T depend on?\" (see the skill for record-field axioms). \
      \With `unsafe=any` it is a transitive soundness audit — the non-terminating/trustme \
      \escapes reachable through its dependency cone, each witnessed."
      (objSchema [ ("name", sp "Definition (e.g. a theorem) to audit.")
                 , ("kind", sp "Restrict roots to this kind (function|projection|datatype|record|constructor|postulate|primitive|other). Default: postulate + primitive.")
                 , ("state", sp "Restrict roots to this state (defined|postulate|hole|failed).")
                 , ("unsafe", sp "Soundness audit: `any` lists every transitive soundness escape the subject rests on, or a specific escape — a declaration kind (`non-terminating` | `trustme`) or a module OPTIONS flag (e.g. `--type-in-type` | `--no-positivity-check`). Overrides the postulate/primitive default; each escape is witnessed by its chain.")
                 , ("module_prefix", sp "Only roots whose module starts with this prefix.")
                 , ("by_module", bp "Per-module count summary instead of a list (default false).")
                 , ("chains", bp "Show a witness chain per root (default true).")
                 , ("limit", ip "Max roots (default 20).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryRoots ld (argInt a "limit" 20)
                                 (argBool a "by_module" False) (argBool a "chains" True)
                                 (argText a "module_prefix")
                                 (argText a "kind") (argText a "state") (argText a "unsafe") n))

  , Tool "type_of"
      "[find] The type signature of a definition — the elaborated (type-checker) form \
      \by default, or the as-written source with `source=true`. Needs a \
      \resolvable name — if a short or operator name misses, run `search` \
      \first to get the fully-qualified name."
      (objSchema [ ("name", sp "Definition whose type signature you want.")
                 , ("source", bp "Show the as-written source signature instead of the elaborated type (default false).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFreshFailFast ss n (\ld ->
          readSignature ld (cfgEntries (ssConfig ss)) (argBool a "source" False)
            (cfgNormaliseSigs (ssConfig ss)) (cfgShowImplicit (ssConfig ss)) n))

  , Tool "similar_types"
      "[reuse] Definitions whose type-signature shape resembles X's (Weisfeiler-Leman \
      \fingerprint Jaccard; same core as the `silhouette` analysis). Answers \
      \\"what else has a type shaped like X's?\"."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.5).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarTypes ld (argInt a "limit" 10) (argDouble a "min_sim" 0.5) n))

  , Tool "similar_bodies"
      "[reuse] Definitions whose elaborated bodies share canonical AST subterms (same \
      \core as the `term-cluster` analysis). Answers \"what else is implemented \
      \like X?\"."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarBodies ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3) n))

  , Tool "find_lemma"
      "[reuse] Goal-directed lemma search: find definitions whose conclusion resembles a \
      \goal, to reuse instead of re-deriving. Supply EXACTLY ONE of `anchor` (an \
      \existing def; WL shape match) or `goal` (free-text type; conclusion-token \
      \match) — see the skill for the mode contract."
      (objSchema [ ("goal", sp "Free-text goal type (e.g. `xs ++ [] ≡ xs`); ranks by conclusion-token overlap. Exclusive with `anchor`.")
                 , ("anchor", sp "An existing def whose result type is the goal shape; ranks by WL fingerprint. Exclusive with `goal`.")
                 , ("kind", sp "Restrict candidates to this kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("module_prefix", sp "Only candidates whose module starts with this prefix.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] [])
      (\ss a -> case (argText a "goal", argText a "anchor") of
          (Just _, Just _) -> pure (Left "find_lemma takes exactly one of `goal` or `anchor`, not both.")
          (Nothing, Nothing) -> pure (Left "find_lemma requires one of `goal` (free-text type) or `anchor` (an existing definition).")
          _ -> withFresh ss (\ld ->
                 queryFindLemma ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3)
                   (argText a "kind") (argText a "module_prefix")
                   (argText a "goal") (argText a "anchor") []))

  , Tool "search"
      "[find] Find definitions whose qualified name contains a substring, ranked by \
      \match tightness; `kind`/`state`/`module_prefix` filter (an empty `query` \
      \plus a filter *lists* all of a kind/state). Start here when you only \
      \know part of a name (or a mixfix operator like `_++_`), then feed the \
      \fully-qualified result to `type_of`/`locate`/`callers`. `mode=text` \
      \instead greps the source bytes with ripgrep (pragmas, comments, \
      \`using`-lists, regex — anything the graph doesn't index); those hits \
      \are always current, independent of the graph snapshot."
      (objSchema [ ("query", sp "In name mode: case-insensitive substring (may be empty with a kind/state/module_prefix filter). In text mode: a ripgrep pattern (regex).")
                 , ("mode", sp "name (default; searches definition names via the graph) | text (ripgreps source bytes — use for pragmas/comments/regex the graph doesn't index).")
                 , ("kind", sp "Filter by kind: function|projection|datatype|record|constructor|postulate|primitive|other. (name mode only)")
                 , ("state", sp "Filter by state: defined|postulate|hole|failed. (name mode only)")
                 , ("unsafe", sp "Filter by soundness escape (name mode): `any` lists every unsafe def (an agda --safe-style audit), or a specific escape — a declaration kind (`non-terminating` | `trustme`) or a module OPTIONS flag (e.g. `--type-in-type` | `--no-positivity-check`). Combine with an empty `query` to enumerate.")
                 , ("module_prefix", sp "Only definitions whose module starts with this prefix. (name mode only)")
                 , ("limit", ip "Max results (default 30).")
                 , ("top_level_only", bp "Drop where-block / anonymous-module locals (default false). (name mode only)")
                 , fmtProp
                 ] [])
      (\ss a -> case argText a "mode" of
          Just "text" -> runSearchText ss a
          _           -> withFresh ss (\ld ->
                  querySearch ld (argBool a "top_level_only" False)
                    (argText a "module_prefix")
                    (argText a "kind") (argText a "state") (argText a "unsafe")
                    (argInt a "limit" 30)
                    (parseFmt (argText a "format"))
                    (fromMaybe "" (argText a "query"))))

  , Tool "unused"
      "[audit] Run agda-unused over the graph: unused imports, duplicate opens, and \
      \(opt-in) dead definitions, confidence-tagged. See the skill for the \
      \false-positive caveats."
      (objSchema [ ("scope", sp "Restrict to a directory, file, or module name (e.g. `Prelude.Init`); relative to project root. Default: project root.")
                 , ("kinds", sp "agda-unused --kinds value, e.g. `all` or `using,duplicate`.")
                 , ("exclude", sp "Comma-separated globs matched against each finding's file path and module name (`**` spans dirs, `*` stops at `/`); a match drops the finding.")
                 , ("group_by", sp "Per-group counts instead of per-finding lines: `dir`, `file`, or `kind`.")
                 , ("count_only", bp "Print only the grand total (default false; wins over group_by).")
                 , fmtProp
                 ] [])
      runUnused

  , Tool "rebuild"
      "Force-regenerate the dependency graph now (runs agda-deps). Normally \
      \unnecessary — queries auto-rebuild when sources change."
      (objSchema [] [])
      (\ss _ -> do
          -- The @rebuild@ tool always (force-)rebuilds: stale=True.
          writeIORef (ssLastRebuilt ss) True
          e <- forceRebuild ss
          pure $ case e of
            Left err -> Left (T.pack err)
            Right ld -> Right ("Rebuilt graph.\n" <> queryStats ld))

  , Tool "status"
      "Daemon configuration and the current snapshot's freshness and \
      \statistics. Does not trigger a rebuild."
      (objSchema [] [])
      (\ss _ -> do
          -- @status@ never rebuilds: stale=False.
          writeIORef (ssLastRebuilt ss) False
          Right <$> statusText ss)
  ]

-- | The single line appended to a tool's rendered output when
-- 'ensureFresh' served a /stale/ snapshot — i.e. a rebuild is in flight in
-- the background and these results reflect the snapshot built at the given
-- time, not a guaranteed-fresh one. Plain text only (no structured JSON
-- field), matching the existing footer style. The model reads this and
-- knows to re-query (or call @rebuild@) for fresh results.
staleFooter :: Loaded -> Text
staleFooter ld =
  "\n# stale: graph is rebuilding in the background; results reflect the snapshot built at "
    <> T.pack (show (ldBuiltAt ld))

-- | Appended whenever the served snapshot came from a build that reported
-- failed/unparseable modules ('ldFailed' non-empty). A parse error under
-- the default @--keep-going@ producer drops the offending module's
-- definitions from the graph while the build still "succeeds" (agda-deps
-- exits 0), so an unqualified "no match" would otherwise read as
-- authoritative — a confident false negative. This flags it. Louder
-- when the graph is empty (a whole-file parse error can drop every def).
-- Fires independently of the rebuilding-stale flag and in every mode.
healthFooter :: Loaded -> Text
healthFooter ld = case ldFailed ld of
  []     -> ""
  failed ->
    "\n# partial: the last build reported " <> T.pack (show (length failed))
      <> " failed/unparseable module(s) (e.g. "
      <> T.intercalate ", " (take 3 failed)
      <> "); some definitions may be missing — a \"no match\" here is not "
      <> "authoritative. Fix the source and re-query."

-- | Appended when the backing graph predates a source edit
-- ('ldStaleVsSource'). Unlike 'staleFooter' (a live rebuild is in flight),
-- this fires from the snapshot's own precomputed flag, so it also surfaces
-- in preloaded mode — which 'ensureFresh' otherwise reports as never-stale.
-- Silent when there is nothing to compare (bare @--graph@, in-memory
-- union).
sourceStaleFooter :: Loaded -> Text
sourceStaleFooter ld
  | ldStaleVsSource ld =
      "\n# stale: the graph file is older than a source file under the "
        <> "include roots — it predates an edit; results may not reflect "
        <> "the current sources (rebuild, or restart with a fresh --graph)."
  | otherwise = ""

-- | Appended to a /watched/-mode read whose snapshot is behind a source edit
-- the fsnotify watcher has not yet turned into a rebuild (debounce lag).
-- Distinct from 'staleFooter' (a rebuild is actually in flight): here none is
-- scheduled yet, so the answer is transiently behind. Flags the confident
-- false negative with how far behind it is.
pendingFooter :: NominalDiffTime -> Text
pendingFooter dt =
  "\n# stale: a source file under the include roots was edited " <> secs
    <> " ago and the graph rebuild has not fired yet — this answer may be "
    <> "behind, so a \"no match\" is not authoritative. Re-query shortly."
  where
    secs = T.pack (show (max (1 :: Int) (round dt))) <> "s"

-- | The rebuild-side footer for a served snapshot's 'Freshness': the
-- background-rebuild note ('staleFooter'), the pending-rebuild note, or
-- nothing when 'Fresh'. The snapshot's own health / source-staleness footers
-- ('snapshotFooters') are appended separately and fire regardless.
freshnessFooter :: Loaded -> Freshness -> Text
freshnessFooter _  Fresh              = ""
freshnessFooter ld Rebuilding         = staleFooter ld
freshnessFooter _  (BehindPending dt) = pendingFooter dt

-- | The health + source-staleness footers a served snapshot always carries,
-- regardless of the rebuilding-stale flag. Threaded into every read answer.
snapshotFooters :: Loaded -> Text
snapshotFooters ld = sourceStaleFooter ld <> healthFooter ld

-- | Plain-text footers ('staleFooter' / 'snapshotFooters') corrupt a
-- @format:json@ answer (they append prose after the envelope), so append
-- them only when the payload is human-readable text. A JSON answer is
-- recognised by its first non-space byte (@{@ or @[@) — every structured
-- envelope here is a JSON object; the staleness/coverage signal is carried
-- in-band there instead (e.g. @unsearched_files@) or via @status@.
appendTextFooters :: Text -> Text -> Text
appendTextFooters footers txt
  | T.null footers          = txt
  | isJsonPayload txt       = txt
  | otherwise               = txt <> footers
  where
    isJsonPayload t = case T.uncons (T.stripStart t) of
      Just (c, _) -> c == '{' || c == '['
      Nothing     -> False

-- | Record the @stale@ telemetry column for the request currently in
-- flight. Every tool runner that calls 'ensureFresh' threads the
-- @(Loaded, Bool)@ stale flag through here; 'handleCall' reads + resets it
-- after the runner returns. (The @rebuild@ tool sets 'True', @status@
-- 'False' directly — see the catalogue.)
noteRebuilt :: ServerState -> Bool -> IO ()
noteRebuilt ss = writeIORef (ssLastRebuilt ss)

withFresh :: ServerState -> (Loaded -> Text) -> IO (Either Text Text)
withFresh ss f = withFreshIO ss (pure . Right . f)

withFreshIO :: ServerState -> (Loaded -> IO (Either Text Text)) -> IO (Either Text Text)
withFreshIO ss f = do
  e <- ensureFresh ss
  case e of
    Left err       -> pure (Left (T.pack err))
    Right (ld, fr) -> do
      noteRebuilt ss (freshnessStale fr)
      r <- f ld
      pure $ case r of
        Left err  -> Left err
        Right txt -> Right (appendTextFooters
                              (freshnessFooter ld fr <> snapshotFooters ld)
                              txt)

-- | The fail-fast wrapper used by @type_of@. Before paying the
-- 'ensureFresh' barrier (which may schedule a background
-- rebuild and serve stale), it resolves @name@ against the
-- /already-loaded/ snapshot. If a snapshot exists and the name is absent
-- from it ('nameInSnapshot' 'False'), it answers the 'notInGraph' message
-- instantly — no 'ensureFresh' scan, no scheduled rebuild — recording the
-- request as non-stale telemetry. Only when the name resolves, or no
-- snapshot exists yet, does it fall through to 'withFreshIO'/'ensureFresh'
-- (so a genuinely-present name still gets the freshness path, and the
-- first-ever query still blocks on the one build).
--
-- @isError=false@: a not-in-graph result is a normal lookup outcome, like
-- @locate@'s. The 'notInGraph' text is rendered from the same snapshot the
-- real 'readSignature' would use, so the slow and fast paths agree.
withFreshFailFast
  :: ServerState
  -> Text                                  -- ^ the queried name
  -> (Loaded -> IO (Either Text Text))     -- ^ the freshness-gated action
  -> IO (Either Text Text)
withFreshFailFast ss name f = do
  cur <- readIORef (ssLoaded ss)
  case cur of
    Just ld | not (nameInSnapshot ld name) -> do
      -- Fast path: absent from the current snapshot, answer instantly — but
      -- still carry the partial/source-stale footers, since "not in graph"
      -- is exactly the answer a partial (parse-failed) build makes unsound.
      noteRebuilt ss False
      pure (Right (appendTextFooters (snapshotFooters ld)
                     (notInGraph ld (cfgEntries (ssConfig ss)) name)))
    _ -> withFreshIO ss f                   -- present, or no snapshot yet

runUnused :: ToolRunner
runUnused ss a = do
  e <- ensureFresh ss
  case e of
    Left err -> pure (Left ("cannot prepare graph: " <> T.pack err))
    Right (ld, fr) -> do
      noteRebuilt ss (freshnessStale fr)
      let c = ssConfig ss
      mscope <- resolveScope c ld (argText a "scope")
      case mscope of
        Left serr   -> pure (Left serr)
        Right scope -> do
          mbin <- findBin "agda-unused" (cfgUnusedBin c) "AGDA_UNUSED_BIN"
          case mbin of
            Nothing  -> pure (Left "could not locate the agda-unused binary (set AGDA_UNUSED_BIN or pass --agda-unused-bin)")
            Just bin -> do
              let mkinds   = argText a "kinds"
                  excls    = maybe [] (filter (not . T.null) . T.splitOn ",") (argText a "exclude")
                  mgroupBy  = argText a "group_by"
                  countOnly = argBool a "count_only" False
                  jsonOut   = parseFmt (argText a "format") == FmtJson
                  uargs = [ "--json=" ++ cfgGraphPath c
                          , "--rel-to=" ++ cfgProjectRoot c ]
                       ++ maybe [] (\k -> ["--kinds=" ++ T.unpack k]) mkinds
                       ++ [ "--exclude=" ++ T.unpack g | g <- excls ]
                       ++ maybe [] (\v -> ["--group-by=" ++ T.unpack v]) mgroupBy
                       ++ [ "--count-only" | countOnly ]
                       -- agda-unused's --json-out already emits the array to
                       -- stdout (and suppresses its stderr breadcrumb), so
                       -- format:json just captures it verbatim below.
                       ++ [ "--json-out" | jsonOut ]
                       ++ [scope]
              (_ec, out, err) <-
                readCreateProcessWithExitCode (proc bin uargs) { cwd = Just (cfgProjectRoot c) } ""
              let body   = if null out then err else out
                  -- Self-describing header: resolved scope, effective
                  -- kinds, exclude globs, and any aggregation mode, so
                  -- "0 findings" can't be mistaken for a mis-scoped or
                  -- over-excluded run.
                  header = "scope: " <> T.pack scope <> "\n"
                        <> "kinds: " <> fromMaybe "(agda-unused default)" mkinds <> "\n"
                        <> (if null excls then ""
                              else "exclude: " <> T.intercalate ", " excls <> "\n")
                        <> maybe "" (\v -> "group_by: " <> v <> "\n") mgroupBy
                        <> (if countOnly then "count_only: true\n" else "")
                        <> "\n"
              -- JSON mode returns the agda-unused array verbatim (the text
              -- header/caveat/footers would corrupt it, like `search`
              -- format:json); text mode keeps the self-describing wrapping.
              pure . Right $
                if jsonOut
                  then T.pack body
                  else header <> caveat <> T.pack body
                         <> freshnessFooter ld fr
                         <> snapshotFooters ld
  where
    caveat =
      "Note: `using` and `duplicate` findings are high-signal. `blanket`, \
      \`defined`, and `public` are best-effort — instance methods and names \
      \used only through `with`/`with ←` chains are known false positives. \
      \Each `dead` finding now carries a confidence tag in its note: \
      \high-confidence deletion candidates are safe, but verify the \
      \low-confidence ones (`low confidence: trivial body, possibly inlined`) \
      \before removing — the elaborator may have inlined the callee.\n\n"

-- | @search mode=text@: ripgrep over the project's source bytes. The graph
-- indexes definitions + edges only, so textual queries (pragmas, comments,
-- @using@-lists, regex, numeric literals) are invisible to name-mode search;
-- this shell-out makes @search@ a superset of grep rather than a
-- different-shaped subset. It reads the current bytes on disk, so
-- it is independent of the graph snapshot — no @ensureFresh@, no staleness
-- caveat. Mirrors 'runUnused''s shell-out (findBin + the same process call).
runSearchText :: ToolRunner
runSearchText ss a
  | T.null q      = pure (Left "search mode=text needs a non-empty `query` (a ripgrep pattern).")
  | all null roots = pure (Left "search mode=text needs a project root or include dirs; none are \
                                \configured (run with --project / -i, not a bare --graph).")
  | otherwise = do
      mbin <- findBin "rg" (cfgRgBin c) "AGDA_EXPLORE_RG"
      case mbin of
        Nothing  -> pure (Left "could not locate ripgrep (`rg`) for text mode — install \
                               \it, set AGDA_EXPLORE_RG, or pass --rg-bin.")
        Just bin -> do
          let rgArgs = [ "-n", "--no-heading", "--color=never", "-S"
                       , "--glob", "*.agda", "--glob", "*.lagda*"
                       , "--", T.unpack q ] ++ roots
          (ec, out, err) <- readCreateProcessWithExitCode
                              (proc bin rgArgs) { cwd = Just (cfgProjectRoot c) } ""
          pure . Right $ case ec of
            -- rg: 0 = matches, 1 = no matches, >=2 = real error.
            ExitFailure n | n >= 2 -> "ripgrep failed (exit " <> T.pack (show n) <> "):\n"
                                        <> T.pack (lastLines 15 err)
            _ -> render (filter (not . null) (lines out))
  where
    c     = ssConfig ss
    q     = fromMaybe "" (argText a "query")
    lim   = max 1 (argInt a "limit" 30)
    fmt   = parseFmt (argText a "format")
    roots = if null (cfgIncludes c) then [cfgProjectRoot c] else cfgIncludes c
    render hits =
      let shown = take lim hits
          more  = length hits - length shown
      in case fmt of
           FmtJson -> listEnvelope "search" (String q) Nothing (length hits)
                        [ "mode" .= ("text" :: Text) ] (map rgRow shown)
           _ | null hits ->
                 "text mode (ripgrep): no matches for `" <> q <> "` under "
                   <> T.intercalate ", " (map T.pack roots) <> "."
             | otherwise ->
                 "text mode (ripgrep over source bytes — always current, not the graph): "
                   <> T.pack (show (length hits)) <> " line(s) for `" <> q <> "`:\n"
                   <> T.unlines (map T.pack shown)
                   <> (if more > 0 then "…and " <> T.pack (show more) <> " more line(s).\n" else "")
    -- rg --no-heading line: "path:line:text". Split on the first two colons;
    -- fall back to a bare text row if the shape is unexpected.
    rgRow ln = case break (== ':') ln of
      (file, ':' : rest) -> case break (== ':') rest of
        (num, ':' : txt) -> object [ "file" .= file
                                   , "line" .= (readMaybe num :: Maybe Int)
                                   , "text" .= txt ]
        _ -> object [ "text" .= ln ]
      _ -> object [ "text" .= ln ]

-- | Resolve the @scope@ argument to an absolute path for @agda-unused@,
-- which keys its module table by /absolute/ path — a relative @scope@
-- would match no module and silently report zero findings. Resolution
-- order:
--
--   * absent scope        -> the project root;
--   * an existing path     -> made absolute (relative paths resolve against
--                             the project root), but only if it actually
--                             covers at least one module in the graph;
--   * else a module name   -> the file recorded for that module;
--   * otherwise            -> an explicit error, never a silent zero.
resolveScope :: Config -> Loaded -> Maybe Text -> IO (Either Text FilePath)
resolveScope c _  Nothing  = pure (Right (cfgProjectRoot c))
resolveScope c ld (Just s) = do
  let raw  = T.unpack s
      abs' = normalise (if isAbsolute raw then raw else cfgProjectRoot c </> raw)
  pathExists <- doesPathExist abs'
  pure $ if pathExists
    then if coversModule abs'
           then Right abs'
           else Left ("scope path exists but covers no modules in the graph: "
                        <> T.pack abs' <> "\n(check the path, or `rebuild` if the "
                        <> "sources are newer than the graph)")
    else case M.lookup s (ldModFiles ld) of
           Just fp -> Right fp                       -- a module name (e.g. Prelude.Init)
           Nothing -> Left ("scope is neither an existing path nor a known module name: "
                              <> s <> "\n(tried path " <> T.pack abs' <> ")")
  where
    coversModule p =
      any (\fp -> let fp' = normalise fp in p == fp' || (p ++ "/") `isPrefixOf` fp')
          (M.elems (ldModFiles ld))

statusText :: ServerState -> IO Text
statusText ss = do
  cur      <- readIORef (ssLoaded ss)
  cold     <- readIORef (ssColdError ss)
  bin      <- binaryIdent
  banner   <- stalenessBanner ss
  watching <- isWatching ss
  -- Plain IORef reads — status never acquires the rebuild lock, so it stays
  -- answerable even while a background rebuild holds it (the point of
  -- serve-stale). `dirty` ⇒ a rebuild is pending; `building` ⇒ one is
  -- actually running right now (ssDirty is cleared at build start, so it
  -- alone goes False mid-build — see 'AgdaMcp.State.ssBuilding'). Either way
  -- queries are served from the prior snapshot until the build lands.
  dirty    <- readIORef (ssDirty ss)
  building <- readIORef (ssBuilding ss)
  counts   <- readIORef (ssToolCounts ss)
  let c = ssConfig ss
      -- Per-run adoption histogram (see 'ssToolCounts'); top rows only,
      -- with the standard `…and N more` tail.
      usage
        | M.null counts = ""
        | otherwise =
            let rows = sortOn (\(n, k) -> (Down k, n)) (M.toList counts)
                top  = take 15 rows
                more = length rows - length top
            in "  tool usage (this run):\n"
                 <> T.unlines [ "    " <> n <> ": " <> T.pack (show k) | (n, k) <- top ]
                 <> (if more > 0 then "    …and " <> T.pack (show more) <> " more tools\n" else "")
      base = T.unlines
        [ "agda-explore status"
        , "  server build: " <> T.pack BuildInfo.buildFingerprint
        , "  binary:       " <> T.pack bin
        , "  project root: " <> T.pack (cfgProjectRoot c)
        , "  entries:      " <> (if null (cfgEntries c)
                                  then "(none — preloaded graph)"
                                  else T.intercalate ", " (map T.pack (cfgEntries c)))
        , "  includes:     " <> (if null (cfgIncludes c) then "(none)"
                                  else T.intercalate ", " (map T.pack (cfgIncludes c)))
        , "  graph file:   " <> T.pack (cfgGraphPath c)
        , "  mode:         " <> (if cfgPreloaded c
                                  then "preloaded (no auto-rebuild)"
                                  else "live (auto-rebuild "
                                         <> (if cfgAutoRebuild c then "on" else "off") <> ")")
        , "  staleness:    " <> (if cfgPreloaded c then "n/a (preloaded)"
                                  else if watching then "fsnotify watcher (event-driven)"
                                  else if cfgWatch c then "polling (watcher unavailable)"
                                  else "polling (watcher disabled)")
        , "  rebuild:      " <> (if cfgPreloaded c then "n/a (preloaded)"
                                  else if dirty || building
                                    then "in flight (serving stale; status never blocks on it)"
                                    else "idle (snapshot is fresh)")
        , "  term hashes:  " <> (if cfgWithHashes c then "on" else "off")
        ]
  pure $ banner <> base <> usage <> "\n" <> case cur of
    Nothing -> case cold of
      Just diag -> "Cold start — no graph yet:\n  " <> diag
                     <> "\n(retrying in the background; will self-heal once the corpus builds)"
      Nothing   -> "No graph built yet — it will build on the first query (or call `rebuild`)."
    Just ld -> "Loaded snapshot built at " <> T.pack (show (ldBuiltAt ld)) <> ".\n"
                 <> "  graph built by: " <> fromMaybe "(unknown — older producer)" (ldProducer ld) <> "\n"
                 <> "  node-key format: v" <> T.pack (show (ldNodeKeyV ld))
                 <> (if ldNodeKeyV ld < currentNodeKeyVersion
                       then " (STALE — this binary produces v"
                              <> T.pack (show currentNodeKeyVersion)
                              <> "; rebuild to refresh)"
                       else " (current)")
                 <> "\n  graph id:       config=" <> ldConfigHash ld
                       <> " content=" <> ldContentHash ld
                 <> "\n    (config = producer flags + node-key/schema version + "
                       <> "build-date-stripped producer; content = sorted def "
                       <> "name/kind/state — a change flags added/dropped defs)"
                 <> (if null (ldFailed ld) then ""
                       else "\n  failed modules: " <> T.pack (show (length (ldFailed ld)))
                              <> " (e.g. " <> T.intercalate ", " (take 3 (ldFailed ld))
                              <> ") — graph is PARTIAL; some definitions are missing")
                 <> (if ldStaleVsSource ld
                       then "\n  source vs graph: STALE — graph file predates a source edit"
                       else "")
                 <> "\n\n" <> queryStats ld
                 <> (case orphanWarning (ldOrphanFiles ld) of
                       "" -> ""
                       w  -> "\n\n" <> w)

-- ---------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------

-- | Handle one decoded JSON-RPC message. 'Nothing' means "notification,
-- no reply".
dispatch :: ServerState -> RpcMsg -> IO (Maybe Value)
dispatch ss msg = case rpcMethod msg of
  Just "initialize"                -> reply (initResult (rpcParams msg))
  Just "notifications/initialized" -> pure Nothing
  Just "notifications/cancelled"   -> pure Nothing
  Just "ping"                      -> reply (object [])
  Just "tools/list"                -> reply (object ["tools" .= map toolInfo (enabledTools ss)])
  Just "tools/call"                -> Just <$> handleCall ss theId (rpcParams msg)
  Just other -> case rpcId msg of
    Just _  -> pure (Just (errorResponse theId codeMethodNotFound ("method not found: " <> other)))
    Nothing -> pure Nothing
  Nothing -> case rpcId msg of
    Just _  -> pure (Just (errorResponse theId codeInvalidParams "missing method"))
    Nothing -> pure Nothing
  where
    theId   = fromMaybe Null (rpcId msg)
    reply r = pure (Just (resultResponse theId r))

handleCall :: ServerState -> Value -> Value -> IO Value
handleCall ss theId params = case argText params "name" of
  Nothing -> pure (errorResponse theId codeInvalidParams "tools/call: missing tool name")
  Just tn -> case [ t | t <- enabledTools ss, tName t == tn ] of
    []      -> pure (errorResponse theId codeMethodNotFound ("unknown tool: " <> tn))
    (t : _) -> do
      let args = fromMaybe (Object KM.empty) (argLookup params "arguments")
      -- Adoption telemetry: count every dispatch per tool name (rendered by
      -- @status@), so which tools agents actually reach for is visible
      -- without parsing transcripts.
      modifyIORef' (ssToolCounts ss) (M.insertWith (+) tn 1)
      -- Telemetry: time the runner, capture whether it triggered a
      -- live rebuild (the runner writes 'ssLastRebuilt'; reset first so a
      -- runner that doesn't touch it reads a clean False), and append one
      -- JSON line per tools/call when cfgQueryLog is on. This is the single
      -- place where the tool name, the raw arguments Value, and the
      -- Right/Left result are all in scope. Logging never affects the reply
      -- (appendQueryLog swallows its own IO failures).
      writeIORef (ssLastRebuilt ss) False
      t0 <- getCurrentTime
      r  <- tRun t ss args
      t1 <- getCurrentTime
      stale <- readIORef (ssLastRebuilt ss)
      let durMs = realToFrac (diffUTCTime t1 t0) * 1000 :: Double
          ok    = either (const False) (const True) r
      if cfgQueryLog (ssConfig ss)
        then appendQueryLog ss $ object
               [ "ts"     .= iso8601Show t1
               , "tool"   .= tn
               , "args"   .= args
               , "dur_ms" .= durMs
               , "ok"     .= ok
               , "stale"  .= stale
               ]
        else pure ()
      -- Tee the same event to the web inspector (no-op when --inspect is
      -- off). This is the single point where every tools/call's name, args,
      -- result, timing, and stale flag are all in scope.
      emitInspect (ssInspect ss) $ EvTool
        { evTool   = tn
        , evArgs   = args
        , evDurMs  = durMs
        , evOk     = ok
        , evStale  = stale
        , evResult = either id id r
        }
      pure $ resultResponse theId $ case r of
        Right txt -> callResult False txt
        Left  err -> callResult True err

callResult :: Bool -> Text -> Value
callResult isErr txt = object
  [ "content" .= [ object ["type" .= ("text" :: Text), "text" .= txt] ]
  , "isError" .= isErr
  ]

toolInfo :: Tool -> Value
toolInfo t = object
  [ "name" .= tName t, "description" .= tDesc t, "inputSchema" .= tSchema t ]

initResult :: Value -> Value
initResult params = object
  [ "protocolVersion" .= fromMaybe protocolVersionDefault (argText params "protocolVersion")
  , "capabilities"    .= object ["tools" .= object []]
  , "serverInfo"      .= object ["name" .= ("agda-explore" :: Text), "version" .= ("0.1" :: Text)]
  ]
