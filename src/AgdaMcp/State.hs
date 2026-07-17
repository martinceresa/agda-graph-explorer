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
  , Freshness(..)
  , freshnessStale
  , currentNodeKeyVersion
    -- * Server
  , ServerState(..)
  , newServerState
    -- * Live regeneration
  , ensureFresh
  , forceRebuild
  , kickRebuild
  , warmStart
  , loadOverlays
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
    -- * Misc helpers
  , lastLines
  ) where

import           Control.Concurrent       (forkIO, threadDelay)
import           Control.Concurrent.MVar  (MVar, modifyMVar_, newEmptyMVar,
                                           newMVar, takeMVar, tryPutMVar,
                                           tryTakeMVar, withMVar)
import           Control.DeepSeq      (force)
import           Control.Exception    (SomeException, evaluate, finally, try)
import           Control.Monad        (filterM, forM, forever, void, when)
import           Data.Aeson           (Value, eitherDecode, encode)
import qualified Data.ByteString.Lazy as BL
import           Data.IORef
import qualified Data.IntMap.Strict   as IM
import           Data.List            (isInfixOf, isPrefixOf, isSuffixOf, maximumBy, sort, sortOn)
import qualified Data.Map.Strict      as M
import           Data.Maybe           (catMaybes, fromMaybe, isJust, mapMaybe)
import qualified Data.Set             as S
import           Data.Ord             (comparing)
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Data.Time.Clock      (NominalDiffTime, UTCTime, diffUTCTime,
                                       getCurrentTime)
import qualified Data.Vector          as V
import           GHC.IO.Handle.Lock   (LockMode (..), hTryLock, hUnlock)
import           System.Directory     (canonicalizePath,
                                       createDirectoryIfMissing,
                                       doesDirectoryExist, doesFileExist,
                                       findExecutable, getModificationTime,
                                       listDirectory, renameFile)
import           System.Environment   (getExecutablePath, lookupEnv)
import           System.Exit          (ExitCode (..))
import           System.FilePath      ((</>), makeRelative, takeBaseName,
                                       takeDirectory, takeFileName)
import           System.FSNotify      (Event (..), WatchManager, eventPath,
                                       startManager, watchTree)
import           System.IO            (IOMode (ReadWriteMode), hPutStrLn,
                                       stderr, withFile)
import           System.Mem           (performMajorGC)
import           System.Process       (CreateProcess (..), proc,
                                       readCreateProcessWithExitCode)

import           AgdaGraph.GoalCanon   (hashString, word64Hex16)
import           AgdaGraph.Glob       (globMatch)
import           AgdaGraph.Index      (Index, buildIndexLean, idxDefs, idxRealCount
                                      , baseNameKey, isLocalName)
import           AgdaGraph.Schema     (Definition (..), ExpandedGraph (..), ReExport (..))
import           AgdaGraph.Union      (unionExpandedGraphs)
import           AgdaGraph.Similarity (SigBodyFingerprints,
                                       buildSigBodyFingerprints,
                                       silhouetteDefaultWlK, subtermMultisetsVec)
import           AgdaGraph.WL         (Fingerprint)
import           AgdaInteract.Registry (SessionEntry (..))
import           AgdaMcp.Inspect      (InspectHub, newInspectHub)

-- | How the daemon (re)builds and reads the graph.
data Config = Config
  { cfgEntries      :: ![FilePath]
    -- ^ Agda entry modules for rebuilds (absolute paths). @[]@ = no entry
    -- configured (preloaded mode, or the daemon couldn't discover one).
    -- With more than one entry the daemon runs @agda-deps@ once per entry
    -- and unions the parsed graphs in-process (see 'runBuild' +
    -- 'AgdaGraph.Union.unionExpandedGraphs'); a single entry takes the
    -- one-subprocess path.
  , cfgIncludes     :: ![FilePath]       -- ^ @-i@ include dirs (and scan roots).
  , cfgProjectRoot  :: !FilePath         -- ^ cwd for the @agda-deps@ subprocess.
  , cfgOutDir       :: !FilePath         -- ^ where the generated @deps.json@ lives.
  , cfgGraphPath    :: !FilePath         -- ^ the graph file to read.
  , cfgPreloaded    :: !Bool             -- ^ True: user supplied a fixed graph; never rebuild.
  , cfgDepsBin      :: !(Maybe FilePath) -- ^ explicit @agda-deps@ path.
  , cfgUnusedBin    :: !(Maybe FilePath) -- ^ explicit @agda-unused@ path.
  , cfgRgBin        :: !(Maybe FilePath) -- ^ explicit @rg@ (ripgrep) path for @search mode=text@; else @$AGDA_EXPLORE_RG@ / @$PATH@.
  , cfgWithHashes   :: !Bool             -- ^ pass @--with-term-hashes@ on rebuild.
  , cfgWithSigs     :: !Bool             -- ^ pass @--with-signatures@ on rebuild.
  , cfgNormaliseSigs :: !Bool            -- ^ pass @--normalise-signatures@ on rebuild.
  , cfgShowImplicit :: !Bool             -- ^ pass @--signature-implicits@ on rebuild.
  , cfgMinTermDepth :: !Int              -- ^ @--min-term-depth@ on rebuild.
  , cfgAutoRebuild  :: !Bool             -- ^ auto-rebuild on detected staleness.
  , cfgWatch        :: !Bool             -- ^ use an fsnotify watcher (live mode) instead of per-query polling.
  , cfgIncremental  :: !Bool             -- ^ multi-entry incremental rebuilds: re-run @agda-deps@ only for entries whose closure a change touches, reusing the others' retained graphs (a RAM-for-speed trade). Off ⇒ every rebuild is full and nothing is retained.
  , cfgRequireWellTyped :: !Bool         -- ^ only promote a well-typed rebuild: a build with failed modules is withheld while a prior snapshot exists (serve-stale); holes still promote. See 'commitOrKeep'.
  , cfgStrictProducer :: !Bool           -- ^ strict @agda-deps@: drop @--keep-going@ (any error ⇒ serve stale) and enable @--incremental@ (needs Agda >= 2.9). See 'buildBaseArgs'.
  , cfgQueryLog     :: !Bool             -- ^ append one JSON line per @tools/call@ to @cfgOutDir/query-log.jsonl@.
  , cfgAutoResolveUnique :: !Bool        -- ^ auto-resolve a name to the sole "did you mean" candidate (tier 3 of 'AgdaMcp.Query.resolveDefNote').
  , cfgEnableInteract :: !Bool           -- ^ expose the write-side interaction-bridge tools (load/goal_type/give/…).
  , cfgAgdaBin      :: !(Maybe FilePath) -- ^ explicit @agda@ path for interaction sessions (else env/$PATH).
  , cfgInteractArgs :: ![String]         -- ^ extra flags passed to @agda --interaction-json@ (e.g. @--safe@).
  , cfgInteractHeapMb :: !Int            -- ^ per-session @agda@ RTS heap cap in MB (@+RTS -M@); @<= 0@ = no cap.
  , cfgMaxSessions  :: !Int              -- ^ cap on concurrently-live interaction @agda@ subprocesses.
  , cfgSessionIdleSecs :: !Int           -- ^ close an interaction session idle this many seconds; @<= 0@ = never (no reaper).
  , cfgInspect      :: !Bool             -- ^ run the localhost web inspector (@--inspect@).
  , cfgInspectPort  :: !Int              -- ^ start port for the inspector (probes upward on conflict).
  , cfgAutoHints    :: !Bool             -- ^ speculative Mimer hints on @check@: probe remaining goals and report found terms inline.
  , cfgAutoHintsLimit :: !Int            -- ^ max goals Mimer probes per @check@.
  , cfgAutoHintsSecs :: !Int             -- ^ Mimer per-goal budget in seconds (its @-t@ option).
  , cfgControlPort  :: !Int              -- ^ localhost control endpoint start port (hooks call @/check@); @<= 0@ = off.
  , cfgCoverageIgnore :: ![String]       -- ^ globs for source files intentionally outside every entry's closure; suppressed from the coverage warning.
  , cfgOverlays     :: ![ExpandedGraph]  -- ^ static overlay graphs (e.g. a prebuilt agda-stdlib graph), decoded once at startup and unioned into every snapshot so queries see external defs. Project defs win collisions.
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
  , cfgRgBin        = Nothing
  , cfgWithHashes   = True
  , cfgWithSigs     = True
  , cfgNormaliseSigs = False
  , cfgShowImplicit = False
  , cfgMinTermDepth = 3
  , cfgAutoRebuild  = True
  , cfgWatch        = True
  , cfgIncremental  = True
  , cfgRequireWellTyped = False
  , cfgStrictProducer = False
  , cfgQueryLog     = True
  , cfgAutoResolveUnique = True
  , cfgEnableInteract = False
  , cfgAgdaBin      = Nothing
  , cfgInteractArgs = []
  , cfgInteractHeapMb = 0          -- no agda heap cap unless configured
  , cfgMaxSessions  = 2            -- bound the worst-case live-session RAM
  , cfgSessionIdleSecs = 0         -- idle-session reaper off unless configured
  , cfgInspect      = False
  , cfgInspectPort  = 7000
  , cfgAutoHints    = True
  , cfgAutoHintsLimit = 3
  , cfgAutoHintsSecs = 1
  , cfgControlPort  = 0            -- control endpoint off unless configured
  , cfgCoverageIgnore = []
  , cfgOverlays     = []
  }

-- | A cheap fingerprint of the source tree: file count + newest mtime.
-- A change in either triggers a rebuild under 'ensureFresh'.
data ScanSig = ScanSig !Int !(Maybe UTCTime)
  deriving (Eq)

-- | How current the snapshot 'ensureFresh' serves is, for the read-side
-- staleness footer + the @stale@ telemetry column. 'Fresh' needs no footer;
-- the other two do (and both count as stale — see 'freshnessStale').
data Freshness
  = Fresh
    -- ^ current: watched with no pending edit, or polled with a matching 'ScanSig'.
  | Rebuilding
    -- ^ a rebuild is in flight (serve-stale); the background worker will swap
    -- the snapshot when it finishes.
  | BehindPending !NominalDiffTime
    -- ^ watched mode only: a source under the include roots is newer
    -- than the snapshot, but the fsnotify rebuild has not fired yet (debounce
    -- lag). Carries the gap (newest source mtime − snapshot build time).
  deriving (Eq)

-- | Whether a 'Freshness' marks a stale read (the @stale@ telemetry column /
-- a footer): everything but 'Fresh'.
freshnessStale :: Freshness -> Bool
freshnessStale Fresh = False
freshnessStale _     = True

-- | The node-key convention this binary expects. A loaded graph below
-- this is stale-format and (in live mode) triggers a rebuild rather than
-- serving results keyed by an older convention. Keep in sync with
-- 'AgdaDeps.Deps.nodeKeyVersion'.
currentNodeKeyVersion :: Int
currentNodeKeyVersion = 3

-- | One immutable graph snapshot held by the daemon.
data Loaded = Loaded
  { ldModuleCount :: !Int
    -- ^ Number of modules in the source graph. Precomputed at snapshot
    -- construction so the daemon needn't retain the whole parsed
    -- 'ExpandedGraph' (its 721k-edge @[(Text,Text)]@ list, raw provenance
    -- and subterm arrays) for the life of the snapshot just to answer a
    -- module count: 'buildIndexLean' already folds everything the queries
    -- need into 'ldIndex', so the 'ExpandedGraph' becomes garbage once this
    -- count is taken. Read by 'AgdaMcp.Query.queryStats'.
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
  , ldOrphanFiles :: ![FilePath]
    -- ^ Source files on disk but outside every entry's import closure
    -- (already @coverage-ignore@-filtered), so invisible to queries.
    -- Surfaced by @status@ and by the empty-result coverage note. Empty in
    -- preloaded mode.
  , ldBaseNameIndex :: M.Map Text [Definition]
    -- ^ Base-name (final dot-component, @\@line@-tag stripped) to the real
    -- defs carrying it. Lets 'AgdaMcp.Query.resolveDefNote' resolve a bare
    -- or dotted-suffix name by looking up one bucket instead of scanning
    -- every def. Lazy (built on the first non-exact resolution, then reused)
    -- so an exact-FQN-only workload pays nothing. Keyed by
    -- 'resolveBaseKey', which must mirror the Query name-normalisers.
  , ldAliases   :: !(M.Map Text Text)
    -- ^ @renaming@ re-export aliases: a host-qualified alias name
    -- (@Host.combine@) mapped to the canonical node-key it renames
    -- (@Core.Base.merge@), built from every 'ReExport' row's 'rxRenames'.
    -- Lets 'AgdaMcp.Query.resolveDefNote' resolve an alias — which is not a
    -- graph node — to its origin, and @search@ surface it. Empty when
    -- no re-export carries a @renaming@ clause.
  , ldStaleVsSource :: !Bool
    -- ^ At snapshot-construction time, the backing graph file was older
    -- than the newest source under the include roots — i.e. the graph
    -- predates an edit. Computed once (zero query-hot-path cost); 'False'
    -- when the graph has no single backing file (in-memory union) or no
    -- include roots are known (bare @--graph@, nothing to compare). Drives
    -- a source-staleness footer that also fires in preloaded mode, which
    -- 'ensureFresh' otherwise reports as never-stale.
  , ldConfigHash  :: !Text
    -- ^ Canonical identity digest of the graph's /configuration/: the
    -- build-date-stripped producer fingerprint, node-key + schema version,
    -- and the producer flag set (live mode). Stable across machines/dates
    -- for the same build recipe, so a consumer can key regressions on it.
    -- See 'graphIdentity'.
  , ldContentHash :: !Text
    -- ^ Digest of the graph's /content/: a fold over the sorted real-def
    -- set (name + kind + state). Changes when definitions are added or
    -- silently dropped, so it is the tripwire that makes a partial-build
    -- def drop visible in @status@ even when everything else looks
    -- fresh. See 'graphIdentity'.
  }

-- | Is this snapshot's node-key format current? When 'False' in live
-- mode, 'ensureFresh' rebuilds rather than serving stale-keyed results.
loadedFormatCurrent :: Loaded -> Bool
loadedFormatCurrent ld = ldNodeKeyV ld >= currentNodeKeyVersion

-- | Per-entry build cache for incremental multi-entry rebuilds: each
-- configured entry's decoded 'ExpandedGraph' plus the (canonicalised) set
-- of source files in its import closure, keyed by entry file. Retained
-- between rebuilds (when 'cfgIncremental') so a selective rebuild reuses
-- the graphs of entries no change touched; the closure set drives the
-- which-entries-to-re-run decision ('chooseReRun'). Holding the per-entry
-- graphs is the deliberate RAM-for-speed trade behind 'cfgIncremental'.
type EntryCache = M.Map FilePath (ExpandedGraph, S.Set FilePath)

data ServerState = ServerState
  { ssConfig      :: !Config
  , ssLoaded      :: !(IORef (Maybe Loaded))
  , ssStartedAt   :: !UTCTime               -- ^ when this daemon process started.
  , ssDirty       :: !(IORef Bool)          -- ^ set by the watcher (or a serve-stale query); a rebuild is pending.
  , ssBuilding    :: !(IORef Bool)
    -- ^ True while a rebuild holds 'ssRebuildLock' and is actually running
    -- @agda-deps@ (raised around the build in 'rebuildLocked' / 'forceRebuild'
    -- / 'kickRebuild', reset in a 'finally'). Distinct from 'ssDirty', which
    -- is /cleared/ up front at build start so a mid-build edit re-dirties — so
    -- during the (minutes-long) subprocess 'ssDirty' reads 'False' and cannot
    -- itself signal "a rebuild is in flight". 'ensureFresh' and @status@ OR
    -- this in, so a snapshot being actively superseded is served stale (with
    -- the footer) rather than presented as fresh.
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
    -- ^ Telemetry: whether the /most recent/ tool runner served a
    -- stale snapshot — i.e. a rebuild was pending/in-flight (the @stale@
    -- column), NOT "this query itself ran a rebuild". The tool runners
    -- write it via the @(Loaded, Freshness)@ plumbing ('freshnessStale');
    -- 'AgdaMcp.Tools.handleCall' reads and
    -- resets it after each @tools/call@. (status sets it 'False'; the
    -- @rebuild@ tool sets it 'True'.)
  , ssLogLock     :: !(MVar ())
    -- ^ Serialises 'appendQueryLog' appends to @query-log.jsonl@. A
    -- /dedicated/ lock — never 'ssRebuildLock' — so a telemetry append can
    -- never block behind a (minutes-long) @agda-deps@ rebuild, and two
    -- threads (a query and the watcher worker) cannot interleave a line.
  , ssSessions    :: !(MVar (M.Map FilePath SessionEntry))
    -- ^ The write-side interaction bridge's live @agda --interaction-json@
    -- sessions, keyed by loaded module file. Guarded by an 'MVar' (not a
    -- bare 'IORef') because the background file-watcher thread flips each
    -- entry's 'seDirty' flag concurrently with the (serialised) tool calls.
  , ssColdError   :: !(IORef (Maybe Text))
    -- ^ Cold-start diagnostic. Set when the /first/ graph build fails (no
    -- snapshot exists to serve). While set, queries return this actionable
    -- message immediately instead of each re-running a full synchronous
    -- @agda-deps@ build, and the background worker keeps retrying so the
    -- daemon self-heals once the offending module is fixed — no reconnect.
    -- Cleared on the first successful build. (Serve-stale only covers the
    -- /after one good build/ case; this covers the cold start.)
  , ssFailSig     :: !(IORef (Maybe ScanSig))
    -- ^ The source 'ScanSig' captured at the /last failed/ rebuild, or
    -- 'Nothing' after any success. The background worker ('watchWorker')
    -- uses it to /change-gate/ retries: it only re-spawns @agda-deps@ when
    -- the current source signature differs from this one. Without it a
    -- persistently-failing corpus retried on a fixed timer — fine when a
    -- build fails in milliseconds, but a 9-entry pass over a large corpus
    -- takes minutes, so back-to-back retries on byte-identical (still
    -- broken) sources burned CPU indefinitely. Gating on the signature
    -- means a doomed build runs once per source state; a real edit (or the
    -- fix to the broken module) changes the signature and re-enables it, so
    -- the daemon still self-heals. The manual @rebuild@ tool ('forceRebuild')
    -- bypasses the gate for transient-failure recovery.
  , ssDirtyFiles  :: !(IORef (S.Set FilePath))
    -- ^ Source files changed since the last build, accumulated by the
    -- fsnotify watcher ('onEvent', canonicalised). Drives /selective/
    -- rebuilds: only entries whose closure intersects this set re-run
    -- @agda-deps@ (see 'chooseReRun'). Empty under the polled fallback
    -- (no paths) ⇒ a full rebuild. Snapshot-and-cleared at build start so
    -- an edit landing mid-build is picked up next round (see 'runBuildShared').
  , ssEntryCache  :: !(IORef EntryCache)
    -- ^ Retained per-entry graphs + closures for incremental rebuilds
    -- ('EntryCache'). Empty until the first full build; written empty (so
    -- nothing is retained) whenever 'cfgIncremental' is off.
  , ssExtraEntries :: !(IORef [FilePath])
    -- ^ Runtime /ad-hoc/ entries (Stage B): brand-new modules nothing in
    -- the configured closures imports yet, surfaced so a freshly-authored
    -- file (e.g. via the bridge's @new_module@) is queryable without being
    -- added to @entries:@. Appended to 'cfgEntries' for builds; pruned when
    -- the file is deleted or fails to build. Incremental-mode only.
  , ssAddedFiles  :: !(IORef (S.Set FilePath))
    -- ^ Files the watcher saw /created/ ('Added' events, canonicalised)
    -- since the last build — the new-module candidates. Keyed on the create
    -- event (not modify) so a genuinely-new file is told apart from a
    -- path-mismatch on an existing closure file (which must stay a safe full
    -- rebuild, never an ad-hoc add that could shadow a stale entry).
  , ssInspect     :: !(Maybe InspectHub)
    -- ^ The localhost web-inspector event bus, or 'Nothing' when
    -- @--inspect@ is off. When 'Nothing' every 'AgdaMcp.Inspect.emitInspect'
    -- is a no-op and no socket/thread exists, so the feature is inert. The
    -- listening socket itself is started separately in @Main@
    -- ('AgdaMcp.Inspect.startInspector').
  , ssToolCounts  :: !(IORef (M.Map Text Int))
    -- ^ Per-run @tools/call@ histogram (tool name → invocation count),
    -- incremented in 'AgdaMcp.Tools.handleCall' and rendered by @status@ —
    -- passive adoption telemetry, so which tools agents actually use is
    -- visible without parsing transcripts. In-memory only (resets with the
    -- daemon).
  , ssBehindProbe :: !(IORef (Maybe (UTCTime, ScanSig)))
    -- ^ TTL cache for the "how far behind" probe: the wall-clock time of
    -- the last proactive source rescan and its 'ScanSig'. In /watched/ mode
    -- 'ensureFresh' rescans at most once per 'behindProbeTtl' to spot a
    -- snapshot behind an on-disk edit the fsnotify watcher has not yet
    -- delivered (debounce lag), without paying a full scan on every read.
  }

newServerState :: Config -> IO ServerState
newServerState c =
  ServerState c
    <$> newIORef Nothing
    <*> getCurrentTime
    <*> newIORef False          -- ssDirty
    <*> newIORef False          -- ssBuilding
    <*> newMVar ()
    <*> newEmptyMVar
    <*> newIORef Nothing
    <*> newMVar ()
    <*> newIORef False
    <*> newMVar ()
    <*> newMVar M.empty
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef S.empty
    <*> newIORef M.empty
    <*> newIORef []
    <*> newIORef S.empty
    <*> (if cfgInspect c then Just <$> newInspectHub else pure Nothing)
    <*> newIORef M.empty        -- ssToolCounts
    <*> newIORef Nothing        -- ssBehindProbe

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

loadLoaded :: Config -> FilePath -> IO (Either String Loaded)
loadLoaded cfg graphFile =
  decodeGraphFile graphFile
    >>= either (pure . Left)
               (fmap Right . loadedFromGraph cfg (Just graphFile))

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

-- | A short human-readable origin label for an overlay graph, derived from
-- its path: the containing directory's basename (e.g. a cache dir named
-- @stdlib-2.9-2.0@), falling back to the file's own basename. Rendered in
-- query output as @[external: <label>]@.
overlayLabel :: FilePath -> Text
overlayLabel p =
  let dir = takeFileName (takeDirectory p)
  in T.pack (if null dir || dir == "." then takeBaseName p else dir)

-- | Decode one overlay graph, validate it, and tag every definition with an
-- origin label. Rejected (a decode failure, or a node-key version that
-- differs from this binary's — its keys wouldn't cross-reference the
-- project graph's) with a clean diagnostic; a static overlay can't be
-- rebuilt, so a mismatch is skipped, never fatal.
loadOverlayGraph :: FilePath -> IO (Either String ExpandedGraph)
loadOverlayGraph path = do
  e <- decodeGraphFile path
  pure $ case e of
    Left err -> Left err
    Right eg
      | egNodeKeyVersion eg /= currentNodeKeyVersion ->
          Left ("node-key format v" ++ show (egNodeKeyVersion eg) ++ " != v"
                  ++ show currentNodeKeyVersion ++ " (this binary) — keys would not "
                  ++ "cross-reference the project graph")
      | otherwise ->
          let lbl = overlayLabel path
          in Right eg { egDefinitions =
                          map (\d -> d { defOrigin = Just lbl }) (egDefinitions eg) }

-- | Decode + tag the configured overlay graphs, warning-and-skipping any
-- that fail to load or version-mismatch (never fatal — a stale cache must
-- not take the daemon down). Called once at startup ('buildConfig');
-- the result is retained on 'cfgOverlays' and re-unioned into every
-- snapshot.
loadOverlays :: [FilePath] -> IO [ExpandedGraph]
loadOverlays paths = fmap catMaybes $ forM paths $ \p -> do
  r <- loadOverlayGraph p
  case r of
    Left err -> do
      hPutStrLn stderr ("agda-explore: skipping overlay graph " ++ p ++ ": " ++ err)
      pure Nothing
    Right eg -> do
      hPutStrLn stderr ("agda-explore: overlay graph " ++ p ++ " loaded ("
                          ++ show (length (egDefinitions eg)) ++ " defs, origin "
                          ++ show (overlayLabel p) ++ ")")
      pure (Just eg)

-- | Build a 'Loaded' snapshot from an already-parsed 'ExpandedGraph'. The
-- @mGraphFile@ is purely cosmetic — it names the source in the stale-format
-- warning; 'Nothing' for an in-memory union (no single backing file). The
-- index-construction / forcing / similarity-cache wiring lives here so the
-- disk path and the union path produce identical snapshots.
loadedFromGraph :: Config -> Maybe FilePath -> ExpandedGraph -> IO Loaded
loadedFromGraph cfg mGraphFile egProject = do
  -- Federate static overlay graphs (e.g. a stdlib graph) before indexing.
  -- Project graph FIRST: 'unionExpandedGraphs' keeps the earliest-seen record,
  -- so project defs win collisions and overlay-only names keep their origin.
  let eg | null (cfgOverlays cfg) = egProject
         | otherwise              = unionExpandedGraphs (egProject : cfgOverlays cfg)
  -- Take the module count up front so the rest of the snapshot can be built
  -- without keeping a reference to the full graph (see 'ldModuleCount').
  let !nMods = length (egModules eg)
      !ix = buildIndexLean eg
  _   <- evaluate (force ix)
  -- Materialise the real-def list and the owner lookup once. Both
  -- are forced (the queries rescan them per request and the snapshot
  -- never changes); the similarity caches below stay lazy by design.
  let !rds      = V.toList (V.take (idxRealCount ix) (idxDefs ix))
      !ownerMap = buildOwnerMap rds
  _   <- evaluate (force (length rds))
  _   <- evaluate (force (IM.size ownerMap))
  now <- getCurrentTime
  sig <- scanSources (cfgIncludes cfg)
  -- Coverage is a project concern: diff on-disk sources against the PROJECT
  -- graph's closure, not the overlay-merged one (overlay files live outside
  -- the project include roots anyway).
  orphans <- computeOrphanFiles (cfgIncludes cfg) (cfgCoverageIgnore cfg) egProject
  -- Source-vs-graph staleness, computed once here (see 'ldStaleVsSource'):
  -- the newest source mtime (from the scan just done) strictly newer than
  -- the backing graph file's mtime means the graph predates an edit. Only
  -- meaningful with a single backing file and known include roots.
  staleVsSrc <- case mGraphFile of
    Just gp | not (null (cfgIncludes cfg)) -> do
      mg <- safeMtime gp
      let ScanSig _ mNewest = sig
      pure (fromMaybe False ((>) <$> mNewest <*> mg))
    _ -> pure False
  let nkv = egNodeKeyVersion eg
      (configHash, contentHash) = graphIdentity cfg eg rds
      -- Host-qualified alias -> canonical node-key, from every re-export
      -- row's renaming clause. Keyed by @rxFrom.<alias>@ so a query
      -- for the fully-qualified alias resolves through it.
      aliases = M.fromList
        [ (rxFrom r <> "." <> alias, canonical)
        | r <- egReExports eg, (alias, canonical) <- M.toList (rxRenames r) ]
  -- Force both digests here so the transient union 'eg' they read is released
  -- by 'commitBuild's major GC (same discipline as 'ix'/'rds' above), rather
  -- than pinned in an unforced thunk.
  _ <- evaluate (force configHash)
  _ <- evaluate (force contentHash)
  if nkv < currentNodeKeyVersion
    then hPutStrLn stderr
           ("agda-explore: " ++ maybe "graph" id mGraphFile
              ++ " uses node-key format v"
              ++ show nkv ++ " < v" ++ show currentNodeKeyVersion
              ++ " (stale) — queries may key nodes by an older "
              ++ "convention; rebuild to refresh.")
    else pure ()
  pure Loaded
    { ldModuleCount = nMods
    , ldIndex    = ix
    , ldModFiles = egModuleFiles eg
    , ldBuiltAt  = now
    , ldScanSig  = sig
    , ldFailed   = egFailedModules eg
    , ldProducer = egProducer eg
    , ldNodeKeyV = nkv
    , ldRealDefs = rds
    , ldOwnerMap = ownerMap
    , ldBaseNameIndex = M.fromListWith (++)
        [ (baseNameKey (defName d), [d]) | d <- rds ]
    , ldSigBodyFp = buildSigBodyFingerprints silhouetteDefaultWlK ix
    , ldSubtermFp = subtermMultisetsVec ix
    , ldAutoResolveUnique = cfgAutoResolveUnique cfg
    , ldOrphanFiles = orphans
    , ldStaleVsSource = staleVsSrc
    , ldConfigHash  = configHash
    , ldContentHash = contentHash
    , ldAliases    = aliases
    }

-- | Canonical @(config, content)@ identity digests for a snapshot (the
-- content half also tripwires silent def drops). Both are the
-- vendored Murmur64 ('AgdaGraph.GoalCanon.hashString', 16-hex-digit) over a
-- canonical rendering — no new dependency, and 64 bits is ample for an
-- identity tripwire.
--
--   * /config/ — the build recipe: the build-date-stripped producer
--     fingerprint (so it is stable across machines and rebuild dates),
--     node-key + schema version, and the producer flag set
--     ('buildBaseArgs'; empty in preloaded mode, which does not rebuild).
--     Not byte-compatible with the arena's own hash (theirs folds in an
--     arena-side seed sha), so @status@ prints the ingredients too and the
--     arena composes its own.
--   * /content/ — an order-independent sum of a per-def hash
--     (@name TAB kind TAB state@), so it changes iff the def set changes
--     without paying a sort or a whole-corpus intermediate string.
graphIdentity :: Config -> ExpandedGraph -> [Definition] -> (Text, Text)
graphIdentity cfg eg rds = (hex configHash, hex contentHash)
  where
    hex = T.pack . word64Hex16
    configHash  = hashString $ unlines $
      [ "producer=" ++ maybe "" (T.unpack . stripBuilt) (egProducer eg)
      , "nodeKeyVersion=" ++ show (egNodeKeyVersion eg)
      , "schemaVersion=2"
      ] ++ [ "flag=" ++ f | f <- buildFlagsFor cfg ]
    -- Sum (Word64, wrapping) of per-def hashes: commutative ⇒ independent of
    -- def order (the set is unordered), changes on any add/drop/rename.
    contentHash = foldl' (\ !acc d -> acc + hashString (defLine d)) 0 rds
    defLine d = T.unpack (defName d) ++ "\t" ++ show (defKind d) ++ "\t" ++ show (defState d)

-- | The producer flag set that identifies a graph's build recipe. Empty in
-- preloaded mode (the user supplied a fixed graph; no rebuild flags apply),
-- else the shared 'buildBaseArgs' minus the machine-specific paths (include
-- dirs and the strict-producer cache dir), so the hash stays portable.
buildFlagsFor :: Config -> [String]
buildFlagsFor cfg
  | cfgPreloaded cfg = []
  | otherwise        = filter portable (dropIncludes (buildBaseArgs cfg))
  where
    -- @-i DIR@ come in pairs; drop both. --cache-dir=PATH carries an absolute
    -- path under --strict-producer, so drop it too (it's environment, not recipe).
    dropIncludes ("-i" : _ : rest) = dropIncludes rest
    dropIncludes (x : rest)        = x : dropIncludes rest
    dropIncludes []                = []
    portable a = not ("--cache-dir=" `isPrefixOf` a)

-- | Strip a @, built <date>,@ segment from a producer fingerprint so the
-- config identity hash is stable across rebuild dates (mirrors the arena's
-- @,\\s*built[^,]*,@ → @,@ rule). No-op when there is no such segment.
stripBuilt :: Text -> Text
stripBuilt t = case T.breakOn ", built" t of
  (_, "")     -> t
  (pre, rest) -> case T.breakOn "," (T.drop (T.length ", built") rest) of
    (_, "")        -> pre                       -- no closing comma: drop the tail
    (_, afterComma) -> pre <> afterComma        -- rejoin at the next comma

-- | Precompute the @where@-/anonymous-module owner lookup consumed by
-- 'AgdaMcp.Query.ownerOf'. For every /local/ def with a known line, find
-- its enclosing top-level def — the nearest non-local def at or above the
-- helper's start line, in the helper's own module or an enclosing one —
-- and key it by the local def's 'defId'. A local def with no such owner
-- (or no line) is simply absent from the map (returns 'Nothing').
--
-- Equivalent, by construction, to a per-call scan + @maximumBy (comparing
-- defLine)@ over each rendered result line; folded
-- once here so a query touching N lines is O(N log n) rather than
-- O(N · nDefs). The non-local candidates are pulled out once and shared
-- across all locals.
buildOwnerMap :: [Definition] -> IM.IntMap Definition
buildOwnerMap rds =
  IM.fromList (mapMaybe owner locals)
  where
    -- Tag each def with its position in @rds@ so the tie-break matches the
    -- former @maximumBy (comparing defLine)@ over a scan in @rds@ order
    -- (equal max line ⇒ the LAST such def ⇒ the largest position).
    indexed   = zip [0 :: Int ..] rds
    locals    = [ d | (_, d) <- indexed, isLocalName d ]
    -- Non-local defs that carry a line, bucketed by module, each bucket a
    -- Vector ascending by (line, position). Instead of scanning every
    -- non-local per local (O(locals·nonLocals)), a local looks up only the
    -- buckets of its enclosing modules and binary-searches each for the
    -- best candidate at or above its line.
    byModule :: M.Map T.Text (V.Vector (Int, Int, Definition))
    byModule =
      M.map (V.fromList . sortOn (\(l, p, _) -> (l, p)))
        (M.fromListWith (++)
           [ (defModule o, [(ln, pos, o)])
           | (pos, o) <- indexed
           , not (isLocalName o)
           , Just ln  <- [defLine o]
           ])
    owner d = do
      ln <- defLine d
      let bests = [ b
                  | k        <- enclosingKeys (defModule d)
                  , Just vec <- [M.lookup k byModule]
                  , Just b   <- [bestLE ln vec]
                  ]
      case bests of
        [] -> Nothing
        _  -> let (_, _, o) = maximumBy (comparing (\(l, p, _) -> (l, p))) bests
              in Just (defId d, o)
    -- Segment-aligned module prefixes of @m@ including @m@ itself — exactly
    -- the modules @enclosingModule _ m@ accepts.
    enclosingKeys m =
      let parts = T.splitOn "." m
      in [ T.intercalate "." (take i parts) | i <- [1 .. length parts] ]
    -- Rightmost element with @line <= ln@ in a (line,position)-ascending
    -- vector — the largest (line, position) at or below the helper's line,
    -- matching the old @maximumBy (comparing defLine)@ within one bucket.
    bestLE :: Int -> V.Vector (Int, Int, Definition)
           -> Maybe (Int, Int, Definition)
    bestLE ln vec = go 0 (V.length vec - 1) Nothing
      where
        go lo hi best
          | lo > hi   = best
          | otherwise =
              let mid       = (lo + hi) `div` 2
                  e@(l,_,_) = vec V.! mid
              in if l <= ln then go (mid + 1) hi (Just e)
                            else go lo (mid - 1) best

-- | The producer flag list shared by every @agda-deps@ run (all but the
-- out-dir and the trailing entry positional).
--
-- Default @--keep-going@ emits a partial graph on a type error rather than
-- nothing. 'cfgStrictProducer' instead drops it (any error ⇒ no graph ⇒
-- serve stale) and enables @--incremental@ — the two are mutually exclusive
-- at the producer. The shared @--cache-dir@ above the per-entry out-dirs is
-- race-free (builds are serialised; 'buildMulti' runs entries sequentially)
-- and lets entries reuse each other's fragments.
buildBaseArgs :: Config -> [String]
buildBaseArgs Config{..} =
  [ "--format=json", "--json-mode=expanded", "--no-externals" ]
    ++ (if cfgStrictProducer
          then [ "--incremental", "--cache-dir=" ++ (cfgOutDir </> ".agda-deps-cache") ]
          else [ "--keep-going" ])
    ++ [ a | cfgWithHashes
           , a <- ["--with-term-hashes", "--min-term-depth=" ++ show cfgMinTermDepth] ]
    ++ ["--with-signatures" | cfgWithSigs]
    ++ ["--normalise-signatures" | cfgWithSigs && cfgNormaliseSigs]
    ++ ["--signature-implicits"  | cfgWithSigs && cfgShowImplicit]
    ++ concatMap (\d -> ["-i", d]) cfgIncludes

showEc :: ExitCode -> String
showEc ExitSuccess     = "exit 0"
showEc (ExitFailure n) = "exit " ++ show n

-- | One @agda-deps@ run into @outDir@ for @entry@; returns the graph file
-- path on success (the caller decodes it). Shared by the single- and
-- multi-entry paths so their build command can't drift.
runOneEntry :: Config -> FilePath -> FilePath -> FilePath -> IO (Either String FilePath)
runOneEntry cfg deps outDir entry = do
  createDirectoryIfMissing True outDir
  let args      = buildBaseArgs cfg ++ ["-o", outDir, entry]
      graphPath = outDir </> "deps.json"
  (ec, _out, err) <-
    readCreateProcessWithExitCode
      (proc deps args) { cwd = Just (cfgProjectRoot cfg) } ""
  exists <- doesFileExist graphPath
  pure $ if not exists
    then Left ("agda-deps produced no graph for " ++ entry ++ " ("
                 ++ showEc ec ++ "):\n" ++ lastLines 25 err)
    else Right graphPath

-- | Single-entry build: one @agda-deps@ into 'cfgOutDir' (writing exactly
-- 'cfgGraphPath'), then decode + index. No per-entry cache — there is
-- nothing to be selective about with one entry.
buildSingle :: Config -> FilePath -> FilePath -> IO (Either String Loaded)
buildSingle cfg deps entry =
  runOneEntry cfg deps (cfgOutDir cfg) entry
    >>= either (pure . Left) (loadLoaded cfg)

-- | 'canonicalizePath' collapsing any IO failure to the input path, so a
-- transient/edge case degrades to a non-match rather than a crash.
safeCanon :: FilePath -> IO FilePath
safeCanon p =
  either (const p) id <$> (try (canonicalizePath p) :: IO (Either SomeException FilePath))

-- | The source files in a graph's import closure, canonicalised so they
-- compare exactly against the watcher's (also canonicalised) change paths.
closureFiles :: ExpandedGraph -> IO (S.Set FilePath)
closureFiles eg = S.fromList <$> mapM safeCanon (M.elems (egModuleFiles eg))

-- | Source files under the @includes@ roots that are in no module of
-- @egProject@'s closure ('closureFiles') — on disk but outside every entry's
-- import closure, so invisible to every query. Both sides are canonicalised
-- (path-normalisation-independent), then @coverage-ignore@ globs drop matches;
-- each glob is tried against the absolute path, the basename, and the
-- include-relative path (so @papers/**@ and @Scratch.agda@ both work). Empty
-- when @includes@ is empty (preloaded mode).
computeOrphanFiles :: [FilePath] -> [String] -> ExpandedGraph -> IO [FilePath]
computeOrphanFiles includes ignore egProject = do
  onDisk  <- listAgdaFiles includes
  inGraph <- closureFiles egProject
  keep    <- filterM (fmap (\c -> not (S.member c inGraph)) . safeCanon) onDisk
  pure (sort [ f | f <- keep, not (ignored f) ])
  where
    ignored f = any (\g -> any (globMatch g) (forms f)) ignore
    forms f   = f : takeFileName f : [ makeRelative r f | r <- includes ]

-- | Decide which entries a rebuild must re-run @agda-deps@ for, given the
-- changed-file set. An edit usually touches only one entry's closure, so
-- re-running every entry (re-emitting tens of MB of unchanged JSON each)
-- is the dominant repeated waste this avoids.
--
-- Conservative by construction — anything that can't be /proven/ safe to
-- narrow falls back to re-running all entries:
--
--   * incremental disabled, no live watcher, or no full prior build to
--     reuse (partial cache) ⇒ full;
--   * woke without a known changed-file set (the polled fallback carries
--     no paths) ⇒ full;
--   * a changed file in /no/ known closure — a brand-new module, or a path
--     that didn't canonicalise to a closure entry ⇒ full. This is the
--     safety net: a path mismatch costs a slower rebuild, never a stale
--     graph.
--
-- Otherwise re-run exactly the entries whose closure contains a changed
-- file (plus any not yet in the cache — a new ad-hoc entry, 'Nothing'
-- below). Reused entries' graphs are byte-identical to a fresh run (same
-- sources + @.agdai@ ⇒ deterministic @agda-deps@), so the union — and thus
-- every query — is identical to a full rebuild.
--
-- @newAdhoc@ (Stage B) are brand-new modules being added as ad-hoc entries
-- this build: they are legitimately in no closure /yet/, so they are
-- excluded from the unmatched-⇒-full check (they become entries, not a
-- reason to rebuild the world) and re-run via the 'Nothing' branch.
chooseReRun :: Config -> Bool -> Bool -> EntryCache -> S.Set FilePath -> S.Set FilePath
            -> (Int -> FilePath -> Bool)
chooseReRun cfg forceFull watching cache dirty newAdhoc
  | runAll    = \_ _ -> True
  | otherwise = \_ e -> case M.lookup e cache of
                          Just (_, cl) -> not (S.null (S.intersection cl dirty))
                          Nothing      -> True
  where
    closures   = S.unions [ cl | (_, cl) <- M.elems cache ]
    dirtyMatch = dirty `S.difference` newAdhoc
    unmatched  = not (S.null (S.filter (`S.notMember` closures) dirtyMatch))
    runAll     =  forceFull
              || not (cfgIncremental cfg)
              || not watching
              || M.null cache             -- no prior build to reuse → full
              || (S.null dirty && S.null newAdhoc)  -- non-empty cache but nothing pending (e.g. a node-key/format rebuild) → full, not a stale-cache reuse
              || unmatched

-- | Union per-entry graphs and index the result into a 'Loaded' snapshot:
-- the shared tail of the multi-entry build ('buildMulti') and the warm
-- cold-start ('warmStart'), so the two can't drift in how they union + index
-- (or in the @loadedFromGraph@ argument shape). Returns the union too — the
-- builder still publishes it to 'cfgGraphPath'; warm-start discards it.
unionAndIndex :: Config -> [ExpandedGraph] -> IO (ExpandedGraph, Loaded)
unionAndIndex cfg egs = do
  let !eg = unionExpandedGraphs egs
  ld <- loadedFromGraph cfg Nothing eg
  pure (eg, ld)

-- | Multi-entry build with reuse over the given entry list (configured +
-- any ad-hoc Stage-B entries): re-run @agda-deps@ for the entries
-- 'chooseReRun' selects, reuse the cached 'ExpandedGraph' for the rest,
-- then union (in entry order — deterministic) and index. Returns the new
-- snapshot /and/ the refreshed per-entry cache. The union is published
-- atomically (temp + rename) so a second daemon passive-reading
-- 'cfgGraphPath' under the build lock never decodes a half-written file.
--
-- A failing /configured/ entry aborts the whole build with its diagnostic
-- (matches single-entry semantics). A failing /ad-hoc/ entry (a new module
-- that doesn't build yet) is dropped with a stderr note instead — a
-- half-authored scratch module must not take the whole graph down; it
-- reappears once it builds. The caller prunes dropped ad-hoc entries by
-- keeping only those present in the returned cache.
buildMulti :: Config -> [FilePath] -> FilePath -> (Int -> FilePath -> Bool) -> EntryCache
           -> IO (Either String (Loaded, EntryCache))
buildMulti cfg entries deps reRun cache = do
  let cfgSet = S.fromList (cfgEntries cfg)
      onFail entry err
        | entry `S.member` cfgSet = pure (Left err)                -- configured: fatal
        | otherwise = do                                           -- ad-hoc: drop + warn
            hPutStrLn stderr ("agda-explore: dropping ad-hoc module " ++ entry
                                ++ " (does not build): " ++ takeWhile (/= '\n') err)
            pure (Right Nothing)
  egsE <- forM (zip [0 :: Int ..] entries) $ \(i, entry) ->
    case M.lookup entry cache of
      Just (eg, cl) | not (reRun i entry) -> pure (Right (Just (entry, eg, cl)))   -- reuse
      _ -> do
        let outDir = cfgOutDir cfg </> ("entry-" ++ show i)
        r <- runOneEntry cfg deps outDir entry
        case r of
          Left err -> onFail entry err
          Right gp -> do
            de <- decodeGraphFile gp
            case de of
              Left err -> onFail entry err
              Right eg -> do cl <- closureFiles eg; pure (Right (Just (entry, eg, cl)))
  case sequence egsE of
    Left err -> pure (Left err)
    Right mrs -> do
      let rs       = catMaybes mrs
          newCache = M.fromList [ (e, (g, cl)) | (e, g, cl) <- rs ]
          unionTmp = cfgGraphPath cfg ++ ".tmp"
      (eg, ld) <- unionAndIndex cfg [ g | (_, g, _) <- rs ]
      BL.writeFile unionTmp (encode eg)
      renameFile unionTmp (cfgGraphPath cfg)
      pure (Right (ld, newCache))

lastLines :: Int -> String -> String
lastLines n = unlines . reverse . take n . reverse . lines

-- ---------------------------------------------------------------------
-- Cross-process build mutex
-- ---------------------------------------------------------------------

-- | The cross-process build-lock path for a project. One per
-- 'cfgOutDir' (which is per project), so it naturally scopes the mutex to
-- a single project's @.agda-explore@ working dirs.
buildLockPath :: Config -> FilePath
buildLockPath cfg = cfgOutDir cfg </> "build.lock"

-- | Run @act@ holding an exclusive, advisory file lock (@flock(2)@ via
-- 'hTryLock'), passing it whether the lock was acquired.
--
-- A daemon must hold this before it spawns @agda-deps@ into the shared
-- @.agda-explore@ dirs. Two daemons started on the same project (e.g. two
-- open editor/CLI sessions) would otherwise run @agda-deps@ into the same
-- per-entry out-dirs at once, overwrite each other's partially-written
-- graphs, and feed the failed-rebuild retry loop. The lock is held only
-- for one build pass; the kernel releases it when the holder's handle is
-- closed /or the process dies/, so a crashed builder hands off to the
-- other daemon with no stale-lock bookkeeping.
--
-- Non-blocking: 'False' is passed when another daemon holds the lock, so
-- the caller passive-reads the builder's graph instead of competing (see
-- 'runBuildShared'). If the platform/filesystem cannot lock ('hTryLock'
-- throws — e.g. some network mounts) we degrade to 'True' (behave as the
-- sole builder): never worse than the pre-lock single-process world.
withTryBuildLock :: FilePath -> (Bool -> IO a) -> IO a
withTryBuildLock path act =
  withFile path ReadWriteMode $ \h -> do
    got <- tryLockBestEffort h
    -- Unlock is best-effort too: when locking was unsupported (degraded
    -- 'True') 'hUnlock' would throw, so swallow it; the handle close that
    -- 'withFile' performs releases a real lock regardless.
    act got `finally` when got (void (try (hUnlock h) :: IO (Either SomeException ())))
  where
    tryLockBestEffort h = either (const True) id
      <$> (try (hTryLock h ExclusiveLock) :: IO (Either SomeException Bool))

-- | The build entry point, run under the cross-process build mutex
-- ('withTryBuildLock'). The daemon that wins the lock builds; a daemon
-- that finds it held becomes a /passive reader/ — it loads the graph the
-- winner publishes at 'cfgGraphPath' instead of spawning a competing
-- build. Preloaded mode and the no-entry case never spawn @agda-deps@, so
-- they skip the lock.
--
-- Multi-entry builds are /selective/ ('chooseReRun'): only entries whose
-- closure a changed file touches re-run @agda-deps@; the rest are reused
-- from the retained per-entry cache ('ssEntryCache'). @forceFull@ (the
-- manual @rebuild@ tool) re-runs everything. The changed-file set
-- ('ssDirtyFiles') is snapshot-and-cleared up front so an edit landing
-- mid-build is picked up next round; on a failed build it is restored.
--
-- Passive-read freshness: the reader picks up whatever union the builder
-- last published atomically (the temp+rename in 'buildMulti'); it may
-- briefly trail the builder until its own next rebuild trigger. That is
-- the intended trade — never two concurrent builders.
runBuildShared :: ServerState -> Bool -> IO (Either String Loaded)
runBuildShared ss forceFull
  | cfgPreloaded cfg =
      loadLoaded cfg (cfgGraphPath cfg)
  | null (cfgEntries cfg) =
      pure (Left "no entry module configured; start the server with --entry FILE (repeatable), \
                 \config `entries:`, or --graph FILE")
  | otherwise = do
      createDirectoryIfMissing True (cfgOutDir cfg)
      withTryBuildLock (buildLockPath cfg) $ \owner ->
        if not owner then passiveRead else build
  where
    cfg = ssConfig ss

    passiveRead = do
      hPutStrLn stderr
        "agda-explore: another daemon holds the build lock for this \
        \project; reading its published graph instead of running a \
        \competing agda-deps."
      loadLoaded cfg (cfgGraphPath cfg)

    build = do
      mdeps <- findBin "agda-deps" (cfgDepsBin cfg) "AGDA_DEPS_BIN"
      case mdeps of
        Nothing   -> pure (Left "could not locate the agda-deps binary (set AGDA_DEPS_BIN or pass --agda-deps-bin)")
        Just deps -> case cfgEntries cfg of
          [entry] -> buildSingle cfg deps entry
          _       -> do
            cache    <- readIORef (ssEntryCache ss)
            watching <- isWatching ss
            extras0  <- readIORef (ssExtraEntries ss)
            -- Snapshot + clear the changed/added sets atomically: edits and
            -- creates landing mid-build accumulate into the now-empty sets
            -- for the next round (mirrors how 'ssDirty' is cleared up front).
            dirty <- atomicModifyIORef' (ssDirtyFiles ss) (\s -> (S.empty, s))
            added <- atomicModifyIORef' (ssAddedFiles ss) (\s -> (S.empty, s))
            -- Stage B (incremental only): surface brand-new modules as ad-hoc
            -- entries. A created file in no known closure and not already an
            -- entry becomes one; deleted ad-hoc entries are pruned (the file
            -- is gone). With incremental off there are no ad-hoc entries.
            (allEntries, newAdhoc) <-
              if cfgIncremental cfg
                then do
                  extrasAlive <- filterM doesFileExist extras0
                  let closures = S.unions [ cl | (_, cl) <- M.elems cache ]
                      known    = S.fromList (cfgEntries cfg ++ extrasAlive)
                      adhoc    = [ f | f <- S.toList added
                                     , f `S.notMember` closures, f `S.notMember` known ]
                  pure (cfgEntries cfg ++ extrasAlive ++ adhoc, S.fromList adhoc)
                else pure (cfgEntries cfg, S.empty)
            let reRun  = chooseReRun cfg forceFull watching cache dirty newAdhoc
                nTotal = length allEntries
                nRun   = length [ () | (i, e) <- zip [0 :: Int ..] allEntries, reRun i e ]
            hPutStrLn stderr $
              "agda-explore: " ++ (if nRun == nTotal then "full" else "incremental")
                ++ " rebuild — re-running " ++ show nRun ++ "/" ++ show nTotal
                ++ " entr" ++ (if nTotal == 1 then "y" else "ies")
                ++ (if nRun == nTotal then "" else " (changed: " ++ show (S.size dirty) ++ " file(s)"
                      ++ (if S.null newAdhoc then "" else ", +" ++ show (S.size newAdhoc) ++ " new") ++ ")")
            r <- buildMulti cfg allEntries deps reRun cache
            case r of
              Left err -> do
                -- Restore the snapshots so the retry still covers them.
                modifyIORef' (ssDirtyFiles ss) (S.union dirty)
                modifyIORef' (ssAddedFiles ss) (S.union added)
                pure (Left err)
              Right (ld, newCache) -> do
                -- Retain the per-entry graphs only in incremental mode (the
                -- RAM-for-speed trade) — and likewise the surviving ad-hoc
                -- entries (those that actually built, dropping new modules
                -- that failed to compile or vanished). With incremental off
                -- neither is ever populated, so nothing is held between
                -- rebuilds and every build is full.
                when (cfgIncremental cfg) $ do
                  writeIORef (ssEntryCache ss) newCache
                  let cfgSet = S.fromList (cfgEntries cfg)
                  writeIORef (ssExtraEntries ss)
                    [ e | e <- allEntries, e `S.notMember` cfgSet, e `M.member` newCache ]
                pure (Right ld)

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
-- telemetry and other-tool fast-paths build on, so it is kept
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
-- | The TTL for the behind-probe cache. A full source rescan on every
-- read would defeat watched mode (whose whole point is to avoid scanning), so
-- the proactive "am I behind?" check runs at most once per this window.
-- Shorter than a typical fsnotify debounce lag (~2s measured), so a genuine
-- edit is still flagged within it.
behindProbeTtl :: NominalDiffTime
behindProbeTtl = 1

-- | In /watched/ mode, is the served snapshot behind an on-disk edit the
-- fsnotify watcher has not yet turned into a rebuild? Compares the newest
-- source mtime under the include roots against the snapshot's build time,
-- caching the scan under 'behindProbeTtl'. 'BehindPending' with the gap when
-- behind, else 'Fresh'. Skipped (→ 'Fresh') when the snapshot already knows it
-- predates a source ('ldStaleVsSource' — the source-staleness footer covers
-- that) or when there are no include roots to scan.
probeBehind :: ServerState -> Loaded -> IO Freshness
probeBehind ServerState{..} ld
  | ldStaleVsSource ld || null (cfgIncludes ssConfig) = pure Fresh
  | otherwise = do
      now    <- getCurrentTime
      cached <- readIORef ssBehindProbe
      ScanSig _ mNewest <- case cached of
        Just (t, sig) | diffUTCTime now t < behindProbeTtl -> pure sig
        _ -> do sig <- scanSources (cfgIncludes ssConfig)
                writeIORef ssBehindProbe (Just (now, sig))
                pure sig
      pure $ case mNewest of
        Just newest | newest > ldBuiltAt ld -> BehindPending (diffUTCTime newest (ldBuiltAt ld))
        _                                   -> Fresh

ensureFresh :: ServerState -> IO (Either String (Loaded, Freshness))
ensureFresh ss@ServerState{..}
  | cfgPreloaded ssConfig = do
      cur <- readIORef ssLoaded
      case cur of
        Just ld -> pure (Right (ld, Fresh))   -- preloaded never rebuilds: never stale
        Nothing -> withMVar ssRebuildLock $ \_ -> do
          -- Re-check under the lock in case a concurrent caller seeded it.
          cur' <- readIORef ssLoaded
          case cur' of
            Just ld -> pure (Right (ld, Fresh))
            Nothing -> seedFrom (loadLoaded ssConfig (cfgGraphPath ssConfig))
  | otherwise = do
      cur <- readIORef ssLoaded
      case cur of
        -- No snapshot yet: nothing to serve, so block on the one build.
        -- This is the only synchronous-build path left in 'ensureFresh'.
        Nothing -> firstBuild
        Just ld -> do
          warranted <- rebuildWarranted ld
          -- A rebuild already in flight (the worker cleared 'ssDirty' up front,
          -- so 'warranted' can read False mid-build) means this snapshot is
          -- about to be superseded: flag it stale so the footer fires rather
          -- than presenting soon-to-be-old data as fresh.
          building  <- readIORef ssBuilding
          if not warranted
            then
              -- Not scheduled for a rebuild. If one is in flight, this snapshot
              -- is about to be superseded (serve-stale). Otherwise, in watched
              -- mode, proactively check whether we are behind an edit the
              -- fsnotify event has not delivered yet (debounce lag).
              if building
                then pure (Right (ld, Rebuilding))
                else do
                  watching <- isWatching ss
                  fr <- if watching then probeBehind ss ld else pure Fresh
                  pure (Right (ld, fr))
            else
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
                  pure (Right (ld, Rebuilding))
                -- Auto-rebuild off: no background rebuild is coming, so don't
                -- cry stale — unless a manual rebuild (the `rebuild` tool) is
                -- actually in flight right now.
                else pure (Right (ld, if building then Rebuilding else Fresh))
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
      cold <- readIORef ssColdError
      case cold of
        -- A prior cold-start failure is cached: serve the diagnostic
        -- immediately rather than blocking this query on another full
        -- (likely-failing) build, and make sure a background worker is
        -- retrying so we self-heal once the corpus is fixed.
        Just diag -> do
          ensureWorker ss
          void (tryPutMVar ssWake ())
          pure (Left (T.unpack diag))
        Nothing -> do
          r <- rebuildLocked ss $ \dirty ld ->
                 pure (dirty || not (loadedFormatCurrent ld))
          case r of
            Right ld  -> pure (Right (ld, Fresh))
            Left raw  -> do
              -- 'doBuild' stored the clean diagnostic + re-dirtied; kick
              -- the worker so retries happen off the query path.
              ensureWorker ss
              void (tryPutMVar ssWake ())
              diag <- readIORef ssColdError
              pure (Left (maybe raw T.unpack diag))

    seedFrom act = do
      r <- act
      case r of
        Right ld -> writeIORef ssLoaded (Just ld) >> pure (Right (ld, Fresh))
        Left e   -> pure (Left e)

-- | Commit a freshly built snapshot: clear the cold-start and change-gate
-- failure markers, install it, and major-GC to reclaim the previous
-- snapshot plus the large transient decode 'Value' (paired with -Fd/-Iw so
-- the freed pages return to the OS), off the query hot path. Shared by
-- every successful build path ('rebuildLocked', 'forceRebuild',
-- 'kickRebuild') so they can't drift.
commitBuild :: ServerState -> Loaded -> IO ()
commitBuild ServerState{..} ld = do
  writeIORef ssColdError Nothing
  writeIORef ssFailSig Nothing
  writeIORef ssLoaded (Just ld)
  performMajorGC

-- | Run a build action with 'ssBuilding' raised for its whole duration
-- (subprocess + 'commitBuild'), so a concurrent query — and @status@ — sees
-- "a rebuild is in flight" and serves the current snapshot stale, even though
-- 'ssDirty' was cleared up front to catch mid-build edits. Reset in a
-- 'finally' so a build exception can't leave the flag stuck on. Call only
-- while holding 'ssRebuildLock'.
withBuilding :: ServerState -> IO a -> IO a
withBuilding ServerState{..} act =
  (writeIORef ssBuilding True >> act) `finally` writeIORef ssBuilding False

-- | Record the source signature a build failed on, so the background
-- worker change-gates the retry (see 'ssFailSig' / 'watchWorker') instead
-- of re-spawning @agda-deps@ over the same broken sources. The failure
-- counterpart to 'commitBuild'; shared by every fallible build path so the
-- gate can't be forgotten on one of them.
noteFailedSig :: ServerState -> IO ()
noteFailedSig ServerState{..} = do
  fsig <- scanSources (cfgIncludes ssConfig)
  writeIORef ssFailSig (Just fsig)

-- | Outcome of offering a freshly-built snapshot to 'commitOrKeep'. Both
-- constructors carry the snapshot now being served ('servedSnapshot').
data Promotion
  = Promoted  !Loaded   -- ^ installed as the new snapshot.
  | KeptStale !Loaded   -- ^ withheld under 'cfgRequireWellTyped'; carries the retained snapshot.

servedSnapshot :: Promotion -> Loaded
servedSnapshot (Promoted  ld) = ld
servedSnapshot (KeptStale ld) = ld

-- | Promote a freshly-built snapshot, or keep the current one. Under
-- 'cfgRequireWellTyped' a build with type errors (non-empty 'ldFailed') does
-- not replace an existing snapshot — keep serving the last well-typed graph
-- and change-gate a retry. Holes never enter 'ldFailed' (@agda-deps@ tags
-- them 'Hole'), so hole-filling still promotes. On cold start (no snapshot)
-- the partial is committed regardless, so the daemon degrades rather than
-- going dark. Call only under 'ssRebuildLock'.
commitOrKeep :: ServerState -> Loaded -> IO Promotion
commitOrKeep ss@ServerState{..} ld = do
  cur <- readIORef ssLoaded
  case cur of
    Just old | cfgRequireWellTyped ssConfig, not (null (ldFailed ld)) -> do
      noteFailedSig ss          -- change-gate the retry (see 'ssFailSig')
      writeIORef ssDirty True   -- queries told "stale"; a later edit retries
      let fs = ldFailed ld
      hPutStrLn stderr $
        "agda-explore: rebuild has type errors in " ++ show (length fs)
          ++ " module(s) (" ++ T.unpack (T.intercalate ", " (take 3 fs))
          ++ (if null (drop 3 fs) then "" else ", …")
          ++ "); serving last well-typed graph"
      pure (KeptStale old)
    _ -> commitBuild ss ld >> pure (Promoted ld)

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
rebuildLocked ss@ServerState{..} needBuild = withMVar ssRebuildLock $ \_ -> do
  cur   <- readIORef ssLoaded
  dirty <- readIORef ssDirty
  case cur of
    Just ld | not (cfgAutoRebuild ssConfig) -> pure (Right ld)
    Just ld -> do
      go <- needBuild dirty ld
      if go then doBuild cur else pure (Right ld)
    Nothing -> doBuild cur
  where
    doBuild cur = withBuilding ss $ do
      writeIORef ssDirty False
      built <- runBuildShared ss False
      case built of
        Right ld -> Right . servedSnapshot <$> commitOrKeep ss ld
        Left err -> do
          noteFailedSig ss   -- change-gate the retry (see 'ssFailSig')
          case cur of
            Just ld -> do
              -- A failed rebuild keeps the stale snapshot AND re-marks it
              -- dirty (so queries are told "stale" and a later edit retries).
              writeIORef ssDirty True
              hPutStrLn stderr ("agda-explore: rebuild failed, serving stale graph: " ++ err)
              pure (Right ld)
            Nothing -> do
              -- Cold start: no snapshot to serve. Record an actionable
              -- diagnostic and re-dirty; the daemon self-heals once the
              -- corpus is fixed (the fix moves 'ssFailSig' and re-enables
              -- the build), with no fixed-timer retry spin in between.
              writeIORef ssColdError (Just (coldStartDiag err))
              writeIORef ssDirty True
              pure (Left err)

-- | Force a regeneration regardless of staleness (the @rebuild@ tool).
-- Serialised through 'ssRebuildLock' and clears 'ssDirty' so it composes
-- with the background watcher.
forceRebuild :: ServerState -> IO (Either String Loaded)
forceRebuild ss@ServerState{..} = withMVar ssRebuildLock $ \_ -> withBuilding ss $ do
  writeIORef ssDirty False
  built <- runBuildShared ss True
  case built of
    Right ld -> Right . servedSnapshot <$> commitOrKeep ss ld
    Left err -> do
      noteFailedSig ss   -- gate a later wakeup on the same broken sources
      cur <- readIORef ssLoaded
      case cur of
        Nothing -> writeIORef ssColdError (Just (coldStartDiag err))   -- still cold
        Just _  -> pure ()
      pure (Left err)

-- | Warm cold-start: reconstruct the in-memory snapshot and the per-entry
-- cache from the graphs the previous run left on disk, instead of paying a
-- full (synchronous, ~minutes-long over a large corpus) @agda-deps@ rebuild
-- of every entry on the first query. The first query is then served
-- instantly from the retained snapshot while the background worker re-runs
-- only the entries whose closure a source changed while the daemon was down
-- — turning the cold start into a warm one. The start-up counterpart to the
-- running daemon's incremental selection ('chooseReRun'): same machinery,
-- seeded from disk rather than from the watcher.
--
-- Staleness is detected by /mtime/: each per-entry @entry-i/deps.json@'s
-- mtime is the time that entry was last built, so a closure file newer than
-- it means that entry must re-run, and a source newer than the whole prior
-- build that is in no closure is a module created while the daemon was down
-- (a Stage-B ad-hoc entry). The changed/added sets are seeded into
-- 'ssDirtyFiles' / 'ssAddedFiles' so the ordinary serve-stale path drives
-- exactly the needed selective rebuild.
--
-- Best-effort and conservative — never serves an incomplete graph as fresh:
--
--   * a no-op unless live + auto-rebuild + incremental + multi-entry (single
--     entry has no per-entry cache; preloaded never rebuilds);
--   * if /every/ configured entry's graph decodes, the snapshot is their
--     in-memory union (byte-identical to a fresh full build) and only the
--     mtime-changed entries are queued to re-run — nothing changed ⇒ no
--     rebuild at all;
--   * if some are missing/corrupt (an interrupted prior build), seed from the
--     last atomically-published union ('cfgGraphPath') if it decodes and
--     force a full background rebuild; if even that is absent, do nothing and
--     let the normal cold build run.
--
-- Must be called AFTER 'startWatcher' (so 'isWatching' — and thus the
-- incremental path in 'chooseReRun' — is live) and before the stdio loop,
-- while 'ssLoaded' is still 'Nothing'.
warmStart :: ServerState -> IO ()
warmStart ss@ServerState{..}
  | cfgPreloaded ssConfig
      || not (cfgAutoRebuild ssConfig)
      || not (cfgIncremental ssConfig)
      || length (cfgEntries ssConfig) < 2 = pure ()
  | otherwise = do
      already <- readIORef ssLoaded
      case already of
        Just _  -> pure ()   -- a query already won the race and built; leave it
        Nothing -> do
          let entries = cfgEntries ssConfig
          slots <- forM (zip [0 :: Int ..] entries) $ \(i, entry) -> do
            let gp = cfgOutDir ssConfig </> ("entry-" ++ show i) </> "deps.json"
            mt <- safeMtime gp
            case mt of
              Nothing -> pure Nothing
              Just t  -> either (const Nothing) (\eg -> Just (entry, eg, t))
                           <$> decodeGraphFile gp
          let present = catMaybes slots
          if length present == length entries
            then seedFromEntries present
            else seedFromUnion
  where
    cfg = ssConfig

    -- All entries present: union them in memory (matches 'buildMulti'),
    -- diff the closure mtimes to find the entries to re-run + the brand-new
    -- modules, and queue just those. Nothing changed ⇒ served fresh.
    seedFromEntries present = do
      withClosures <- forM present $ \(e, eg, t) -> do
        cl <- closureFiles eg
        pure (e, eg, cl, t)
      let cache = M.fromList [ (e, (g, cl)) | (e, g, cl, _) <- withClosures ]
      (_, ld) <- unionAndIndex cfg [ g | (_, g, _, _) <- withClosures ]
      -- Source mtimes, canonicalised to compare against the closure paths.
      srcs <- listAgdaFiles (cfgIncludes cfg)
      mts  <- forM srcs $ \f -> do
                cp <- safeCanon f
                mt <- safeMtime f
                pure (fmap (\t -> (cp, t)) mt)
      let mtimeMap   = M.fromList (catMaybes mts)
          allClosure = S.unions [ cl | (_, _, cl, _) <- withClosures ]
          maxBuilt   = maximum  [ t  | (_, _, _, t)  <- withClosures ]
          -- A closure file newer than its entry's graph ⇒ that entry re-runs.
          dirty = S.fromList
            [ f | (_, _, cl, t) <- withClosures, f <- S.toList cl
                , maybe False (> t) (M.lookup f mtimeMap) ]
          -- A source newer than the whole prior build and in no closure is a
          -- module created while the daemon was down ⇒ a new ad-hoc entry.
          added = S.fromList
            [ f | (f, mt) <- M.toList mtimeMap
                , f `S.notMember` allClosure, mt > maxBuilt ]
          pending     = S.size dirty + S.size added
          -- A stale on-disk node-key format needs a full rebuild too — the
          -- seeded snapshot still serves (with the old convention, banner and
          -- all) while it runs, never blocking.
          formatStale = not (loadedFormatCurrent ld)
          needBuild   = pending > 0 || formatStale
          suffix
            | not needBuild = " (graph up to date)"
            | pending == 0  = " (stale node-key format — rebuilding in background)"
            | otherwise     = "; " ++ show (S.size dirty) ++ " changed file(s)"
                                ++ (if S.null added then "" else ", " ++ show (S.size added) ++ " new")
                                ++ " — refreshing in background"
      writeIORef ssEntryCache cache
      writeIORef ssDirtyFiles dirty
      writeIORef ssAddedFiles added
      writeIORef ssDirty needBuild
      -- Cold start (ssLoaded == Nothing): commit directly. The 'commitOrKeep'
      -- gate would promote regardless here, so 'cfgRequireWellTyped' never
      -- withholds the first snapshot ("degrade, not go dark").
      commitBuild ss ld   -- install snapshot + GC the transient decodes
      hPutStrLn stderr $
        "agda-explore: warm start — reused " ++ show (length present)
          ++ " cached entries" ++ suffix
      when needBuild $ do
        ensureWorker ss
        void (tryPutMVar ssWake ())

    -- Some entry graphs are missing/corrupt (an interrupted prior build):
    -- serve the last complete union if it decodes and force a full
    -- background rebuild (empty change-set ⇒ 'chooseReRun' goes full,
    -- repopulating the cache). If the union is absent too, do nothing and
    -- let the normal cold build run.
    seedFromUnion = do
      r <- loadLoaded cfg (cfgGraphPath cfg)
      case r of
        Left _   -> pure ()
        Right ld -> do
          writeIORef ssDirty True
          commitBuild ss ld   -- install snapshot + GC the transient decode
          hPutStrLn stderr
            "agda-explore: warm start — per-entry cache incomplete; serving \
            \last published graph and rebuilding in background."
          ensureWorker ss
          void (tryPutMVar ssWake ())

-- | The synchronous /kick/: fold a file the bridge just authored into the
-- graph now, so it is queryable the moment the writing tool call returns —
-- instead of waiting for the asynchronous watcher rebuild. Used by
-- @new_module@ (a scaffolded skeleton) and @give_file@ (whole-file
-- @content@ / appended block). Registers @file@ as a candidate (in
-- 'ssAddedFiles', so a /new/ file becomes an ad-hoc entry — see
-- 'runBuildShared') and runs one incremental rebuild under 'ssRebuildLock'.
--
-- Run /under the lock/ so the post-build cleanup is race-free against the
-- background worker: on success it drops @file@ from the pending sets and
-- recomputes 'ssDirty', so the watcher's own (redundant) event for the same
-- write becomes a no-op — the worker's dirty gate then skips it — while a
-- concurrent edit to a /different/ file (which the watcher recorded during
-- the build) is preserved and still triggers its rebuild. Best-effort: a
-- build failure leaves the snapshot and re-arms the watcher. A no-op unless
-- live + auto-rebuild + incremental (otherwise there are no ad-hoc entries
-- and the watcher's full rebuild handles it).
--
-- If @file@ is an /existing/ closure file (a @give_file@ overwrite/append,
-- not a new module), the ad-hoc logic in 'runBuildShared' naturally treats
-- it as a normal selective change of its entry instead — no special-casing
-- here. The 'ssAddedFiles' insert is then harmless (an in-closure file is
-- excluded from the new-ad-hoc set).
kickRebuild :: ServerState -> FilePath -> IO ()
kickRebuild ss@ServerState{..} file
  | cfgPreloaded ssConfig || not (cfgAutoRebuild ssConfig) || not (cfgIncremental ssConfig) =
      pure ()
  | otherwise = do
      p <- safeCanon file
      modifyIORef' ssAddedFiles (S.insert p)
      modifyIORef' ssDirtyFiles (S.insert p)
      void (try (withMVar ssRebuildLock $ \_ -> withBuilding ss $ do
                   built <- runBuildShared ss False
                   case built of
                     Right ld -> do
                       prom <- commitOrKeep ss ld
                       case prom of
                         Promoted _ -> do
                           modifyIORef' ssDirtyFiles (S.delete p)
                           modifyIORef' ssAddedFiles (S.delete p)
                           rest <- readIORef ssDirtyFiles
                           writeIORef ssDirty (not (S.null rest))
                         KeptStale _ ->                    -- type errors under require-well-typed:
                           pure ()                         -- commitOrKeep re-dirtied + noted; leave p pending
                     Left _  -> do                         -- leave it for the watcher,
                       noteFailedSig ss                    -- change-gated like any failed build
                       writeIORef ssDirty True)
              :: IO (Either SomeException ()))

-- | A clean, actionable cold-start message wrapping the raw producer
-- error, shown by every graph tool (and @status@) while the first build
-- has never succeeded — instead of echoing the bare @exit 120@.
coldStartDiag :: String -> Text
coldStartDiag raw = T.pack $
  "the dependency graph has never built — the configured entry's import \
  \closure does not type-check, so there is no snapshot to serve yet. Fix \
  \the failing module reported below, or point `entries:` / `--entry` at a \
  \module that builds; the daemon retries in the background and self-heals \
  \once it does (no reconnect needed).\n\n" ++ raw

-- ---------------------------------------------------------------------
-- Query telemetry
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
    onEvent ev = do
      writeIORef ssDirty True
      -- Record which file changed (canonicalised) so the next rebuild can
      -- re-run only the entries whose closure it touches (see 'chooseReRun').
      p <- safeCanon (eventPath ev)
      modifyIORef' ssDirtyFiles (S.insert p)
      -- A created file is a new-module candidate (Stage B): tracked
      -- separately so a create is told apart from a modify of an existing
      -- file (see 'ssAddedFiles' / the ad-hoc-entry logic in 'runBuildShared').
      case ev of
        Added{} -> modifyIORef' ssAddedFiles (S.insert p)
        _       -> pure ()
      -- Serve-stale parity for live interaction sessions: a source change
      -- on disk marks every open session dirty so it reloads (refreshing
      -- its stable-goal map) on next use, rather than eagerly reloading a
      -- module nobody is interacting with.
      modifyMVar_ ssSessions (pure . M.map (\e -> e { seDirty = True }))
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
-- Change-gated retry. A failed rebuild leaves the snapshot dirty and
-- records the source signature it failed on ('ssFailSig'). This loop only
-- (re)builds when the /current/ source signature differs from that — so a
-- wakeup over byte-identical, still-broken sources (e.g. a serve-stale
-- query while the corpus is broken) costs a cheap rescan instead of
-- another doomed multi-minute @agda-deps@ pass. A real edit (or the fix to
-- the failing module) moves the signature and re-enables the build, so the
-- daemon self-heals; the 0.25s debounce is the only floor on wakeup rate.
-- Gating on the source signature (rather than a fixed self-rewake interval)
-- is deliberate: a fixed interval re-runs a ~minutes-long pass back-to-back
-- on an unchanged broken corpus.
watchWorker :: ServerState -> IO ()
watchWorker ss = forever $ do
  takeMVar (ssWake ss)
  threadDelay watchDebounceMicros
  void (tryTakeMVar (ssWake ss))     -- drain a wakeup raised during the delay
  dirty <- readIORef (ssDirty ss)
  when dirty $ do
    -- Gate: skip when we already failed on exactly these sources. Only the
    -- post-failure path needs the comparison, so we scan the source tree
    -- (an O(files) stat walk) ONLY when a prior build failed — a clean
    -- snapshot ('ssFailSig' = Nothing) always passes without scanning.
    failSig <- readIORef (ssFailSig ss)
    gated <- case failSig of
      Nothing -> pure False
      Just fs -> (== fs) <$> scanSources (cfgIncludes (ssConfig ss))
    when (not gated) $ do
      -- Never let a transient rebuild exception kill the loop; the next edit
      -- (or a query's own ensureFresh) gets another chance.
      r <- try (rebuildLocked ss (\d _ -> pure d))
             :: IO (Either SomeException (Either String Loaded))
      case r of
        Right _ -> pure ()
        Left e  -> hPutStrLn stderr ("agda-explore: file-watch rebuild raised: " ++ show e)
