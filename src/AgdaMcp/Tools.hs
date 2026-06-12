{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The MCP surface of the @agda-explore@ daemon: the lifecycle handlers
-- (@initialize@ / @ping@ / @tools\/list@ / @tools\/call@) and the tool
-- catalogue itself. Each tool turns a point query (or a rebuild) into a
-- block of text the model reads — these are the calls that replace
-- @grep@-driven exploration of an Agda corpus.
module AgdaMcp.Tools
  ( dispatch
  ) where

import           Data.Aeson         (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap  as KM
import           Data.IORef         (readIORef, writeIORef)
import           Data.List          (isPrefixOf)
import qualified Data.Map.Strict    as M
import           Data.Maybe         (fromMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           Data.Time.Clock    (diffUTCTime, getCurrentTime)
import           Data.Time.Format.ISO8601 (iso8601Show)
import           System.Directory   (doesPathExist)
import           System.FilePath    (isAbsolute, normalise, (</>))
import           System.Process     (CreateProcess (..), proc,
                                     readCreateProcessWithExitCode)

import           AgdaInteract.Tools (interactTools)
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

graphTools :: [Tool]
graphTools =
  [ Tool "locate"
      "Where a definition lives: its module, source file:line, kind, state, \
      \visibility, direct caller/dependency counts, and transitive blast radius. \
      \For a where-/anonymous-module helper it also reports the enclosing \
      \top-level `owner`. Accepts a fully-qualified name or any unique \
      \dotted-suffix (e.g. `liveness′`); a single unambiguous near-match \
      \(case-insensitive infix) is resolved automatically, with a one-line \
      \`(auto-resolved …)` note. Use instead of grepping for a definition site."
      (objSchema [("name", sp "Fully-qualified name or any unique dotted-suffix of one. A single unambiguous near-match is auto-resolved (noted in the output); ambiguous names list candidates.")] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryLocate ld n))

  , Tool "callers"
      "Who uses a definition (reverse dependency edges). `transitive` walks the \
      \whole upstream cone. `module_prefix` keeps only callers under a module \
      \path; `provenance` keeps only direct edges of one kind \
      \(signature/body/where/with) — e.g. `body` for genuine term-level uses vs \
      \`signature` for in-scope/type-level mentions — and annotates each direct \
      \line with its tag; `by_module` returns a per-module count summary instead \
      \of a flat list (good for large fan-out). Replaces `grep -rn '\\bname\\b'`."
      (objSchema [ ("name", sp "Definition to find callers of.")
                 , ("transitive", bp "Walk all transitive callers (default false).")
                 , ("module_prefix", sp "Only include callers whose module starts with this prefix.")
                 , ("provenance", sp "Keep only direct edges of this provenance: signature|body|where|with|unknown.")
                 , ("by_module", bp "Summarise as per-module counts instead of a flat list (default false).")
                 , ("limit", ip "Max results to list (default 50).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryCallers ld (argBool a "transitive" False)
                                 (argText a "module_prefix") (argText a "provenance")
                                 (argBool a "by_module" False) (argInt a "limit" 50) n))

  , Tool "callees"
      "What a definition depends on (forward dependency edges). `transitive` \
      \walks the whole downstream cone. `module_prefix` keeps only \
      \dependencies under a module path; `provenance` keeps only direct edges of \
      \one kind (signature/body/where/with) and annotates each direct line with \
      \its tag; `by_module` returns a per-module count summary instead of a flat \
      \list."
      (objSchema [ ("name", sp "Definition to find dependencies of.")
                 , ("transitive", bp "Walk all transitive dependencies (default false).")
                 , ("module_prefix", sp "Only include dependencies whose module starts with this prefix.")
                 , ("provenance", sp "Keep only direct edges of this provenance: signature|body|where|with|unknown.")
                 , ("by_module", bp "Summarise as per-module counts instead of a flat list (default false).")
                 , ("limit", ip "Max results to list (default 50).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryCallees ld (argBool a "transitive" False)
                                 (argText a "module_prefix") (argText a "provenance")
                                 (argBool a "by_module" False) (argInt a "limit" 50) n))

  , Tool "impact"
      "Blast radius of changing a definition's type/signature: every \
      \definition that transitively depends on it, summarised by module. \
      \Answers \"what breaks if I change X?\"."
      (objSchema [ ("name", sp "Definition you intend to change.")
                 , ("limit", ip "Max affected definitions to list (default 60).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFresh ss (\ld -> queryImpact ld (argInt a "limit" 60) n))

  , Tool "path"
      "Shortest dependency chain from one definition to another: the sequence \
      \`from → … → to` along forward (uses) edges, showing *why* `from` \
      \transitively depends on `to`. Each hop is annotated with its edge \
      \provenance (`{body}`/`{where}`/`{signature}`/`{with}`). Set `k > 1` to \
      \return several distinct shortest paths (useful when the first runs \
      \through a helper you don't care about); a non-positive `k` is clamped to \
      \1 with a note. `module_prefix` keeps the chain within a module subtree. \
      \Answers \"how does this proof reach that assumption?\" in one call."
      (objSchema [ ("from", sp "Start definition (the user / dependent).")
                 , ("to", sp "End definition (the dependency to reach).")
                 , ("k", ip "Max number of distinct shortest paths to return (default 1).")
                 , ("module_prefix", sp "Only route through intermediate nodes whose module starts with this prefix (endpoints exempt).")
                 ] ["from", "to"])
      (\ss a -> case (argText a "from", argText a "to") of
          (Just f, Just t) -> withFresh ss (\ld ->
              queryPath ld (argInt a "k" 1) (argText a "module_prefix") f t)
          _                -> pure (Left "path requires both `from` and `to` arguments."))

  , Tool "roots"
      "Which assumptions a definition ultimately rests on: its transitive \
      \dependencies that are postulates / primitives (or a given `kind`/`state`), \
      \each with a shortest witnessing chain. Answers \"what axioms does theorem \
      \T depend on?\" in one call. For a project whose axioms live in record \
      \fields rather than postulates, scope with `kind=projection \
      \module_prefix=<your Assumptions module>` to audit exactly those. \
      \`by_module` gives a per-module count summary and `chains=false` drops the \
      \witness chains — both for scanning a large root set."
      (objSchema [ ("name", sp "Definition (e.g. a theorem) to audit.")
                 , ("kind", sp "Restrict roots to this structural kind \
                               \(function|projection|datatype|record|constructor|postulate|primitive|other). \
                               \Default: postulate + primitive.")
                 , ("state", sp "Restrict roots to this lifecycle state (defined|postulate|hole|failed).")
                 , ("module_prefix", sp "Only report roots whose module starts with this prefix (e.g. an Assumptions module).")
                 , ("by_module", bp "Summarise roots as per-module counts instead of a list (default false).")
                 , ("chains", bp "Show a witness chain per root (default true; set false for a bare list).")
                 , ("limit", ip "Max roots to list (default 20).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> queryRoots ld (argInt a "limit" 20)
                                 (argBool a "by_module" False) (argBool a "chains" True)
                                 (argText a "module_prefix")
                                 (argText a "kind") (argText a "state") n))

  , Tool "type_of"
      "The type signature of a definition. By default this is the *elaborated* \
      \type reified from the type-checker (fully qualified, Agda's default \
      \printing — so numeric literals and instance dictionaries may be expanded). \
      \Set `source=true` to show the signature as *written* in the file instead \
      \(best-effort for multi-line signatures). The reified form's \
      \normalise / show-implicit dimensions are daemon-level settings; the output \
      \footer reports the active mode."
      (objSchema [ ("name", sp "Definition whose type signature you want.")
                 , ("source", bp "Show the as-written source signature instead of the elaborated type (default false).")
                 ] ["name"])
      (\ss a -> needName a $ \n -> withFreshFailFast ss n (\ld ->
          readSignature ld (cfgEntries (ssConfig ss)) (argBool a "source" False)
            (cfgNormaliseSigs (ssConfig ss)) (cfgShowImplicit (ssConfig ss)) n))

  , Tool "similar_types"
      "Definitions whose type-signature *shape* resembles X's, ranked by \
      \weighted Jaccard of their Weisfeiler-Leman signature fingerprints. \
      \Uses the same shared core as the batch `silhouette` analysis, so a \
      \100-percent hit is exactly one of X's structural twins there. Answers \
      \\"what else has a type shaped like X's?\"."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.5).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarTypes ld (argInt a "limit" 10) (argDouble a "min_sim" 0.5) n))

  , Tool "similar_bodies"
      "Definitions whose elaborated bodies share canonical AST subterms, \
      \ranked by occurrence-weighted Jaccard of their subterm-hash multisets \
      \— the same per-def view the batch `term-cluster` analysis buckets over. \
      \Answers \"what else is implemented like X?\". Requires a graph built \
      \with term hashes (the daemon does this by default)."
      (objSchema [ ("name", sp "Reference definition.")
                 , ("limit", ip "Max results (default 10).")
                 , ("min_sim", np "Minimum similarity 0..1 (default 0.3).")
                 ] ["name"])
      (\ss a -> needName a $ \n ->
          withFresh ss (\ld -> querySimilarBodies ld (argInt a "limit" 10) (argDouble a "min_sim" 0.3) n))

  , Tool "find_lemma"
      "Goal-directed lemma search: find existing definitions whose \
      \*conclusion* (result type) resembles a proof goal, so you can reuse a \
      \lemma instead of re-deriving it. Two modes (supply EXACTLY ONE of \
      \`goal`/`anchor`): (1) `anchor=<existing def>` ranks by the same \
      \Weisfeiler-Leman signature-fingerprint shape as `similar_types` (true \
      \structural matching, requires a graph node with edges); (2) \
      \`goal=\"<rendered goal type>\"` canonicalises the free-text goal, takes \
      \its conclusion (after the last top-level arrow), and ranks candidate \
      \signatures by identifier-token Jaccard over their conclusions — a \
      \name-overlap proxy, NOT WL (an out-of-graph string has no edges to \
      \fingerprint). Optional `kind`/`module_prefix` filter candidates. \
      \Free-text mode needs a signatures-enabled graph (the daemon default); \
      \against a signature-less graph it returns a rebuild note."
      (objSchema [ ("goal", sp "Free-text goal type to match (e.g. `xs ++ [] ≡ xs`); mutually exclusive with `anchor`. Ranks by conclusion-token overlap.")
                 , ("anchor", sp "An existing definition whose result type is the goal shape; mutually exclusive with `goal`. Ranks by WL signature-fingerprint shape (like `similar_types`).")
                 , ("kind", sp "Restrict candidates to this structural kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("module_prefix", sp "Only consider candidates whose module starts with this prefix.")
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
      \match tightness. Use to discover exact names before other queries. \
      \`kind` (function/projection/datatype/record/constructor/postulate/\
      \primitive/other), `state` (defined/postulate/hole/failed), and \
      \`module_prefix` filter structurally — supply any of them with an empty \
      \`query` to *list* (e.g. every postulate, or every datatype under a \
      \module subtree). Set `top_level_only` to drop where-block / \
      \anonymous-module locals."
      (objSchema [ ("query", sp "Substring to search for (case-insensitive). May be empty when kind/state/module_prefix is given.")
                 , ("kind", sp "Filter by structural kind: function|projection|datatype|record|constructor|postulate|primitive|other.")
                 , ("state", sp "Filter by lifecycle state: defined|postulate|hole|failed.")
                 , ("module_prefix", sp "Only list definitions whose module starts with this prefix (e.g. `Data.List.Base`).")
                 , ("limit", ip "Max results (default 30).")
                 , ("top_level_only", bp "Drop where-block / anonymous-module locals (default false).")
                 ] [])
      (\ss a -> withFresh ss (\ld ->
                  querySearch ld (argBool a "top_level_only" False)
                    (argText a "module_prefix")
                    (argText a "kind") (argText a "state") (argInt a "limit" 30)
                    (fromMaybe "" (argText a "query"))))

  , Tool "unused"
      "Run agda-unused over the current graph: unused `using` imports, \
      \duplicate opens, and (opt-in) dead definitions. High-signal for \
      \import hygiene; carries the known instance/`with`-clause false-positive \
      \caveat. Each `dead` finding is tagged high- or low-confidence (the \
      \low ones have trivial bodies the elaborator may have inlined) — verify \
      \low-confidence ones before deleting; high-confidence ones are safe. \
      \The response header echoes the resolved scope, effective kinds, \
      \and any exclude globs, and the trailing `# excluded:` line reports how \
      \many findings the excludes suppressed."
      (objSchema [ ("scope", sp "Restrict the scan to a directory, file, or module name \
                                 \(e.g. `Prelude.Init`). Relative paths resolve against the \
                                 \project root; a scope matching no module is rejected. \
                                 \Default: project root.")
                 , ("kinds", sp "agda-unused --kinds value, e.g. `all` or `using,duplicate`.")
                 , ("exclude", sp "Comma-separated *glob(s)* (not substrings) tested against \
                                   \each finding's absolute file path and dotted module name; a \
                                   \finding is dropped if either matches. `**` spans directories, \
                                   \`*` stops at `/`, `?` is one char — e.g. `**/Init.agda` for a \
                                   \re-export hub, or `Prelude.*`. The output's `# excluded:` line \
                                   \reports how many findings were suppressed.")
                 , ("group_by", sp "Aggregate findings into per-group counts instead of one \
                                    \line per finding: `dir` (directory of the relativised path), \
                                    \`file` (relativised path), or `kind`. Rows are sorted by \
                                    \descending count, ties broken by group key.")
                 , ("count_only", bp "Print only the grand total (default false). Wins over \
                                      \group_by if both are set.")
                 ] [])
      runUnused

  , Tool "rebuild"
      "Force-regenerate the dependency graph now (runs agda-deps, reusing \
      \Agda's .agdai cache) and report fresh statistics. Normally unnecessary \
      \— queries auto-rebuild when sources change."
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
-- flight. Every tool runner that calls 'ensureFresh' threads the E1
-- @(Loaded, Bool)@ stale flag through here; 'handleCall' reads + resets it
-- after the runner returns. (The @rebuild@ tool sets 'True', @status@
-- 'False' directly — see the catalogue.)
noteRebuilt :: ServerState -> Bool -> IO ()
noteRebuilt ss = writeIORef (ssLastRebuilt ss)

withFresh :: ServerState -> (Loaded -> Text) -> IO (Either Text Text)
withFresh ss f = do
  e <- ensureFresh ss
  case e of
    Left err          -> pure (Left (T.pack err))
    Right (ld, stale) -> do
      noteRebuilt ss stale
      pure (Right (f ld <> if stale then staleFooter ld else ""))

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

-- | The E2 fail-fast wrapper used by @type_of@. Before paying the
-- 'ensureFresh' barrier (which, post-E1, may schedule a background
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
  bin      <- binaryIdent
  banner   <- stalenessBanner ss
  watching <- isWatching ss
  -- A plain IORef read — status never acquires the rebuild lock, so it is
  -- answerable even while a background rebuild holds it (the point of
  -- serve-stale). True ⇒ a rebuild is pending/in-flight and queries are
  -- being served from the prior snapshot until it lands.
  dirty    <- readIORef (ssDirty ss)
  let c = ssConfig ss
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
                                  else if dirty
                                    then "in flight (serving stale; status never blocks on it)"
                                    else "idle (snapshot is fresh)")
        , "  term hashes:  " <> (if cfgWithHashes c then "on" else "off")
        ]
  pure $ banner <> base <> "\n" <> case cur of
    Nothing -> "No graph built yet — it will build on the first query (or call `rebuild`)."
    Just ld -> "Loaded snapshot built at " <> T.pack (show (ldBuiltAt ld)) <> ".\n"
                 <> "  graph built by: " <> fromMaybe "(unknown — older producer)" (ldProducer ld) <> "\n"
                 <> "  node-key format: v" <> T.pack (show (ldNodeKeyV ld))
                 <> (if ldNodeKeyV ld < currentNodeKeyVersion
                       then " (STALE — this binary produces v"
                              <> T.pack (show currentNodeKeyVersion)
                              <> "; rebuild to refresh)"
                       else " (current)")
                 <> "\n\n" <> queryStats ld

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
      -- Telemetry (E6): time the runner, capture whether it triggered a
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
