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
import           Data.Time.Clock    (diffUTCTime, getCurrentTime)
import           Data.Time.Format.ISO8601 (iso8601Show)
import           System.Directory   (doesPathExist)
import           System.FilePath    (isAbsolute, normalise, (</>))
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
-- ('interactTools') only when started with @--enable-interact@.
enabledTools :: ServerState -> [Tool]
enabledTools ss = graphTools ++ [ t | cfgEnableInteract (ssConfig ss), t <- interactTools ]

-- | The @format@ property, shared by the list tools (search / callers /
-- callees). Kept terse — the structured-output contract is in the skill.
fmtProp :: (Text, Value)
fmtProp = ("format", ep "`text` (default) or `json` (structured envelope)." ["text", "json"])

graphTools :: [Tool]
graphTools =
  [ Tool "brief"
      "One-call orientation on a definition: location + blast radius, type, \
      \direct callers/callees (capped), and closest body-twins. Lead with this; \
      \use the individual tools to go deeper on a section."
      (objSchema [ ("name", sp "FQN or unique dotted-suffix (resolved as `locate`).")
                 , ("limit", ip "Max callers/callees per section (default 10).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryBrief ld (argInt a "limit" 10) n))

  , Tool "locate"
      "Where a definition lives: module, file:line, kind, state, visibility, \
      \caller/dependency counts, blast radius, and enclosing owner for a \
      \where-helper. Use instead of grepping for a definition site."
      (objSchema [("name", sp "FQN or unique dotted-suffix; a unique near-match is auto-resolved, ambiguous names list candidates.")] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryLocate ld n))

  , Tool "callers"
      "Who uses a definition (reverse dependency edges); `transitive` walks the \
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
      "What a definition depends on (forward dependency edges); `transitive` \
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
      "Blast radius of changing a definition's type: everything that \
      \transitively depends on it, by module. Answers \"what breaks if I change X?\"."
      (objSchema [ ("name", sp "Definition you intend to change.")
                 , ("limit", ip "Max affected definitions (default 60).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryImpact ld (argInt a "limit" 60) n))

  , Tool "path"
      "Shortest dependency chain `from → … → to` along uses-edges, each hop \
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
      "Which assumptions a definition rests on: its transitive postulate/primitive \
      \(or a given kind/state) dependencies, each with a witness chain. Answers \
      \\"what axioms does theorem T depend on?\" (see the skill for record-field axioms)."
      (objSchema [ ("name", sp "Definition (e.g. a theorem) to audit.")
                 , ("kind", sp "Restrict roots to this kind (function|projection|datatype|record|constructor|postulate|primitive|other). Default: postulate + primitive.")
                 , ("state", sp "Restrict roots to this state (defined|postulate|hole|failed).")
                 , ("module_prefix", sp "Only roots whose module starts with this prefix.")
                 , ("by_module", bp "Per-module count summary instead of a list (default false).")
                 , ("chains", bp "Show a witness chain per root (default true).")
                 , ("limit", ip "Max roots (default 20).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryRoots ld (argInt a "limit" 20)
                                 (argBool a "by_module" False) (argBool a "chains" True)
                                 (argText a "module_prefix")
                                 (argText a "kind") (argText a "state") n))

  , Tool "type_of"
      "The type signature of a definition — the elaborated (type-checker) form \
      \by default, or the as-written source with `source=true`."
      (objSchema [ ("name", sp "Definition whose type signature you want.")
                 , ("source", bp "Show the as-written source signature instead of the elaborated type (default false).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFreshFailFast ss n (\ld ->
          readSignature ld (cfgEntries (ssConfig ss)) (argBool a "source" False)
            (cfgNormaliseSigs (ssConfig ss)) (cfgShowImplicit (ssConfig ss)) n))

  , Tool "similar_types"
      "Definitions whose type-signature shape resembles X's (Weisfeiler-Leman \
      \fingerprint Jaccard; same core as the `silhouette` analysis). Answers \
      \\"what else has a type shaped like X's?\"."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.5).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarTypes ld (argInt a "limit" 10) (argDouble a "min_sim" 0.5) n))

  , Tool "similar_bodies"
      "Definitions whose elaborated bodies share canonical AST subterms (same \
      \core as the `term-cluster` analysis). Answers \"what else is implemented \
      \like X?\"."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarBodies ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3) n))

  , Tool "find_lemma"
      "Goal-directed lemma search: find definitions whose conclusion resembles a \
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
                   (argText a "goal") (argText a "anchor")))

  , Tool "search"
      "Find definitions whose qualified name contains a substring, ranked by \
      \match tightness; `kind`/`state`/`module_prefix` filter (an empty `query` \
      \plus a filter *lists* all of a kind/state)."
      (objSchema [ ("query", sp "Case-insensitive substring; may be empty when a kind/state/module_prefix filter is given.")
                 , ("kind", sp "Filter by kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("state", sp "Filter by state: defined|postulate|hole|failed.")
                 , ("module_prefix", sp "Only definitions whose module starts with this prefix.")
                 , ("limit", ip "Max results (default 30).")
                 , ("top_level_only", bp "Drop where-block / anonymous-module locals (default false).")
                 , fmtProp
                 ] [])
      (\ss a -> withFresh ss (\ld ->
                  querySearch ld (argBool a "top_level_only" False)
                    (argText a "module_prefix")
                    (argText a "kind") (argText a "state") (argInt a "limit" 30)
                    (parseFmt (argText a "format"))
                    (fromMaybe "" (argText a "query"))))

  , Tool "unused"
      "Run agda-unused over the graph: unused imports, duplicate opens, and \
      \(opt-in) dead definitions, confidence-tagged. See the skill for the \
      \false-positive caveats."
      (objSchema [ ("scope", sp "Restrict to a directory, file, or module name (e.g. `Prelude.Init`); relative to project root. Default: project root.")
                 , ("kinds", sp "agda-unused --kinds value, e.g. `all` or `using,duplicate`.")
                 , ("exclude", sp "Comma-separated globs matched against each finding's file path and module name (`**` spans dirs, `*` stops at `/`); a match drops the finding.")
                 , ("group_by", sp "Per-group counts instead of per-finding lines: `dir`, `file`, or `kind`.")
                 , ("count_only", bp "Print only the grand total (default false; wins over group_by).")
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
    Left err          -> pure (Left (T.pack err))
    Right (ld, stale) -> do
      noteRebuilt ss stale
      r <- f ld
      pure $ case r of
        Left err  -> Left err
        Right txt -> Right (txt <> if stale then staleFooter ld else "")

-- | The fail-fast wrapper used by @type_of@. Before paying the
-- 'ensureFresh' barrier (which may schedule a background
-- rebuild and serve stale), it resolves @name@ against the
-- /already-loaded/ snapshot. If a snapshot exists and the name is absent
-- from it ('nameInSnapshot' 'False'), it answers the 'notInGraph' message
-- instantly — no 'ensureFresh' scan, no scheduled rebuild — recording the
-- request as non-stale telemetry. Only when the name resolves, or no
-- snapshot exists yet, does it fall through to 'withFreshIO'/'ensureFresh'
-- (so a genuinely-present name still gets the freshness path, and the
-- first-ever query still blocks on the one build as before).
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
      -- Fast path: absent from the current snapshot, answer instantly.
      noteRebuilt ss False
      pure (Right (notInGraph ld (cfgEntries (ssConfig ss)) name))
    _ -> withFreshIO ss f                   -- present, or no snapshot yet

runUnused :: ToolRunner
runUnused ss a = do
  e <- ensureFresh ss
  case e of
    Left err -> pure (Left ("cannot prepare graph: " <> T.pack err))
    Right (ld, stale) -> do
      noteRebuilt ss stale
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
                  uargs = [ "--json=" ++ cfgGraphPath c
                          , "--rel-to=" ++ cfgProjectRoot c ]
                       ++ maybe [] (\k -> ["--kinds=" ++ T.unpack k]) mkinds
                       ++ [ "--exclude=" ++ T.unpack g | g <- excls ]
                       ++ maybe [] (\v -> ["--group-by=" ++ T.unpack v]) mgroupBy
                       ++ [ "--count-only" | countOnly ]
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
              pure (Right (header <> caveat <> T.pack body
                             <> if stale then staleFooter ld else ""))
  where
    caveat =
      "Note: `using` and `duplicate` findings are high-signal. `blanket`, \
      \`defined`, and `public` are best-effort — instance methods and names \
      \used only through `with`/`with ←` chains are known false positives. \
      \Each `dead` finding now carries a confidence tag in its note: \
      \high-confidence deletion candidates are safe, but verify the \
      \low-confidence ones (`low confidence: trivial body, possibly inlined`) \
      \before removing — the elaborator may have inlined the callee.\n\n"

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
