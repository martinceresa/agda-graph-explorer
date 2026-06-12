{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Server configuration, the loaded-graph state, and the live
-- regeneration machinery for the @agda-explore@ MCP daemon.
--
-- The daemon holds one 'Loaded' snapshot (the parsed 'ExpandedGraph'
-- plus its in-memory 'Index') behind an 'IORef'. 'ensureFresh' stats the
-- project's Agda sources before answering a query and, if anything
-- changed since the snapshot was built, spawns @agda-deps@ as a
-- /subprocess/ to re-emit @graph.json@ and hot-swaps the snapshot.
--
-- A fresh subprocess per rebuild keeps Agda's @TCM@/@IORef@
-- type-checking state clean while still reusing its on-disk @.agdai@
-- interface cache, so re-runs only re-elaborate the modules that
-- actually changed.
module AgdaMcp.State
  ( -- * Config
    Config(..)
  , defaultConfig
    -- * Loaded snapshot
  , Loaded(..)
  , ScanSig(..)
  , currentNodeKeyVersion
    -- * Server
  , ServerState(..)
  , newServerState
    -- * Live regeneration
  , ensureFresh
  , forceRebuild
    -- * Query telemetry
  , appendQueryLog
    -- * Background file-watch
  , startWatcher
  , ensureWorker
  , isWatching
    -- * Binary discovery
  , findBin
  , binaryIdent
  , stalenessBanner
  ) where

import           Control.Concurrent       (forkIO, threadDelay)
import           Control.Concurrent.MVar  (MVar, newEmptyMVar, newMVar,
                                           takeMVar, tryPutMVar, tryTakeMVar,
                                           withMVar)
import           Control.DeepSeq      (force)
import           Control.Exception    (SomeException, evaluate, try)
import           Control.Monad        (filterM, forM, forever, void)
import           Data.Aeson           (Value, eitherDecode, encode)
import qualified Data.ByteString.Lazy as BL
import           Data.IORef
import qualified Data.IntMap.Strict   as IM
import           Data.List            (isInfixOf, isSuffixOf, maximumBy)
import qualified Data.Map.Strict      as M
import           Data.Maybe           (catMaybes, isJust, mapMaybe)
import           Data.Ord             (comparing)
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Data.Time.Clock      (UTCTime, getCurrentTime)
import qualified Data.Vector          as V
import           System.Directory     (createDirectoryIfMissing,
                                       doesDirectoryExist, doesFileExist,
                                       findExecutable, getModificationTime,
                                       listDirectory)
import           System.Environment   (getExecutablePath, lookupEnv)
import           System.Exit          (ExitCode (..))
import           System.FilePath      ((</>))
import           System.FSNotify      (Event, WatchManager, eventPath,
                                       startManager, watchTree)
import           System.IO            (hPutStrLn, stderr)
import           System.Process       (CreateProcess (..), proc,
                                       readCreateProcessWithExitCode)

import           AgdaGraph.Index      (Index, buildIndex, idxDefs, idxRealCount)
import           AgdaGraph.Schema     (Definition (..), ExpandedGraph (..))
import           AgdaGraph.Union      (unionExpandedGraphs)
import           AgdaGraph.Similarity (SigBodyFingerprints,
                                       buildSigBodyFingerprints,
                                       silhouetteDefaultWlK, subtermMultisetsVec)
import           AgdaGraph.WL         (Fingerprint)

-- | How the daemon (re)builds and reads the graph.
data Config = Config
  { cfgEntries      :: ![FilePath]
    -- ^ Agda entry modules for rebuilds (absolute paths). @[]@ = no entry
    -- configured (preloaded mode, or the daemon couldn't discover one).
    -- With more than one entry the daemon runs @agda-deps@ once per entry
    -- and unions the parsed graphs in-process (see 'runBuild' +
    -- 'AgdaGraph.Union.unionExpandedGraphs'); a single entry takes the
    -- one-subprocess path and is byte-identical to the historical
    -- single-@cfgEntry@ behaviour.
  , cfgIncludes     :: ![FilePath]       -- ^ @-i@ include dirs (and scan roots).
  , cfgProjectRoot  :: !FilePath         -- ^ cwd for the @agda-deps@ subprocess.
  , cfgOutDir       :: !FilePath         -- ^ where the generated @deps.json@ lives.
  , cfgGraphPath    :: !FilePath         -- ^ the graph file to read.
  , cfgPreloaded    :: !Bool             -- ^ True: user supplied a fixed graph; never rebuild.
  , cfgDepsBin      :: !(Maybe FilePath) -- ^ explicit @agda-deps@ path.
  , cfgUnusedBin    :: !(Maybe FilePath) -- ^ explicit @agda-unused@ path.
  , cfgWithHashes   :: !Bool             -- ^ pass @--with-term-hashes@ on rebuild.
  , cfgWithSigs     :: !Bool             -- ^ pass @--with-signatures@ on rebuild.
  , cfgNormaliseSigs :: !Bool            -- ^ pass @--normalise-signatures@ on rebuild.
  , cfgShowImplicit :: !Bool             -- ^ pass @--signature-implicits@ on rebuild.
  , cfgMinTermDepth :: !Int              -- ^ @--min-term-depth@ on rebuild.
  , cfgAutoRebuild  :: !Bool             -- ^ auto-rebuild on detected staleness.
  , cfgWatch        :: !Bool             -- ^ use an fsnotify watcher (live mode) instead of per-query polling.
  , cfgQueryLog     :: !Bool             -- ^ append one JSON line per @tools/call@ to @cfgOutDir/query-log.jsonl@.
  , cfgAutoResolveUnique :: !Bool        -- ^ auto-resolve a name to the sole "did you mean" candidate (tier 3 of 'AgdaMcp.Query.resolveDefNote').
  }

defaultConfig :: Config
defaultConfig = Config
  { cfgEntries      = []
  , cfgIncludes     = []
  , cfgProjectRoot  = "."
  , cfgOutDir       = ".agda-explore"
  , cfgGraphPath    = ".agda-explore" </> "deps.json"
  , cfgPreloaded    = False
  , cfgDepsBin      = Nothing
  , cfgUnusedBin    = Nothing
  , cfgWithHashes   = True
  , cfgWithSigs     = True
  , cfgNormaliseSigs = False
  , cfgShowImplicit = False
  , cfgMinTermDepth = 3
  , cfgAutoRebuild  = True
  , cfgWatch        = True
  , cfgQueryLog     = True
  , cfgAutoResolveUnique = True
  }

-- | A cheap fingerprint of the source tree: file count + newest mtime.
-- A change in either triggers a rebuild under 'ensureFresh'.
data ScanSig = ScanSig !Int !(Maybe UTCTime)
  deriving (Eq)

-- | The node-key convention this binary expects. A loaded graph below
-- this is stale-format and (in live mode) triggers a rebuild rather than
-- serving results keyed by an older convention. Keep in sync with
-- 'AgdaDeps.Deps.nodeKeyVersion'.
currentNodeKeyVersion :: Int
currentNodeKeyVersion = 2

-- | One immutable graph snapshot held by the daemon.
data Loaded = Loaded
  { ldGraph     :: !ExpandedGraph
  , ldIndex     :: !Index
  , ldModFiles  :: !(M.Map Text FilePath) -- ^ module name -> source file.
  , ldBuiltAt   :: !UTCTime
  , ldScanSig   :: !ScanSig
  , ldFailed    :: ![Text]                -- ^ modules that failed to type-check.
  , ldProducer  :: !(Maybe Text)          -- ^ build fingerprint that emitted this graph.
  , ldNodeKeyV  :: !Int                   -- ^ node-key format version of this graph.
  , ldRealDefs  :: ![Definition]
    -- ^ The real (non-synthetic) defs as a list, materialised once at
    -- snapshot construction. The point queries rescan this many times per
    -- request; the snapshot is immutable, so it is built once here instead.
  , ldOwnerMap  :: !(IM.IntMap Definition)
    -- ^ Precomputed enclosing-owner lookup for @where@-/anonymous-module
    -- locals: a local def's id ('defId') to its owning top-level def (see
    -- 'AgdaMcp.Query.ownerOf'). Built once so the per-result-line owner
    -- annotation is O(log n) instead of a full linear scan of all defs.
    -- Absent key ⇒ no owner (the def is non-local, has no line, or has no
    -- enclosing top-level def above it).
    -- Lazy similarity caches (forced on the first @similar_*@ query, then
    -- reused for the life of the snapshot). Deliberately non-strict so a
    -- plain rebuild doesn't pay the WL / subterm-multiset cost up front.
  , ldSigBodyFp :: SigBodyFingerprints
    -- ^ per-node WL signature/body fingerprints — the @silhouette@ core,
    -- reused by @similar_types@ so the two agree by construction.
  , ldSubtermFp :: Maybe (V.Vector Fingerprint)
    -- ^ per-real-def occurrence-weighted subterm multiset — the
    -- @term-cluster@ core, reused by @similar_bodies@. 'Nothing' when the
    -- graph carries no term hashes.
  , ldAutoResolveUnique :: !Bool
    -- ^ Whether the pure query layer's name resolver auto-resolves a name
    -- to the sole "did you mean" candidate (tier 3 of
    -- 'AgdaMcp.Query.resolveDefNote'). Carried on the snapshot — rather
    -- than read from 'Config' — so "AgdaMcp.Query" needs no 'Config'
    -- import. Set in 'loadLoaded' from 'cfgAutoResolveUnique'.
  }

-- | Is this snapshot's node-key format current? When 'False' in live
-- mode, 'ensureFresh' rebuilds rather than serving stale-keyed results.
loadedFormatCurrent :: Loaded -> Bool
loadedFormatCurrent ld = ldNodeKeyV ld >= currentNodeKeyVersion

data ServerState = ServerState
  { ssConfig      :: !Config
  , ssLoaded      :: !(IORef (Maybe Loaded))
  , ssStartedAt   :: !UTCTime               -- ^ when this daemon process started.
  , ssDirty       :: !(IORef Bool)          -- ^ set by the watcher (or a serve-stale query); a rebuild is pending.
  , ssRebuildLock :: !(MVar ())             -- ^ serialises rebuilds (watch worker vs. query).
  , ssWake        :: !(MVar ())             -- ^ coalescing watcher/query→worker wakeup.
  , ssWatcher     :: !(IORef (Maybe WatchManager))
    -- ^ the live fsnotify manager (also keeps it from being collected);
    -- 'Nothing' when watching is disabled or failed to start (poll fallback).
  , ssWorkerUp    :: !(MVar ())
    -- ^ start-at-most-once gate for the background rebuild worker
    -- ('watchWorker'). Starts /full/ (holds the single permit); the first
    -- caller that manages 'tryTakeMVar' wins the right to fork the worker.
    -- Both the fsnotify path ('startWatcher') and the polled serve-stale
    -- fallback ('ensureWorker') go through this, so exactly one worker ever
    -- drains 'ssWake' — otherwise two workers could double-build.
  , ssLastRebuilt :: !(IORef Bool)
    -- ^ Telemetry (E6): whether the /most recent/ tool runner served a
    -- stale snapshot — i.e. a rebuild was pending/in-flight (the @stale@
    -- column), NOT "this query itself ran a rebuild". The tool runners
    -- write it via the E1 @(Loaded, Bool)@ plumbing;
    -- 'AgdaMcp.Tools.handleCall' reads and
    -- resets it after each @tools/call@. (status sets it 'False'; the
    -- @rebuild@ tool sets it 'True'.)
  , ssLogLock     :: !(MVar ())
    -- ^ Serialises 'appendQueryLog' appends to @query-log.jsonl@. A
    -- /dedicated/ lock — never 'ssRebuildLock' — so a telemetry append can
    -- never block behind a (minutes-long) @agda-deps@ rebuild, and two
    -- threads (a query and the watcher worker) cannot interleave a line.
  }

newServerState :: Config -> IO ServerState
newServerState c =
  ServerState c
    <$> newIORef Nothing
    <*> getCurrentTime
    <*> newIORef False
    <*> newMVar ()
    <*> newEmptyMVar
    <*> newIORef Nothing
    <*> newMVar ()
    <*> newIORef False
    <*> newMVar ()

-- ---------------------------------------------------------------------
-- Source scanning
-- ---------------------------------------------------------------------

agdaExt :: FilePath -> Bool
agdaExt f = any (`isSuffixOf` f)
  [".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex", ".lagda.org"]

-- | All Agda source files reachable from the given roots (files or dirs).
listAgdaFiles :: [FilePath] -> IO [FilePath]
listAgdaFiles roots = fmap concat (mapM walk roots)
  where
    walk p = do
      isDir <- doesDirectoryExist p
      if isDir
        then do
          es <- listDirectory p `orEmpty` []
          fmap concat $ forM es $ \e ->
            if e == ".git" || e == "dist-newstyle" || e == ".agda-explore"
              then pure []
              else walk (p </> e)
        else do
          isF <- doesFileExist p
          pure [p | isF && agdaExt p]
    orEmpty act fb = (act >>= evaluate) `catchA` const (pure fb)

catchA :: IO a -> (SomeException -> IO a) -> IO a
catchA act h = either h pure =<< try act

-- | @getModificationTime@ with any IO exception (missing file, perms)
-- collapsed to 'Nothing'. The single place we stat a path's mtime.
safeMtime :: FilePath -> IO (Maybe UTCTime)
safeMtime p = either (const Nothing) Just
                <$> (try (getModificationTime p) :: IO (Either SomeException UTCTime))

scanSources :: [FilePath] -> IO ScanSig
scanSources roots = do
  fs <- listAgdaFiles roots
  ts <- catMaybes <$> mapM safeMtime fs
  pure $! ScanSig (length fs) (if null ts then Nothing else Just (maximum ts))

-- ---------------------------------------------------------------------
-- Binary discovery: explicit -> env var -> $PATH -> dist-newstyle sibling
-- ---------------------------------------------------------------------

-- | Locate a sibling binary by base name. Gathers every candidate — an
-- explicit path, an environment variable, @$PATH@, and the sibling
-- under the same @dist-newstyle@ tree as the running server — and
-- returns the one with the /newest/ mtime (ties favour a user-pinned
-- path).
--
-- Newest-wins matters because after a GHC bump the canonical
-- @dist-newstyle@ artifact moves, but a pinned @AGDA_*_BIN@ keeps
-- resolving the old tree; strict precedence would then serve a stale
-- binary forever. Preferring the newest build heals that automatically; a
-- one-line stderr note fires when a stale pin is overridden, so the
-- misconfiguration is still visible.
--
-- Cross-repo note: @agda-deps@ now lives in a separate repository
-- (the Agda backend; this explorer is build-Agda-free), so the
-- @dist-newstyle@ sibling fallback only finds it when the two happen to
-- share a build tree. The documented, reliable resolution path for
-- @agda-deps@ is therefore @--agda-deps-bin@ \> @AGDA_DEPS_BIN@ \>
-- @$PATH@; the sibling probe stays as a best-effort convenience.
findBin :: String -> Maybe FilePath -> String -> IO (Maybe FilePath)
findBin name explicit envName = do
  envP <- lookupEnv envName
  onP  <- findExecutable name
  sib  <- siblingPath name
  let pinned     = catMaybes [explicit, envP]   -- user-specified
      discovered = catMaybes [onP, sib]         -- $PATH / dist-newstyle sibling
      tagged     = [ (p, True)  | p <- pinned ]
                ++ [ (p, False) | p <- discovered ]
  existing  <- filterM (doesFileExist . fst) tagged
  withMtime <- catMaybes <$> mapM stat existing
  case withMtime of
    [] -> pure Nothing
    xs -> do
      let keyOf (_, t, pin) = (t, pin)   -- newest first; pinned breaks ties
          (bestPath, _, bestPinned) = maximumBy (comparing keyOf) xs
      if not bestPinned && not (null pinned)
        then hPutStrLn stderr
               ("agda-explore: pinned " ++ name ++ " (" ++ envName
                  ++ "/--*-bin) is older than a discovered build; using newer "
                  ++ bestPath ++ " — repoint or unset the pin to silence.")
        else pure ()
      pure (Just bestPath)
  where
    stat (p, pin) = fmap (\t -> (p, t, pin)) <$> safeMtime p

-- | The expected path of @name@ under the same dist-newstyle @\/x\/@ build
-- tree as the running server, when derivable. Shared by 'findBin'
-- (companion-bin discovery) and 'newestExploreBuild' (self staleness): for
-- the running @agda-explore@ this reconstructs its own clean path, which
-- is also how a @"(deleted)"@ marker on a replaced binary gets dropped.
siblingPath :: String -> IO (Maybe FilePath)
siblingPath name = do
  self <- getExecutablePath
  -- .../dist-newstyle/build/<plat>/<ghc>/<pkg>/x/<exe>/build/<exe>/<exe>
  let (pre, _) = T.breakOnEnd "/x/" (T.pack self)
  pure $ if T.null pre
           then Nothing
           else Just (T.unpack pre ++ name ++ "/build/" ++ name ++ "/" ++ name)

-- | The running binary's path and on-disk mtime — an OS-truthful,
-- /monotonic/ build discriminator. Unlike the compile-time
-- 'BuildInfo.buildFingerprint' (whose @built …@ date freezes when only
-- /other/ modules are recompiled), the executable's mtime advances on
-- every relink, including uncommitted rebuilds of the same commit — the
-- dominant dev loop. @"(deleted)"@-style paths (a binary replaced under a
-- running daemon) simply report no mtime.
binaryIdent :: IO String
binaryIdent = do
  self <- getExecutablePath
  mt   <- safeMtime self
  pure $ self ++ maybe "" (\t -> " (mtime " ++ show t ++ ")") mt

-- | The newest @agda-explore@ build discoverable on disk (path + mtime).
-- Candidates: the running executable itself ('getExecutablePath'), its
-- dist-newstyle 'siblingPath' (the reconstructed clean path — the one that
-- still resolves when the running file was replaced in place), an
-- @AGDA_EXPLORE_BIN@ pin, and @$PATH@. A path that can't be stat'd (e.g. a
-- @"(deleted)"@ running exe) is dropped — its sibling or @$PATH@ entry
-- covers it. 'Nothing' if none can be stat'd.
newestExploreBuild :: IO (Maybe (FilePath, UTCTime))
newestExploreBuild = do
  self <- getExecutablePath
  sib  <- siblingPath "agda-explore"
  envP <- lookupEnv "AGDA_EXPLORE_BIN"
  onP  <- findExecutable "agda-explore"
  stats <- catMaybes <$> mapM withMtime (self : catMaybes [sib, envP, onP])
  pure $ if null stats then Nothing else Just (maximumBy (comparing snd) stats)
  where
    withMtime p = fmap (\t -> (p, t)) <$> safeMtime p

-- | A warning line when a newer @agda-explore@ build sits on disk than
-- the one this daemon is running. A live daemon cannot hot-swap its own
-- executable, so this nudges a @\/mcp@ reconnect. Empty
-- when the running process is the newest build. The reference is the
-- daemon's /start time/, not the running file's mtime, so an in-place
-- rebuild (which bumps the on-disk mtime under the live process) is still
-- caught.
stalenessBanner :: ServerState -> IO Text
stalenessBanner ss = do
  mNewest <- newestExploreBuild
  pure $ case mNewest of
    Just (p, mt) | mt > ssStartedAt ss ->
      "⚠ a newer agda-explore build exists on disk (mtime " <> T.pack (show mt)
        <> ") — reconnect (/mcp) to use it:\n  " <> T.pack p <> "\n\n"
    _ -> ""

-- ---------------------------------------------------------------------
-- Load / build
-- ---------------------------------------------------------------------

loadLoaded :: Bool -> [FilePath] -> FilePath -> IO (Either String Loaded)
loadLoaded autoResolveUnique includes graphFile = do
  e <- try (BL.readFile graphFile) :: IO (Either SomeException BL.ByteString)
  case e of
    Left err -> pure (Left ("cannot read " ++ graphFile ++ ": " ++ show err))
    Right bs -> case eitherDecode bs of
      Left perr -> pure (Left ("cannot parse " ++ graphFile ++ ": " ++ perr))
      Right (eg :: ExpandedGraph) ->
        Right <$> loadedFromGraph autoResolveUnique includes (Just graphFile) eg

-- | Decode an expanded @graph.json@ from disk, returning the parsed
-- 'ExpandedGraph' (or a clean diagnostic). Shared by the single-entry
-- ('loadLoaded') and the multi-entry-union ('runBuild') paths — the latter
-- decodes one graph per entry before unioning them in-process.
decodeGraphFile :: FilePath -> IO (Either String ExpandedGraph)
decodeGraphFile graphFile = do
  e <- try (BL.readFile graphFile) :: IO (Either SomeException BL.ByteString)
  pure $ case e of
    Left err -> Left ("cannot read " ++ graphFile ++ ": " ++ show err)
    Right bs -> case eitherDecode bs of
      Left perr            -> Left ("cannot parse " ++ graphFile ++ ": " ++ perr)
      Right (eg :: ExpandedGraph) -> Right eg

-- | Build a 'Loaded' snapshot from an already-parsed 'ExpandedGraph'. The
-- @mGraphFile@ is purely cosmetic — it names the source in the stale-format
-- warning; 'Nothing' for an in-memory union (no single backing file). All
-- the index-construction / forcing / similarity-cache wiring that used to
-- live inline in 'loadLoaded' is here so the disk path and the union path
-- produce identical snapshots.
loadedFromGraph :: Bool -> [FilePath] -> Maybe FilePath -> ExpandedGraph -> IO Loaded
loadedFromGraph autoResolveUnique includes mGraphFile eg = do
  let !ix = buildIndex eg
  _   <- evaluate (force ix)
  -- Materialise the real-def list and the owner lookup once. Both
  -- are forced (the queries rescan them per request and the snapshot
  -- never changes); the similarity caches below stay lazy by design.
  let !rds      = V.toList (V.take (idxRealCount ix) (idxDefs ix))
      !ownerMap = buildOwnerMap rds
  _   <- evaluate (force (length rds))
  _   <- evaluate (force (IM.size ownerMap))
  now <- getCurrentTime
  sig <- scanSources includes
  let nkv = egNodeKeyVersion eg
  if nkv < currentNodeKeyVersion
    then hPutStrLn stderr
           ("agda-explore: " ++ maybe "graph" id mGraphFile
              ++ " uses node-key format v"
              ++ show nkv ++ " < v" ++ show currentNodeKeyVersion
              ++ " (stale) — queries may key nodes by an older "
              ++ "convention; rebuild to refresh.")
    else pure ()
  pure Loaded
    { ldGraph    = eg
    , ldIndex    = ix
    , ldModFiles = egModuleFiles eg
    , ldBuiltAt  = now
    , ldScanSig  = sig
    , ldFailed   = egFailedModules eg
    , ldProducer = egProducer eg
    , ldNodeKeyV = nkv
    , ldRealDefs = rds
    , ldOwnerMap = ownerMap
    , ldSigBodyFp = buildSigBodyFingerprints silhouetteDefaultWlK ix
    , ldSubtermFp = subtermMultisetsVec ix
    , ldAutoResolveUnique = autoResolveUnique
    }

-- | Precompute the @where@-/anonymous-module owner lookup consumed by
-- 'AgdaMcp.Query.ownerOf'. For every /local/ def with a known line, find
-- its enclosing top-level def — the nearest non-local def at or above the
-- helper's start line, in the helper's own module or an enclosing one —
-- and key it by the local def's 'defId'. A local def with no such owner
-- (or no line) is simply absent from the map, matching the old 'Nothing'.
--
-- Equivalent, by construction, to the per-call scan + @maximumBy (comparing
-- defLine)@ the query used to run for each rendered result line; folded
-- once here so a query touching N lines is O(N log n) rather than
-- O(N · nDefs). The non-local candidates are pulled out once and shared
-- across all locals.
buildOwnerMap :: [Definition] -> IM.IntMap Definition
buildOwnerMap rds =
  IM.fromList (mapMaybe owner locals)
  where
    locals     = filter isLocalName' rds
    nonLocals  = filter (not . isLocalName') rds
    owner d = do
      ln <- defLine d
      case [ o | o <- nonLocals
               , enclosingModule (defModule o) (defModule d)
               , maybe False (<= ln) (defLine o) ] of
        [] -> Nothing
        os -> Just (defId d, maximumBy (comparing defLine) os)
    -- A where-block / anonymous-module local carries the @._.@ marker
    -- Agda inserts for such scopes (mirrors 'AgdaMcp.Query.isLocalName').
    isLocalName' d = "._." `T.isInfixOf` defName d
    -- @outer@ is @inner@ or a (segment-aligned) module prefix of it
    -- (mirrors the @enclosingModule@ in 'AgdaMcp.Query.ownerOf').
    enclosingModule outer inner =
      outer == inner || (outer <> ".") `T.isPrefixOf` inner

-- | Run @agda-deps@ to regenerate the graph, then parse and index it.
--
-- Three paths:
--
--   * /preloaded/ — read the fixed graph from disk (never spawns
--     @agda-deps@).
--   * /single entry/ — one @agda-deps@ subprocess into 'cfgOutDir', then
--     decode + index 'cfgGraphPath'. Byte-identical to the historical
--     single-@cfgEntry@ behaviour (one trailing positional, the committed
--     fixtures + docs assume this).
--   * /multiple entries/ — a single @agda-deps@ invocation only compiles
--     /one/ entry's import closure, so we run it once per entry into a
--     separate out-dir, decode each 'ExpandedGraph', and union them
--     in-process ('AgdaGraph.Union.unionExpandedGraphs') before building a
--     single 'Index' over the result.
runBuild :: Config -> IO (Either String Loaded)
runBuild Config{..}
  | cfgPreloaded = loadLoaded cfgAutoResolveUnique cfgIncludes cfgGraphPath
  | null cfgEntries =
      pure (Left "no entry module configured; start the server with --entry FILE (repeatable), \
                 \config `entries:`, or --graph FILE")
  | otherwise = do
      mdeps <- findBin "agda-deps" cfgDepsBin "AGDA_DEPS_BIN"
      case mdeps of
        Nothing   -> pure (Left "could not locate the agda-deps binary (set AGDA_DEPS_BIN or pass --agda-deps-bin)")
        Just deps -> case cfgEntries of
          [entry] -> singleEntry deps entry
          _       -> multiEntry deps cfgEntries
  where
    showEc ExitSuccess     = "exit 0"
    showEc (ExitFailure n) = "exit " ++ show n

    -- The shared producer flag list (everything except the out-dir + the
    -- trailing entry positional). Identical to the historical args, so the
    -- single-entry invocation below is byte-for-byte the old command.
    baseArgs =
      [ "--format=json", "--json-mode=expanded"
      , "--no-externals", "--keep-going" ]
        ++ [ a | cfgWithHashes
               , a <- ["--with-term-hashes"
                      , "--min-term-depth=" ++ show cfgMinTermDepth] ]
        ++ ["--with-signatures" | cfgWithSigs]
        ++ ["--normalise-signatures" | cfgWithSigs && cfgNormaliseSigs]
        ++ ["--signature-implicits"  | cfgWithSigs && cfgShowImplicit]
        ++ concatMap (\d -> ["-i", d]) cfgIncludes

    -- One agda-deps run into @outDir@ for @entry@; returns the graph file
    -- path on success (so the caller decodes it where it wants).
    runOne :: FilePath -> FilePath -> FilePath -> IO (Either String FilePath)
    runOne deps outDir entry = do
      createDirectoryIfMissing True outDir
      let args      = baseArgs ++ ["-o", outDir, entry]
          graphPath = outDir </> "deps.json"
      (ec, _out, err) <-
        readCreateProcessWithExitCode
          (proc deps args) { cwd = Just cfgProjectRoot } ""
      exists <- doesFileExist graphPath
      pure $ if not exists
        then Left ("agda-deps produced no graph for " ++ entry ++ " ("
                     ++ showEc ec ++ "):\n" ++ lastLines 25 err)
        else Right graphPath

    -- Single entry: 'runOne' into 'cfgOutDir' IS the historical one-subprocess
    -- command (identical 'baseArgs ++ ["-o", cfgOutDir, entry]') and writes
    -- exactly 'cfgGraphPath' (== cfgOutDir </> "deps.json"), so we read back
    -- the path it returns via 'loadLoaded'. Sharing 'runOne' keeps the single-
    -- and multi-entry build commands from drifting on a future 'baseArgs' change.
    singleEntry :: FilePath -> FilePath -> IO (Either String Loaded)
    singleEntry deps entry =
      runOne deps cfgOutDir entry
        >>= either (pure . Left) (loadLoaded cfgAutoResolveUnique cfgIncludes)

    -- Multiple entries: one agda-deps run per entry into a per-entry
    -- sub-dir of 'cfgOutDir', decode each graph, then union in-process and
    -- index the result. Entry order is preserved (deterministic union /
    -- representative entryModule). A single entry that fails aborts the
    -- whole build with that entry's diagnostic (matches the single-entry
    -- "produced no graph" semantics).
    multiEntry :: FilePath -> [FilePath] -> IO (Either String Loaded)
    multiEntry deps entries = do
      egsE <- forM (zip [0 :: Int ..] entries) $ \(i, entry) -> do
        let outDir = cfgOutDir </> ("entry-" ++ show i)
        r <- runOne deps outDir entry
        case r of
          Left err  -> pure (Left err)
          Right gp  -> decodeGraphFile gp
      case sequence egsE of
        Left err  -> pure (Left err)
        Right egs -> do
          let !eg = unionExpandedGraphs egs
          -- Materialise the unioned graph at 'cfgGraphPath' so out-of-process
          -- consumers that read it directly see the SAME graph the in-memory
          -- Index is built from. In particular the @unused@ tool shells out
          -- to @agda-unused --json=cfgGraphPath@; without this it would read
          -- a missing file (first run) or a stale single-entry leftover and
          -- silently disagree with every in-process query.
          BL.writeFile cfgGraphPath (encode eg)
          Right <$> loadedFromGraph cfgAutoResolveUnique cfgIncludes Nothing eg

lastLines :: Int -> String -> String
lastLines n = unlines . reverse . take n . reverse . lines

-- ---------------------------------------------------------------------
-- Live regeneration entry points
-- ---------------------------------------------------------------------

-- | Return the current snapshot for a query, /serving stale/: when a
-- snapshot already exists and a rebuild is warranted, the existing
-- snapshot is returned /immediately/ tagged stale and the rebuild is
-- scheduled in the background — the daemon never blocks a query (or the
-- stdio loop behind it) on the ~minutes-long @agda-deps@ subprocess. The
-- one exception is the genuine first build (no snapshot yet): there is
-- nothing to serve, so that single case blocks synchronously.
--
-- The returned 'Bool' is the /stale/ flag: 'True' means a rebuild is in
-- flight (or pending) and the results reflect a previously-built snapshot
-- rather than a guaranteed-fresh one. Callers ('AgdaMcp.Tools.withFresh'
-- /etc./) surface it as a one-line footer. The flag is the foundation the
-- telemetry (E6) and other-tool fast-paths (E2) build on, so it is kept
-- explicit here. Serve-stale is /always on/ — there is no opt-out.
--
-- Two staleness-detection paths decide whether a rebuild is warranted:
--
--   * /watched/ — when an fsnotify watcher is live ('startWatcher'
--     succeeded), changes set 'ssDirty', so a query only has to read a
--     flag (O(1)) instead of re-scanning the source tree. The watcher's
--     worker has usually already rebuilt between queries; if a query
--     races ahead of it the snapshot is served stale while the worker
--     finishes.
--   * /polled/ (portable fallback) — no watcher, so we re-scan the
--     source tree's file-count + newest mtime and compare to the
--     snapshot's 'ScanSig'. On a mismatch we also (lazily) ensure the
--     background worker is running so 'ssWake' actually drains.
ensureFresh :: ServerState -> IO (Either String (Loaded, Bool))
ensureFresh ss@ServerState{..}
  | cfgPreloaded ssConfig = do
      cur <- readIORef ssLoaded
      case cur of
        Just ld -> pure (Right (ld, False))   -- preloaded never rebuilds: never stale
        Nothing -> withMVar ssRebuildLock $ \_ -> do
          -- Re-check under the lock in case a concurrent caller seeded it.
          cur' <- readIORef ssLoaded
          case cur' of
            Just ld -> pure (Right (ld, False))
            Nothing -> seedFrom (loadLoaded (cfgAutoResolveUnique ssConfig) (cfgIncludes ssConfig) (cfgGraphPath ssConfig))
  | otherwise = do
      cur <- readIORef ssLoaded
      case cur of
        -- No snapshot yet: nothing to serve, so block on the one build.
        -- This is the only synchronous-build path left in 'ensureFresh'.
        Nothing -> firstBuild
        Just ld -> do
          warranted <- rebuildWarranted ld
          if not warranted
            then pure (Right (ld, False))      -- fresh enough
            else do
              -- Serve stale + schedule an async rebuild. Coalescing:
              -- setting ssDirty and a single tryPutMVar is idempotent under
              -- concurrent callers; 'rebuildLocked' still serialises the
              -- actual subprocess. 'ensureWorker' guarantees a drain thread
              -- exists even on the polled/no-watch path.
              if cfgAutoRebuild ssConfig
                then do
                  writeIORef ssDirty True
                  ensureWorker ss
                  void (tryPutMVar ssWake ())
                  pure (Right (ld, True))
                -- Auto-rebuild off: do not schedule a (looping) background
                -- rebuild; serve the snapshot as-is, not flagged stale.
                else pure (Right (ld, False))
  where
    -- Is a rebuild warranted for the current snapshot? Watched: trust the
    -- dirty flag (no scan); polled: re-scan and compare the ScanSig. Both
    -- also rebuild when the on-disk node-key format is stale.
    rebuildWarranted ld = do
      watching <- isWatching ss
      dirty    <- readIORef ssDirty
      if watching
        then pure (dirty || not (loadedFormatCurrent ld))
        else do
          newSig <- scanSources (cfgIncludes ssConfig)
          pure (dirty || ldScanSig ld /= newSig || not (loadedFormatCurrent ld))

    -- The genuine first build: no snapshot exists, so we must block. Reuse
    -- the serialised gate. If a concurrent caller already seeded a snapshot
    -- while we waited for the lock, 'rebuildLocked' re-reads it under the
    -- lock and the predicate then only rebuilds if it is actually stale —
    -- avoiding a redundant synchronous build in that race. A result here is
    -- always treated as "fresh" (stale = False): we blocked for it.
    firstBuild = do
      r <- rebuildLocked ss $ \dirty ld ->
             pure (dirty || not (loadedFormatCurrent ld))
      pure (fmap (\ld -> (ld, False)) r)

    seedFrom act = do
      r <- act
      case r of
        Right ld -> writeIORef ssLoaded (Just ld) >> pure (Right (ld, False))
        Left e   -> pure (Left e)

-- | The single serialised rebuild gate, shared by 'ensureFresh' (both
-- the watched and polled paths) and the watcher's worker. Holds
-- 'ssRebuildLock' so the worker and a query never spawn @agda-deps@
-- concurrently. The @needBuild@ predicate is consulted /under the lock/
-- against the current snapshot and the pending-dirty flag; when there is
-- no snapshot yet (or auto-rebuild is off and one exists) the obvious
-- thing happens without calling it.
--
-- 'ssDirty' is cleared /before/ the subprocess runs, so a source edit
-- that lands mid-rebuild re-dirties and is picked up on the next cycle.
rebuildLocked :: ServerState -> (Bool -> Loaded -> IO Bool) -> IO (Either String Loaded)
rebuildLocked ServerState{..} needBuild = withMVar ssRebuildLock $ \_ -> do
  cur   <- readIORef ssLoaded
  dirty <- readIORef ssDirty
  case cur of
    Just ld | not (cfgAutoRebuild ssConfig) -> pure (Right ld)
    Just ld -> do
      go <- needBuild dirty ld
      if go then doBuild cur else pure (Right ld)
    Nothing -> doBuild cur
  where
    doBuild cur = do
      writeIORef ssDirty False
      built <- runBuild ssConfig
      case built of
        Right ld -> writeIORef ssLoaded (Just ld) >> pure (Right ld)
        Left err -> case cur of
          Just ld -> do
            -- A failed rebuild keeps the stale snapshot AND re-marks it
            -- dirty so the background worker retries (after a backoff — see
            -- 'watchWorker'). Without re-dirtying, a transient failure
            -- would freeze the snapshot until the next source edit.
            writeIORef ssDirty True
            hPutStrLn stderr ("agda-explore: rebuild failed, serving stale graph: " ++ err)
            pure (Right ld)
          Nothing -> pure (Left err)

-- | Force a regeneration regardless of staleness (the @rebuild@ tool).
-- Serialised through 'ssRebuildLock' and clears 'ssDirty' so it composes
-- with the background watcher.
forceRebuild :: ServerState -> IO (Either String Loaded)
forceRebuild ServerState{..} = withMVar ssRebuildLock $ \_ -> do
  writeIORef ssDirty False
  built <- runBuild ssConfig
  case built of
    Right ld -> writeIORef ssLoaded (Just ld) >> pure (Right ld)
    Left err -> pure (Left err)

-- ---------------------------------------------------------------------
-- Query telemetry (E6)
-- ---------------------------------------------------------------------

-- | Append one telemetry record (a pre-built aeson 'Value') as a single
-- line to @cfgOutDir/query-log.jsonl@. Called from
-- 'AgdaMcp.Tools.handleCall' once per @tools/call@ (never for
-- @initialize@/@ping@/@tools\/list@). The caller decides /whether/ to call
-- this (it gates on 'cfgQueryLog'); this function unconditionally writes.
--
-- IO discipline (mirrors 'catchA' / 'safeMtime'): a telemetry write must
-- /never/ fail a query, so the whole append — directory creation included
-- — is wrapped in 'try' and any exception (read-only fs, full disk) is
-- silently dropped. Appends are serialised through the dedicated
-- 'ssLogLock' (not 'ssRebuildLock'): a log append must never block behind
-- a long @agda-deps@ rebuild, and the query thread + watcher worker must
-- not interleave a partial line.
--
-- The line carries a wall-clock @ts@ / @dur_ms@, so the file is
-- intentionally /not/ byte-reproducible. Note it grows unbounded
-- (append-only); rotation is out of scope.
appendQueryLog :: ServerState -> Value -> IO ()
appendQueryLog ServerState{..} v =
  withMVar ssLogLock $ \_ -> do
    _ <- (try act :: IO (Either SomeException ())) -- swallow everything
    pure ()
  where
    logPath = cfgOutDir ssConfig </> "query-log.jsonl"
    act = do
      createDirectoryIfMissing True (cfgOutDir ssConfig)
      BL.appendFile logPath (encode v <> "\n")

-- ---------------------------------------------------------------------
-- Background file-watch (optional; portable poll path is the fallback)
-- ---------------------------------------------------------------------

-- | Debounce window: coalesce the burst of inotify events a single
-- editor "save" emits (temp-file write + rename, etc.) before rebuilding.
watchDebounceMicros :: Int
watchDebounceMicros = 250000  -- 0.25s

-- | Backoff after a /failed/ background rebuild before the worker retries.
-- A failed rebuild leaves the snapshot dirty (so it retries); without this
-- pause a persistently-failing @agda-deps@ would spin in a tight loop,
-- re-spawning the subprocess as fast as it can fail.
rebuildBackoffMicros :: Int
rebuildBackoffMicros = 2000000  -- 2s

-- | Is a live watcher attached? When 'True', 'ensureFresh' trusts
-- 'ssDirty' instead of re-scanning the source tree.
isWatching :: ServerState -> IO Bool
isWatching ss = isJust <$> readIORef (ssWatcher ss)

-- | Start an fsnotify watcher over the configured include roots (live
-- mode + auto-rebuild + 'cfgWatch' only). On any change to an Agda source
-- file it flips 'ssDirty' and wakes a worker thread that rebuilds /between/
-- queries, so an edit is usually reflected before the next query arrives.
--
-- Best-effort: if the manager or any @watchTree@ throws (e.g. the inotify
-- watch limit, or a root that isn't a directory) we log one line and leave
-- 'ssWatcher' 'Nothing', so 'ensureFresh' silently keeps polling — the
-- portable fallback. A no-op outside live/auto-rebuild/watch mode.
startWatcher :: ServerState -> IO ()
startWatcher ss@ServerState{..}
  | cfgPreloaded ssConfig || not (cfgAutoRebuild ssConfig) || not (cfgWatch ssConfig) =
      pure ()
  | otherwise = do
      roots <- filterM doesDirectoryExist (cfgIncludes ssConfig)
      if null roots
        then hPutStrLn stderr
               "agda-explore: file-watch: no include directory to watch; polling instead."
        else do
          r <- try (setup roots) :: IO (Either SomeException ())
          case r of
            Right () -> hPutStrLn stderr
              ("agda-explore: watching " ++ show (length roots)
                 ++ " source root(s) for changes (rebuild between queries).")
            Left e -> hPutStrLn stderr
              ("agda-explore: file-watch unavailable (" ++ show e
                 ++ "); falling back to per-query polling.")
  where
    setup roots = do
      mgr <- startManager
      mapM_ (\root -> void (watchTree mgr root relevantEvent onEvent)) roots
      ensureWorker ss     -- start-at-most-once; shares the gate with the polled path
      writeIORef ssWatcher (Just mgr)
    -- A change worth a rebuild: an Agda source file outside VCS/build/output
    -- dirs. The extension filter also stops our own @deps.json@ writes
    -- under @.agda-explore@ from triggering a self-rebuild loop.
    relevantEvent :: Event -> Bool
    relevantEvent e =
      let p = eventPath e
      in agdaExt p && not (any (`isInfixOf` p) skipFragments)
    skipFragments = ["/.git/", "/dist-newstyle/", "/.agda-explore/", "/_build/"]
    onEvent _ = do
      writeIORef ssDirty True
      void (tryPutMVar ssWake ())   -- coalescing: one pending wakeup is enough

-- | Start the single background rebuild worker, at most once per daemon.
-- Both the fsnotify path ('startWatcher') and the polled serve-stale
-- fallback (a stale-serving 'ensureFresh' query, which has no watcher to
-- fork the worker for it) call this; the 'ssWorkerUp' MVar — created full,
-- holding one permit — ensures exactly one of them actually forks the
-- thread. (Two workers draining 'ssWake' could double-build.) A no-op
-- outside live/auto-rebuild mode, since nothing schedules an async
-- rebuild there.
ensureWorker :: ServerState -> IO ()
ensureWorker ss@ServerState{..}
  | cfgPreloaded ssConfig || not (cfgAutoRebuild ssConfig) = pure ()
  | otherwise = do
      won <- tryTakeMVar ssWorkerUp     -- claim the single start permit
      case won of
        Just () -> void (forkIO (watchWorker ss))   -- this caller starts it
        Nothing -> pure ()                          -- already running

-- | The background debounce + rebuild loop. Blocks on 'ssWake', waits out
-- the debounce window draining any further wakeups, then rebuilds if a
-- change is still pending. Started exactly once via 'ensureWorker' and
-- runs forever.
--
-- A failed rebuild re-marks the snapshot dirty (see 'rebuildLocked'); this
-- loop then waits 'rebuildBackoffMicros' and re-wakes itself so the retry
-- happens without a tight failing loop. A successful rebuild clears the
-- dirty flag, so the self-rewake is skipped.
watchWorker :: ServerState -> IO ()
watchWorker ss = forever $ do
  takeMVar (ssWake ss)
  threadDelay watchDebounceMicros
  void (tryTakeMVar (ssWake ss))     -- drain a wakeup raised during the delay
  -- Never let a transient rebuild exception kill the loop; the next edit
  -- (or a query's own ensureFresh) gets another chance.
  r <- try (rebuildLocked ss (\dirty _ -> pure dirty))
         :: IO (Either SomeException (Either String Loaded))
  case r of
    Right _ -> pure ()
    Left e  -> hPutStrLn stderr ("agda-explore: file-watch rebuild raised: " ++ show e)
  -- Retry path: if the snapshot is still dirty (a failed rebuild re-dirtied
  -- it, an exception left it set, or a fresh edit landed mid-build), back
  -- off and re-wake so the retry actually fires instead of stalling until
  -- the next external wakeup.
  stillDirty <- readIORef (ssDirty ss)
  if stillDirty
    then do
      threadDelay rebuildBackoffMicros
      void (tryPutMVar (ssWake ss) ())
    else pure ()
