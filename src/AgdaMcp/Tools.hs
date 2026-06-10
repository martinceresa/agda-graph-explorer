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

import           Data.Aeson         (Value (..), object, parseJSON, (.=))
import qualified Data.Aeson.Key     as Key
import qualified Data.Aeson.KeyMap  as KM
import           Data.Aeson.Types   (parseMaybe)
import           Data.IORef         (readIORef)
import           Data.List          (isPrefixOf)
import qualified Data.Map.Strict    as M
import           Data.Maybe         (fromMaybe)
import           Data.Text          (Text)
import qualified Data.Text          as T
import           System.Directory   (doesPathExist)
import           System.FilePath    (isAbsolute, normalise, (</>))
import           System.Process     (CreateProcess (..), proc,
                                     readCreateProcessWithExitCode)

import           AgdaMcp.Query
import           AgdaMcp.Rpc
import           AgdaMcp.State
import qualified BuildInfo

-- ---------------------------------------------------------------------
-- Argument helpers
-- ---------------------------------------------------------------------

argLookup :: Value -> Text -> Maybe Value
argLookup (Object o) k = KM.lookup (Key.fromText k) o
argLookup _          _ = Nothing

argText :: Value -> Text -> Maybe Text
argText v k = argLookup v k >>= parseMaybe parseJSON

argInt :: Value -> Text -> Int -> Int
argInt v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

argBool :: Value -> Text -> Bool -> Bool
argBool v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

argDouble :: Value -> Text -> Double -> Double
argDouble v k d = fromMaybe d (argLookup v k >>= parseMaybe parseJSON)

-- ---------------------------------------------------------------------
-- JSON-schema builders
-- ---------------------------------------------------------------------

objSchema :: [(Text, Value)] -> [Text] -> Value
objSchema props req = object
  [ "type"                 .= ("object" :: Text)
  , "properties"           .= object [ Key.fromText k .= v | (k, v) <- props ]
  , "required"             .= req
  , "additionalProperties" .= False
  ]

sp, ip, bp, np :: Text -> Value
sp d = object ["type" .= ("string" :: Text),  "description" .= d]
ip d = object ["type" .= ("integer" :: Text), "description" .= d]
bp d = object ["type" .= ("boolean" :: Text), "description" .= d]
np d = object ["type" .= ("number" :: Text),  "description" .= d]

-- ---------------------------------------------------------------------
-- Tool catalogue
-- ---------------------------------------------------------------------

type ToolRunner = ServerState -> Value -> IO (Either Text Text)

data Tool = Tool
  { tName   :: !Text
  , tDesc   :: !Text
  , tSchema :: !Value
  , tRun    :: !ToolRunner
  }

tools :: [Tool]
tools =
  [ Tool "locate"
      "Where a definition lives: its module, source file:line, kind, state, \
      \visibility, direct caller/dependency counts, and transitive blast radius. \
      \For a where-/anonymous-module helper it also reports the enclosing \
      \top-level `owner`. Accepts a fully-qualified name or any unique \
      \dotted-suffix (e.g. `liveness′`). Use instead of grepping for a \
      \definition site."
      (objSchema [("name", sp "Fully-qualified name or any unique dotted-suffix of one.")] ["name"])
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
      (\ss a -> needName a $ \n -> withFreshIO ss (\ld ->
          readSignature ld (argBool a "source" False)
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
                 , ("module_prefix", sp "Only list definitions whose module starts with this prefix (e.g. `Protocol.Jolteon.Block`).")
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
      \caveat. The response header echoes the resolved scope, effective kinds, \
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
                 ] [])
      runUnused

  , Tool "rebuild"
      "Force-regenerate the dependency graph now (runs agda-deps, reusing \
      \Agda's .agdai cache) and report fresh statistics. Normally unnecessary \
      \— queries auto-rebuild when sources change."
      (objSchema [] [])
      (\ss _ -> do
          e <- forceRebuild ss
          pure $ case e of
            Left err -> Left (T.pack err)
            Right ld -> Right ("Rebuilt graph.\n" <> queryStats ld))

  , Tool "status"
      "Daemon configuration and the current snapshot's freshness and \
      \statistics. Does not trigger a rebuild."
      (objSchema [] [])
      (\ss _ -> Right <$> statusText ss)
  ]

needName :: Value -> (Text -> IO (Either Text Text)) -> IO (Either Text Text)
needName a go = case argText a "name" of
  Nothing -> pure (Left "missing required argument: name")
  Just n  -> go n

withFresh :: ServerState -> (Loaded -> Text) -> IO (Either Text Text)
withFresh ss f = do
  e <- ensureFresh ss
  pure $ case e of Left err -> Left (T.pack err); Right ld -> Right (f ld)

withFreshIO :: ServerState -> (Loaded -> IO (Either Text Text)) -> IO (Either Text Text)
withFreshIO ss f = do
  e <- ensureFresh ss
  case e of Left err -> pure (Left (T.pack err)); Right ld -> f ld

runUnused :: ToolRunner
runUnused ss a = do
  e <- ensureFresh ss
  case e of
    Left err -> pure (Left ("cannot prepare graph: " <> T.pack err))
    Right ld -> do
      let c = ssConfig ss
      mscope <- resolveScope c ld (argText a "scope")
      case mscope of
        Left serr   -> pure (Left serr)
        Right scope -> do
          mbin <- findBin "agda-unused" (cfgUnusedBin c) "AGDA_UNUSED_BIN"
          case mbin of
            Nothing  -> pure (Left "could not locate the agda-unused binary (set AGDA_UNUSED_BIN or pass --agda-unused-bin)")
            Just bin -> do
              let mkinds = argText a "kinds"
                  excls  = maybe [] (filter (not . T.null) . T.splitOn ",") (argText a "exclude")
                  uargs = [ "--json=" ++ cfgGraphPath c
                          , "--rel-to=" ++ cfgProjectRoot c ]
                       ++ maybe [] (\k -> ["--kinds=" ++ T.unpack k]) mkinds
                       ++ [ "--exclude=" ++ T.unpack g | g <- excls ]
                       ++ [scope]
              (_ec, out, err) <-
                readCreateProcessWithExitCode (proc bin uargs) { cwd = Just (cfgProjectRoot c) } ""
              let body   = if null out then err else out
                  -- Self-describing header: resolved scope, effective
                  -- kinds, and exclude globs, so "0 findings" can't be
                  -- mistaken for a mis-scoped or over-excluded run.
                  header = "scope: " <> T.pack scope <> "\n"
                        <> "kinds: " <> fromMaybe "(agda-unused default)" mkinds <> "\n"
                        <> (if null excls then ""
                              else "exclude: " <> T.intercalate ", " excls <> "\n")
                        <> "\n"
              pure (Right (header <> caveat <> T.pack body))
  where
    caveat =
      "Note: `using` and `duplicate` findings are high-signal. `blanket`, \
      \`defined`, and `public` are best-effort — instance methods and names \
      \used only through `with`/`with ←` chains are known false positives, so \
      \grep-verify a deletion candidate before removing it.\n\n"

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
  let c = ssConfig ss
      base = T.unlines
        [ "agda-explore status"
        , "  server build: " <> T.pack BuildInfo.buildFingerprint
        , "  binary:       " <> T.pack bin
        , "  project root: " <> T.pack (cfgProjectRoot c)
        , "  entry:        " <> maybe "(none — preloaded graph)" T.pack (cfgEntry c)
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
  Just "tools/list"                -> reply (object ["tools" .= map toolInfo tools])
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
  Just tn -> case [ t | t <- tools, tName t == tn ] of
    []      -> pure (errorResponse theId codeMethodNotFound ("unknown tool: " <> tn))
    (t : _) -> do
      let args = fromMaybe (Object KM.empty) (argLookup params "arguments")
      r <- tRun t ss args
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
