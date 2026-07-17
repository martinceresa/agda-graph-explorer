{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for @agda-explore@: an interactive MCP (Model Context
-- Protocol) server that turns @agda-deps@' dependency graph into live,
-- point-query tools for an agent exploring an Agda library.
--
-- It loads the expanded @graph.json@ once into an in-memory 'Index' and
-- serves queries (locate / callers / callees / impact / type / similar /
-- unused) over stdio. When the project's sources change it transparently
-- regenerates the graph by spawning @agda-deps@ as a subprocess (see
-- "AgdaMcp.State").
--
-- Usage (typically wired up by the bundled Claude Code plugin):
--
-- > agda-explore --entry agda-src/Main.lagda.md -i agda-src
-- > agda-explore --graph path/to/deps.json        # fixed snapshot, no rebuild
--
-- With no flags it discovers a project from the current directory.
module Main (main) where

import           Control.Concurrent (forkIO)
import           Control.Exception  (SomeException, finally, try)
import           Control.Monad      (forM, void, when)
import           Data.Aeson         (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key     as Key
import           Data.List          (intercalate, isPrefixOf, isSuffixOf,
                                     partition, sortOn)
import           Data.Maybe         (fromMaybe)
import qualified Data.Text          as T
import qualified Data.Text.IO       as TIO
import           System.Directory   (doesDirectoryExist, doesFileExist,
                                     getCurrentDirectory, listDirectory,
                                     makeAbsolute, removePathForcibly)
import           System.Environment (getArgs, lookupEnv)
import           System.Exit        (exitFailure, exitSuccess)
import           System.FilePath    (isAbsolute, splitSearchPath, takeDirectory,
                                     takeFileName, (</>))
import           System.IO          (hPutStrLn, stderr)

import           AgdaGraph.ConfigCore (firstExisting)
import           AgdaMcp.Config     (Opts (..), applyConfig,
                                     discoverConfigPath, extractConfigArg,
                                     loadConfig, orderNub)
import           AgdaMcp.Control    (startControl)
import           AgdaMcp.Inspect    (startInspector)
import           AgdaMcp.Rpc        (runStdioLoop)
import           AgdaMcp.State
import           AgdaMcp.ToolDef    (Tool (..))
import           AgdaInteract.Tools (closeAllSessions, interactTools,
                                     reapIdleSessions)
import           AgdaMcp.Tools      (dispatch, enabledTools)
import qualified BuildInfo

-- ---------------------------------------------------------------------
-- CLI options
-- ---------------------------------------------------------------------

-- | 'Opts' lives in "AgdaMcp.Config" so the YAML layer can overlay onto
-- it without an import cycle.

defOpts :: Opts
defOpts = Opts
  { oGraph = Nothing, oEntries = [], oIncl = [], oProj = Nothing
  , oOut = Nothing, oDeps = Nothing, oUnused = Nothing
  , oHashes = True, oSigs = True, oNormSigs = False, oShowImpl = False
  , oMinDepth = 3, oAuto = True, oWatch = True, oIncremental = True, oQueryLog = True
  , oRequireWellTyped = False, oStrictProducer = False
  , oAutoResolve = True
  , oEnableInteract = False, oAgdaBin = Nothing, oInteractArgs = []
  , oInteractHeapMb = 0, oMaxSessions = 2, oSessionIdleSecs = 0
  , oInspect = False, oInspectPort = 7000
  , oAutoHints = True, oAutoHintsLimit = 3, oAutoHintsSecs = 1
  , oControlPort = 0
  , oCoverageIgnore = []
  , oOverlayGraphs = []
  , oHelp = False, oVer = False
  }

-- | Split @--key=value@ into two tokens so the parser only deals with the
-- space-separated form.
preprocess :: [String] -> [String]
preprocess = concatMap split
  where
    split a
      | "--" `isPrefixOf'` a
      , (k, '=' : v) <- break (== '=') a = [k, v]
      | otherwise = [a]
    isPrefixOf' p s = take (length p) s == p

parseOpts :: [String] -> Opts -> Either String Opts
parseOpts [] o = Right o
parseOpts (x : xs) o = case x of
  "--help"            -> parseOpts xs o { oHelp = True }
  "-h"                -> parseOpts xs o { oHelp = True }
  "--version"         -> parseOpts xs o { oVer = True }
  "-V"                -> parseOpts xs o { oVer = True }
  "--graph"           -> need $ \v -> o { oGraph = Just v }
  "--entry"           -> need $ \v -> o { oEntries = oEntries o ++ [v] }
  "-i"                -> need $ \v -> o { oIncl = oIncl o ++ [v] }
  "--include"         -> need $ \v -> o { oIncl = oIncl o ++ [v] }
  "--include-path"    -> need $ \v -> o { oIncl = oIncl o ++ [v] }
  "--project"         -> need $ \v -> o { oProj = Just v }
  "--out-dir"         -> need $ \v -> o { oOut = Just v }
  "-o"                -> need $ \v -> o { oOut = Just v }
  "--agda-deps-bin"   -> need $ \v -> o { oDeps = Just v }
  "--agda-unused-bin" -> need $ \v -> o { oUnused = Just v }
  "--min-term-depth"  -> need $ \v -> o { oMinDepth = readInt v (oMinDepth o) }
  "--no-term-hashes"  -> parseOpts xs o { oHashes = False }
  "--no-signatures"   -> parseOpts xs o { oSigs = False }
  "--normalise-signatures" -> parseOpts xs o { oNormSigs = True }
  "--normalize-signatures" -> parseOpts xs o { oNormSigs = True }
  "--show-implicit"   -> parseOpts xs o { oShowImpl = True }
  "--no-auto-rebuild" -> parseOpts xs o { oAuto = False }
  "--no-watch"        -> parseOpts xs o { oWatch = False }
  "--no-incremental"  -> parseOpts xs o { oIncremental = False }
  "--require-well-typed" -> parseOpts xs o { oRequireWellTyped = True }
  "--strict-producer" -> parseOpts xs o { oStrictProducer = True }
  "--no-query-log"    -> parseOpts xs o { oQueryLog = False }
  "--no-auto-resolve" -> parseOpts xs o { oAutoResolve = False }
  "--enable-interact" -> parseOpts xs o { oEnableInteract = True }
  "--agda-bin"        -> need $ \v -> o { oAgdaBin = Just v }
  "--agda-arg"        -> need $ \v -> o { oInteractArgs = oInteractArgs o ++ [v] }
  "--interaction-heap-mb"      -> need $ \v -> o { oInteractHeapMb = readInt v (oInteractHeapMb o) }
  "--max-interaction-sessions" -> need $ \v -> o { oMaxSessions = readInt v (oMaxSessions o) }
  "--interaction-idle-timeout" -> need $ \v -> o { oSessionIdleSecs = readInt v (oSessionIdleSecs o) }
  "--inspect"         -> parseOpts xs o { oInspect = True }
  "--inspect-port"    -> need $ \v -> o { oInspect = True, oInspectPort = readInt v (oInspectPort o) }
  "--no-auto-hints"      -> parseOpts xs o { oAutoHints = False }
  "--auto-hints-limit"   -> need $ \v -> o { oAutoHintsLimit = readInt v (oAutoHintsLimit o) }
  "--auto-hints-timeout" -> need $ \v -> o { oAutoHintsSecs = readInt v (oAutoHintsSecs o) }
  "--control-port"       -> need $ \v -> o { oControlPort = readInt v (oControlPort o) }
  "--coverage-ignore"    -> need $ \v -> o { oCoverageIgnore = oCoverageIgnore o ++ [v] }
  "--overlay-graph"      -> need $ \v -> o { oOverlayGraphs = oOverlayGraphs o ++ [v] }
  _ | isAgdaFile x    -> parseOpts xs o { oEntries = oEntries o ++ [x] }
    | otherwise       -> Left ("unknown argument: " ++ x)
  where
    need f = case xs of
      (v : rest) -> parseOpts rest (f v)
      []         -> Left (x ++ " requires a value")
    readInt s d = case reads s of [(n, "")] -> n; _ -> d

isAgdaFile :: FilePath -> Bool
isAgdaFile f = any (`isSuffixOf` f)
  [ ".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex", ".lagda.org"
  , ".lagda.tree", ".lagda.typ" ]

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing  y = y

-- 'orderNub' (order-preserving dedup) is shared from "AgdaMcp.Config" so the
-- config-merge and this CLI/env assembly dedup entry/include lists identically.

-- ---------------------------------------------------------------------
-- Project discovery
-- ---------------------------------------------------------------------

preferredEntries :: [String]
preferredEntries =
  ["Main.lagda.md", "Main.agda", "Everything.agda", "Everything.lagda.md",
   "index.agda", "Index.agda", "All.agda"]

-- | Collect Agda source files under a root, bounded in depth, skipping
-- VCS / build dirs.
collectAgda :: Int -> FilePath -> IO [FilePath]
collectAgda depth root
  | depth < 0 = pure []
  | otherwise = do
      isDir <- doesDirectoryExist root
      if not isDir
        then do isF <- doesFileExist root; pure [root | isF && isAgdaFile root]
        else do
          es <- safeList root
          fmap concat $ forM es $ \e ->
            if e `elem` [".git", "dist-newstyle", ".agda-explore", "_build", "node_modules"]
              then pure []
              else collectAgda (depth - 1) (root </> e)
  where
    safeList p = either (const []) id
                   <$> (try (listDirectory p) :: IO (Either SomeException [FilePath]))

-- | Find the most likely entry module under a project root.
discoverEntry :: FilePath -> IO (Maybe FilePath)
discoverEntry proj = do
  files <- collectAgda 6 proj
  let scored = [ (length (filter (== '/') f), f)
               | f <- files, takeFileName f `elem` preferredEntries ]
  case map snd (sortOn fst scored) of
    (f : _) -> Just <$> makeAbsolute f
    []      -> pure Nothing

-- ---------------------------------------------------------------------
-- Build the Config
-- ---------------------------------------------------------------------

buildConfig :: Opts -> IO Config
buildConfig o = do
  envEntry <- lookupEnv "AGDA_EXPLORE_ENTRY"
  envGraph <- lookupEnv "AGDA_EXPLORE_GRAPH"
  envProj  <- lookupEnv "AGDA_EXPLORE_PROJECT"
  envIncl  <- lookupEnv "AGDA_EXPLORE_INCLUDE"
  cwd      <- getCurrentDirectory
  proj     <- makeAbsolute (fromMaybe cwd (oProj o `orElse` envProj))
  -- Decode + origin-tag the overlay graphs once (warns and skips bad ones);
  -- retained on the Config and re-unioned into every snapshot.
  overlays <- loadOverlays =<< mapM makeAbsolute (oOverlayGraphs o)
  let inclRaw  = if not (null (oIncl o)) then oIncl o
                 else maybe [] splitSearchPath envIncl
      -- Entries: the CLI/config list ('oEntries', already appended in
      -- precedence order), order-preserving deduped. AGDA_EXPLORE_ENTRY is a
      -- FALLBACK only — used when no --entry/config entry was given (so a
      -- CLI --entry is never silently unioned with a stray env value), and
      -- is PATH-separator-splittable like AGDA_EXPLORE_INCLUDE. Several
      -- entries union their import closures into one graph (see
      -- "AgdaGraph.Union").
      entriesRaw = orderNub $ if null (oEntries o)
                                then maybe [] splitSearchPath envEntry
                                else oEntries o
      graphRaw = oGraph o `orElse` envGraph
      base bin = defaultConfig
        { cfgProjectRoot  = proj
        , cfgDepsBin      = oDeps o
        , cfgUnusedBin    = oUnused o
        , cfgWithHashes   = oHashes o
        , cfgWithSigs     = oSigs o
        , cfgNormaliseSigs = oNormSigs o
        , cfgShowImplicit = oShowImpl o
        , cfgMinTermDepth = oMinDepth o
        , cfgWatch        = oWatch o
        , cfgIncremental  = oIncremental o
        , cfgRequireWellTyped = oRequireWellTyped o
        , cfgStrictProducer = oStrictProducer o
        , cfgQueryLog     = oQueryLog o
        , cfgAutoResolveUnique = oAutoResolve o
        , cfgEnableInteract = oEnableInteract o
        , cfgAgdaBin      = oAgdaBin o
        , cfgInteractArgs = oInteractArgs o
        , cfgInteractHeapMb = oInteractHeapMb o
        , cfgMaxSessions  = oMaxSessions o
        , cfgSessionIdleSecs = oSessionIdleSecs o
        , cfgInspect      = oInspect o
        , cfgInspectPort  = oInspectPort o
        , cfgAutoHints    = oAutoHints o
        , cfgAutoHintsLimit = oAutoHintsLimit o
        , cfgAutoHintsSecs = oAutoHintsSecs o
        , cfgControlPort  = oControlPort o
        , cfgCoverageIgnore = oCoverageIgnore o
        , cfgOverlays     = overlays
        , cfgIncludes     = bin
        }
      preloaded g incl = do
        gAbs   <- makeAbsolute g
        incl'  <- mapM makeAbsolute (if null incl then [proj] else incl)
        -- Telemetry OFF by default in preloaded mode: cfgOutDir there is the
        -- default ".agda-explore" relative to a cwd that may be unwritable
        -- or unexpected, so we do not write a query-log unless asked.
        pure (base incl') { cfgPreloaded = True, cfgGraphPath = gAbs
                          , cfgAutoRebuild = False, cfgEntries = []
                          , cfgQueryLog = False }
      -- @entries@ are already absolute; @incl@ is the resolved include list.
      live entries incl = do
        out   <- makeAbsolute (fromMaybe (proj </> ".agda-explore") (oOut o))
        incl' <- mapM makeAbsolute incl
        pure (base incl') { cfgPreloaded = False, cfgEntries = entries
                          , cfgOutDir = out, cfgGraphPath = out </> "deps.json"
                          , cfgAutoRebuild = oAuto o }
  case graphRaw of
    Just g  -> preloaded g inclRaw
    Nothing -> do
      -- User-supplied entries win; otherwise fall back to a single
      -- discovered entry (wrapped as a singleton list).
      entries <- case entriesRaw of
        [] -> maybe [] pure <$> discoverEntry proj
        es -> mapM makeAbsolute es
      case entries of
        (_ : _) ->
          -- Default include dirs cover /every/ entry's tree (else
          -- agda-deps can't resolve some closures), order-preserving nub.
          live entries (if null inclRaw
                          then orderNub (map takeDirectory entries)
                          else inclRaw)
        [] -> do
          mg <- firstExisting [ proj </> "deps.json"
                              , proj </> ".agda-explore" </> "deps.json" ]
          case mg of
            Just g  -> preloaded g inclRaw
            Nothing -> live [] (if null inclRaw then [proj] else inclRaw)

modeDesc :: Config -> String
modeDesc c
  | cfgPreloaded c = "preloaded graph " ++ cfgGraphPath c
  | otherwise = case cfgEntries c of
      []  -> "live, no entry discovered — set --entry or AGDA_EXPLORE_ENTRY"
      [e] -> "live, entry " ++ e
      es  -> "live, entries " ++ intercalate ", " es
                ++ " (union of import closures)"

-- ---------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------

versionStr :: String
versionStr = "agda-explore 0.1 — interactive MCP server for agda-deps\n"
          ++ BuildInfo.buildFingerprint

usage :: String
usage = unlines
  [ versionStr
  , ""
  , "An MCP (Model Context Protocol) stdio server exposing point queries over"
  , "an Agda project's dependency graph. Normally launched by the bundled"
  , "Claude Code plugin, not by hand."
  , ""
  , "One-shot query (no daemon), for scripting / non-MCP use:"
  , "  agda-explore query <tool> [key=value ...] [--json] [--graph FILE] [-i DIR]"
  , "    Runs a read tool once and prints its result (add --json for a structured"
  , "    envelope). E.g.:  agda-explore query brief name=Foo.bar --graph deps.json"
  , "                      agda-explore query search query=map --graph deps.json --json | jq"
  , ""
  , "Options (server mode):"
  , "  --entry FILE          Agda entry module to build the graph from"
  , "                        (repeatable; several entries union their import"
  , "                        closures into one graph — see config `entries:`)."
  , "  -i, --include DIR     Agda include directory (repeatable)."
  , "  --graph FILE          Serve a fixed graph.json; disables rebuilds."
  , "  --project DIR         Project root / subprocess cwd (default: cwd)."
  , "  --out-dir DIR         Where the generated graph.json lives"
  , "                        (default: <project>/.agda-explore)."
  , "  --agda-deps-bin P     Path to agda-deps   (else $AGDA_DEPS_BIN, $PATH)."
  , "  --agda-unused-bin P   Path to agda-unused (else $AGDA_UNUSED_BIN, $PATH)."
  , "  --no-term-hashes      Build without AST term hashes (disables similar_bodies)."
  , "  --no-signatures       Build without rendered type signatures (type_of falls"
  , "                        back to a source scrape)."
  , "  --normalise-signatures  Normalise type signatures (semantic form) for type_of."
  , "  --show-implicit       Render type signatures with implicit arguments shown."
  , "  --min-term-depth N    Term-hash depth filter (default 3)."
  , "  --no-auto-rebuild     Do not regenerate the graph when sources change."
  , "  --no-watch            Disable the fsnotify watcher; poll on each query instead."
  , "  --require-well-typed  Only promote a rebuild that fully type-checks; while a"
  , "                        module has a type error, keep serving the last well-typed"
  , "                        graph (holes still refresh). Off by default."
  , "  --strict-producer     Run agda-deps strictly: drop --keep-going for its"
  , "                        --incremental cache (faster rebuilds; needs Agda >= 2.9)."
  , "  --no-query-log        Disable per-query telemetry (else appends one JSON line"
  , "                        per tools/call to <out-dir>/query-log.jsonl; on by default"
  , "                        in live mode, off in preloaded mode)."
  , "  --no-auto-resolve     Do not auto-resolve a name to its sole near-match candidate"
  , "                        (on by default; a one-line note flags any auto-resolution)."
  , "  --enable-interact     Expose the write-side interaction-bridge tools (load,"
  , "                        goal_type, goal_context, infer, normalize, case_split,"
  , "                        refine, give) backed by a live `agda --interaction-json`"
  , "                        session. Needs `agda` on $PATH (or --agda-bin)."
  , "  --agda-bin P          Path to agda for interaction sessions (else $AGDA_BIN, $PATH)."
  , "  --agda-arg ARG        Extra flag for `agda --interaction-json` (repeatable;"
  , "                        e.g. --agda-arg --safe)."
  , "  --inspect             Serve a localhost web inspector (activity feed + live"
  , "                        editing view) at http://127.0.0.1:7000 over Server-Sent"
  , "                        Events. Off by default; localhost-only, no auth."
  , "  --inspect-port N      Inspector start port (implies --inspect; probes upward"
  , "                        from N if busy, so several projects don't clash)."
  , "  --no-auto-hints       Disable the speculative Mimer probe `check` runs over"
  , "                        remaining goals (on by default; solutions it finds are"
  , "                        reported inline)."
  , "  --auto-hints-limit N  Max goals the check-time Mimer probe tries (default 3)."
  , "  --auto-hints-timeout N  Mimer budget per probed goal, seconds (default 1)."
  , "  --control-port N      Serve a localhost control endpoint (GET /check?file=…)"
  , "                        for PostToolUse hooks; probes upward from N, writes the"
  , "                        bound port to <out-dir>/control-port. Needs"
  , "                        --enable-interact. Off by default."
  , "  --coverage-ignore GLOB  Source files (matching GLOB) intentionally outside every"
  , "                        entry's closure; excluded from the coverage warning. Repeatable."
  , "  --overlay-graph FILE  Federate a prebuilt expanded graph.json (e.g. an agda-stdlib"
  , "                        graph) into every snapshot so search/type_of/find_lemma see its"
  , "                        definitions ([external: …]-tagged). Project defs win. Repeatable."
  , "  --config FILE         Load this .agda-explore.yml (else discovered; see below)."
  , "  -h, --help            This help."
  , "  -V, --version         Version."
  , ""
  , "Config: a .agda-explore.yml / .yaml is discovered from --config,"
  , "$AGDA_EXPLORE_CONFIG, ./.agda-explore.yml, or the nearest *.agda-lib ancestor."
  , "Keys are kebab-case mirrors of the flags above (e.g. no-watch, min-term-depth);"
  , "merge order is defaults < config < CLI."
  , ""
  , "Environment fallbacks: AGDA_EXPLORE_ENTRY (PATH-sep, multi-entry),"
  , "AGDA_EXPLORE_INCLUDE (PATH-sep),"
  , "AGDA_EXPLORE_GRAPH, AGDA_EXPLORE_PROJECT, AGDA_EXPLORE_CONFIG, AGDA_DEPS_BIN,"
  , "AGDA_UNUSED_BIN."
  ]

-- | One-shot read query: @agda-explore query \<tool\> [key=value ...] [--json]
-- [server flags]@. Loads the graph once (no daemon) and dispatches through the
-- same tool table the server uses, so the CLI inherits every read tool. Exit 0
-- on any answer (incl. "no results"), nonzero on an operational error.
-- @key=value@ tokens (no leading dash) are tool args; other tokens are
-- server/config flags (@--graph FILE@, @-i DIR@). Read-oriented; the write
-- bridge stays MCP-only.
runQuery :: [String] -> IO ()
runQuery [] = do
  hPutStrLn stderr "usage: agda-explore query <tool> [key=value ...] [--json] [--graph FILE] [-i DIR ...]"
  exitFailure
runQuery (tool : rest) = do
  let isKv a         = not ("-" `isPrefixOf` a) && '=' `elem` a
      (kvs, flags0)  = partition isKv rest
      wantJson       = "--json" `elem` flags0
      flags          = filter (/= "--json") flags0
      (mCfgArg, fl') = extractConfigArg (preprocess flags)
  (seed, _) <- loadSeed mCfgArg
  finalOpts <- case parseOpts fl' seed of
    Left e  -> hPutStrLn stderr ("agda-explore: " ++ e) >> exitFailure
    Right f -> pure f
  cfg <- buildConfig finalOpts
  ss  <- newServerState cfg
  let args = object $ map kvPair kvs
                        ++ [ (Key.fromText "format", toJSON ("json" :: T.Text)) | wantJson ]
  case [ t | t <- enabledTools ss, tName t == T.pack tool ] of
    [] -> do
      hPutStrLn stderr $ "agda-explore: unknown tool `" ++ tool ++ "`. Available: "
                           ++ intercalate ", " [ T.unpack (tName t) | t <- enabledTools ss ]
      exitFailure
    (t : _) -> do
      r <- tRun t ss args
      case r of
        Right txt -> TIO.putStrLn txt >> exitSuccess
        Left  err -> TIO.hPutStrLn stderr err >> exitFailure

-- | Parse one @key=value@ token into an aeson pair, coercing the value to a
-- JSON number/bool when it clearly is one (so @limit=50@ reaches 'argInt' as a
-- @Number@, not a string). Everything else stays a string.
kvPair :: String -> (Key.Key, Value)
kvPair s =
  let (k, v0) = break (== '=') s
  in (Key.fromText (T.pack k), coerceVal (drop 1 v0))

coerceVal :: String -> Value
coerceVal "true"  = Bool True
coerceVal "false" = Bool False
coerceVal s
  | [(n, "")] <- (reads s :: [(Int, String)])    = toJSON n
  | [(d, "")] <- (reads s :: [(Double, String)]) = toJSON d
  | otherwise                                     = toJSON (T.pack s)

main :: IO ()
main = do
  argv <- getArgs
  case argv of
    ("query" : rest) -> runQuery rest
    _                -> mainServer argv

-- | The default mode: the long-lived MCP stdio server.
mainServer :: [String] -> IO ()
mainServer argv = do
  -- Lift --config out before the hand-rolled parser sees it (after the
  -- --key=value splitter, so only the space-separated form reaches here).
  let (mCfgArg, argv') = extractConfigArg (preprocess argv)
  case parseOpts argv' defOpts of
    Left err -> hPutStrLn stderr ("agda-explore: " ++ err) >> exitFailure
    Right o
      | oHelp o   -> putStr usage
      | oVer o    -> do
          bin <- binaryIdent
          putStrLn (versionStr ++ "\nbinary: " ++ bin)
      | otherwise -> do
          -- defaults < config < CLI: overlay the YAML onto the default
          -- 'Opts', then re-run the CLI parser on top of that seed.
          (seed, mApplied) <- loadSeed mCfgArg
          finalOpts <- case parseOpts argv' seed of
            Left e  -> hPutStrLn stderr ("agda-explore: " ++ e) >> exitFailure
            Right f -> pure f
          maybe (pure ()) (\p -> hPutStrLn stderr ("agda-explore: applied config from " ++ p)) mApplied
          cfg <- buildConfig finalOpts
          ss  <- newServerState cfg
          startWatcher ss
          -- Warm cold-start: reuse the previous run's on-disk per-entry
          -- graphs so the first query is served instantly and only the
          -- entries a source changed under re-run (after the watcher, so the
          -- incremental path is live).
          warmStart ss
          startInspect ss cfg
          mPortFile <- startControlEndpoint ss cfg
          -- Idle-session reaper: only when interaction is on and a timeout is
          -- configured (interaction-idle-timeout > 0); otherwise no thread.
          when (cfgEnableInteract cfg && cfgSessionIdleSecs cfg > 0) $
            void (forkIO (reapIdleSessions ss))
          hPutStrLn stderr ("agda-explore: ready (" ++ modeDesc cfg ++ ")")
          -- Reap any live interaction sessions when the stdio loop ends
          -- (stdin EOF) or throws, so child agda processes aren't orphaned;
          -- also drop the control-port discovery file so hooks stop probing
          -- a dead endpoint.
          runStdioLoop (dispatch ss)
            `finally` (closeAllSessions ss >> mapM_ removeQuiet mPortFile)

-- | Start the localhost web inspector when @--inspect@ is on. Binds the
-- listening socket (probing upward from 'cfgInspectPort' so several daemons
-- coexist) and reports the actual URL on stderr. A no-op otherwise; a bind
-- failure is logged but never fatal — the daemon serves stdio regardless.
startInspect :: ServerState -> Config -> IO ()
startInspect ss cfg = case ssInspect ss of
  Nothing  -> pure ()
  Just hub -> do
    mport <- startInspector hub (cfgInspectPort cfg) (cfgProjectRoot cfg)
    case mport of
      Just p  -> hPutStrLn stderr
        ("agda-explore: inspector at http://127.0.0.1:" ++ show p
           ++ (if p /= cfgInspectPort cfg
                 then " (port " ++ show (cfgInspectPort cfg) ++ " busy)"
                 else ""))
      Nothing -> hPutStrLn stderr
        ("agda-explore: inspector could not bind a port near "
           ++ show (cfgInspectPort cfg) ++ "; continuing without it.")

-- | Start the localhost control endpoint when @--control-port@ is set (and
-- the interaction bridge is on — @/check@ runs through it). Returns the
-- port-file path for shutdown cleanup. The callback dispatches to the same
-- @check@ runner the MCP tool uses, so an external hook and the agent see
-- byte-identical verdicts. A bind failure is logged but never fatal.
startControlEndpoint :: ServerState -> Config -> IO (Maybe FilePath)
startControlEndpoint ss cfg
  | cfgControlPort cfg <= 0 = pure Nothing
  | not (cfgEnableInteract cfg) = do
      hPutStrLn stderr "agda-explore: --control-port needs --enable-interact (its /check runs the bridge); not starting it."
      pure Nothing
  | otherwise = do
      let outAbs   = let od = cfgOutDir cfg
                     in if isAbsolute od then od else cfgProjectRoot cfg </> od
          portFile = outAbs </> "control-port"
          toolCb nm f = case [ t | t <- interactTools, tName t == nm ] of
            (t : _) -> tRun t ss (object ["file" .= f])
            []      -> pure (Left (nm <> " tool unavailable"))
          -- /repair passes no `write`, so it proposes a fix, never applies it.
          routes = [ ("/check?", toolCb "check"), ("/repair?", toolCb "repair") ]
      mport <- startControl (cfgControlPort cfg) portFile routes
      case mport of
        Just p  -> do
          hPutStrLn stderr ("agda-explore: control endpoint at http://127.0.0.1:"
                              ++ show p ++ " (port file " ++ portFile ++ ")")
          pure (Just portFile)
        Nothing -> do
          hPutStrLn stderr ("agda-explore: control endpoint could not bind a port near "
                              ++ show (cfgControlPort cfg) ++ "; continuing without it.")
          pure Nothing

-- | Best-effort file removal (shutdown path; never throws).
removeQuiet :: FilePath -> IO ()
removeQuiet p = void (try (removePathForcibly p) :: IO (Either SomeException ()))

-- | Discover + load a config file and overlay it onto 'defOpts',
-- returning the seed 'Opts' and the applied path (for the breadcrumb).
loadSeed :: Maybe FilePath -> IO (Opts, Maybe FilePath)
loadSeed mCfgArg = do
  mPath <- discoverConfigPath mCfgArg
  case mPath of
    Nothing -> pure (defOpts, Nothing)
    Just p  -> do
      fc <- loadConfig p
      pure (applyConfig fc defOpts, Just p)
