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
    -- * Background file-watch
  , startWatcher
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
import           Data.Aeson           (eitherDecode)
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
import           AgdaGraph.Similarity (SigBodyFingerprints,
                                       buildSigBodyFingerprints,
                                       silhouetteDefaultWlK, subtermMultisetsVec)
import           AgdaGraph.WL         (Fingerprint)

-- | How the daemon (re)builds and reads the graph.
data Config = Config
  { cfgEntry        :: !(Maybe FilePath) -- ^ Agda entry module for rebuilds.
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
  }

defaultConfig :: Config
defaultConfig = Config
  { cfgEntry        = Nothing
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
  }

-- | Is this snapshot's node-key format current? When 'False' in live
-- mode, 'ensureFresh' rebuilds rather than serving stale-keyed results.
loadedFormatCurrent :: Loaded -> Bool
loadedFormatCurrent ld = ldNodeKeyV ld >= currentNodeKeyVersion

data ServerState = ServerState
  { ssConfig      :: !Config
  , ssLoaded      :: !(IORef (Maybe Loaded))
  , ssStartedAt   :: !UTCTime               -- ^ when this daemon process started.
  , ssDirty       :: !(IORef Bool)          -- ^ set by the watcher; a rebuild is pending.
  , ssRebuildLock :: !(MVar ())             -- ^ serialises rebuilds (watch worker vs. query).
  , ssWake        :: !(MVar ())             -- ^ coalescing watcher→worker wakeup.
  , ssWatcher     :: !(IORef (Maybe WatchManager))
    -- ^ the live fsnotify manager (also keeps it from being collected);
    -- 'Nothing' when watching is disabled or failed to start (poll fallback).
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

loadLoaded :: [FilePath] -> FilePath -> IO (Either String Loaded)
loadLoaded includes graphFile = do
  e <- try (BL.readFile graphFile) :: IO (Either SomeException BL.ByteString)
  case e of
    Left err -> pure (Left ("cannot read " ++ graphFile ++ ": " ++ show err))
    Right bs -> case eitherDecode bs of
      Left perr -> pure (Left ("cannot parse " ++ graphFile ++ ": " ++ perr))
      Right (eg :: ExpandedGraph) -> do
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
                 ("agda-explore: " ++ graphFile ++ " uses node-key format v"
                    ++ show nkv ++ " < v" ++ show currentNodeKeyVersion
                    ++ " (stale) — queries may key nodes by an older "
                    ++ "convention; rebuild to refresh.")
          else pure ()
        pure $ Right Loaded
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
runBuild :: Config -> IO (Either String Loaded)
runBuild Config{..}
  | cfgPreloaded = loadLoaded cfgIncludes cfgGraphPath
  | otherwise = case cfgEntry of
      Nothing -> pure (Left "no entry module configured; start the server with --entry FILE or --graph FILE")
      Just entry -> do
        mdeps <- findBin "agda-deps" cfgDepsBin "AGDA_DEPS_BIN"
        case mdeps of
          Nothing   -> pure (Left "could not locate the agda-deps binary (set AGDA_DEPS_BIN or pass --agda-deps-bin)")
          Just deps -> do
            createDirectoryIfMissing True cfgOutDir
            let args = [ "--format=json", "--json-mode=expanded"
                       , "--no-externals", "--keep-going" ]
                    ++ [ a | cfgWithHashes
                           , a <- ["--with-term-hashes"
                                  , "--min-term-depth=" ++ show cfgMinTermDepth] ]
                    ++ ["--with-signatures" | cfgWithSigs]
                    ++ ["--normalise-signatures" | cfgWithSigs && cfgNormaliseSigs]
                    ++ ["--signature-implicits"  | cfgWithSigs && cfgShowImplicit]
                    ++ concatMap (\d -> ["-i", d]) cfgIncludes
                    ++ ["-o", cfgOutDir, entry]
            (ec, _out, err) <-
              readCreateProcessWithExitCode
                (proc deps args) { cwd = Just cfgProjectRoot } ""
            exists <- doesFileExist cfgGraphPath
            if not exists
              then pure (Left ("agda-deps produced no graph (" ++ showEc ec
                                ++ "):\n" ++ lastLines 25 err))
              else loadLoaded cfgIncludes cfgGraphPath
  where
    showEc ExitSuccess     = "exit 0"
    showEc (ExitFailure n) = "exit " ++ show n

lastLines :: Int -> String -> String
lastLines n = unlines . reverse . take n . reverse . lines

-- ---------------------------------------------------------------------
-- Live regeneration entry points
-- ---------------------------------------------------------------------

-- | Return the current snapshot, regenerating first if the sources have
-- changed since it was built (unless preloaded or auto-rebuild is off).
-- On a rebuild failure with a prior snapshot in hand, the stale snapshot
-- is reused and a note is written to stderr.
--
-- Two staleness-detection paths share 'rebuildLocked':
--
--   * /watched/ — when an fsnotify watcher is live ('startWatcher'
--     succeeded), changes set 'ssDirty', so a query only has to read a
--     flag (O(1)) instead of re-scanning the source tree. The watcher's
--     worker has usually already rebuilt between queries; a query that
--     races ahead of it still rebuilds synchronously here.
--   * /polled/ (portable fallback) — no watcher, so we re-scan the
--     source tree's file-count + newest mtime and compare to the
--     snapshot's 'ScanSig', exactly as before.
ensureFresh :: ServerState -> IO (Either String Loaded)
ensureFresh ss@ServerState{..}
  | cfgPreloaded ssConfig = do
      cur <- readIORef ssLoaded
      case cur of
        Just ld -> pure (Right ld)
        Nothing -> withMVar ssRebuildLock $ \_ -> do
          -- Re-check under the lock in case a concurrent caller seeded it.
          cur' <- readIORef ssLoaded
          case cur' of
            Just ld -> pure (Right ld)
            Nothing -> seedFrom (loadLoaded (cfgIncludes ssConfig) (cfgGraphPath ssConfig))
  | otherwise = do
      watching <- isWatching ss
      if watching
        -- Watched: the worker has usually rebuilt already (dirty cleared);
        -- a query only rebuilds if it raced ahead of the worker, or the
        -- on-disk format is stale. No source-tree scan.
        then rebuildLocked ss $ \dirty ld ->
               pure (dirty || not (loadedFormatCurrent ld))
        else do
          newSig <- scanSources (cfgIncludes ssConfig)
          rebuildLocked ss $ \dirty ld ->
            -- Poll decision: rebuild when sources moved or the format is stale.
            pure (dirty || ldScanSig ld /= newSig || not (loadedFormatCurrent ld))
  where
    seedFrom act = do
      r <- act
      case r of
        Right ld -> writeIORef ssLoaded (Just ld) >> pure (Right ld)
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
-- Background file-watch (optional; portable poll path is the fallback)
-- ---------------------------------------------------------------------

-- | Debounce window: coalesce the burst of inotify events a single
-- editor "save" emits (temp-file write + rename, etc.) before rebuilding.
watchDebounceMicros :: Int
watchDebounceMicros = 250000  -- 0.25s

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
      void (forkIO (watchWorker ss))
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

-- | The watcher's debounce + rebuild loop. Blocks on 'ssWake', waits out
-- the debounce window draining any further wakeups, then rebuilds if a
-- change is still pending. Runs forever; one per daemon.
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
