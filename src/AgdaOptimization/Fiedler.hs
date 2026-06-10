{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Requires 'process' dep on the agda-optimization executable.
-- Also requires Python 3 with scipy installed; see scripts/fiedler_helper.py.
--
-- == Fiedler — global spectral near-cuts and module connectivity.
--
-- Computes the smallest non-trivial eigenpairs of the normalised
-- Laplacian @L = I − D^(−1/2) A D^(−1/2)@ of the /symmetrised/ dep
-- graph, then turns the spectrum into three rankings:
--
--   * /Bridge edges/ — undirected edges @(u, v)@ ranked by
--     @|v₂(u) − v₂(v)|@ along the Fiedler vector. Large gap = the edge
--     spans the spectral bisection and is a candidate "thin cut".
--   * /Algebraic-connectivity hotspots/ — modules ranked /ascending/
--     by @λ₂@ of their induced subgraph (helper restricts to that
--     subgraph's largest component). Low @λ₂@ = "stringy", linear
--     chain.
--   * /Resonant clusters/ — group nodes by their sign pattern across
--     @(v₂, v₃, …, v_k)@. Keep clusters whose members live in ≥ 2
--     declared modules (i.e. they /cross declared boundaries/) and
--     whose size meets a minimum.
--
-- The actual sparse-Lanczos lives in @scripts/fiedler_helper.py@
-- (scipy's @eigsh@). We marshal the graph to JSON, shell out, and
-- read back the eigenvectors. We never crash on a missing helper or
-- a degenerate spectrum — we emit a structured warning to stderr
-- and exit cleanly.
module AgdaOptimization.Fiedler
  ( Options(..)
  , defaultOptions
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq             ( NFData(..) )
import           Control.Exception           ( catch, try, SomeException )
import           Control.Monad               ( when )
import           Data.Foldable               ( foldl' )
import qualified Data.IntMap.Strict          as IM
import qualified Data.IntSet                 as IS
import           Data.IntSet                 ( IntSet )
import           Data.List                   ( intercalate, sortOn )
import qualified Data.Map.Strict             as Map
import           Data.Map.Strict             ( Map )
import           Data.Ord                    ( Down(..) )
import           Data.Text                   ( Text )
import qualified Data.Text                   as T
import qualified Data.Vector                 as V
import qualified Data.Version
import           System.Environment          ( getExecutablePath, lookupEnv )
import           System.Exit                 ( ExitCode(..) )
import           System.FilePath             ( (</>), takeDirectory )
import           System.IO                   ( hClose, hPutStrLn, openTempFile
                                             , stderr )
import           System.Directory            ( canonicalizePath, doesFileExist
                                             , removeFile )
import           System.Process              ( readProcessWithExitCode )

import qualified Data.Aeson                  as A
import           Data.Aeson                  ( (.=), (.:), (.:?), (.!=) )
import qualified Data.ByteString.Lazy        as BL

import           AgdaGraph.Index             ( Index(..), defAt )
import           AgdaGraph.Schema            ( Definition(..) )

import           AgdaOptimization.CLIParse   ( splitFlag, valueFor, readInt )
import           AgdaOptimization.Config     ( lookupKey )
import           AgdaOptimization.Report     ( GlobalOpts(..), OutFormat(..)
                                             , renderTable, emitJsonReport
                                             , withHumanOutput )

import qualified Paths_agda_graph_explorer   as Paths

----------------------------------------------------------------------
-- Options.

-- | User-facing knobs.
data Options = Options
  { optTopN   :: !Int
    -- ^ Cap on the number of rows in each section of the report.
    -- Default 50.
  , optEigK   :: !Int
    -- ^ Number of non-trivial eigenpairs (λ₂ … λ_{k+1}) to request
    -- from the helper. Default 5.
  , optHelper :: !FilePath
    -- ^ Python helper script. Empty string @""@ means "resolve at
    -- runtime via cabal data-files / env-var / argv0 fallback" — see
    -- 'resolveHelperPath'. A non-empty path (from @--helper=PATH@)
    -- is taken verbatim.
  , optPython :: !FilePath
    -- ^ Python interpreter. Default @python3@.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optTopN   = 50
  , optEigK   = 5
  , optHelper = ""
  , optPython = "python3"
  }

instance NFData Options where
  rnf (Options a b c d) = rnf a `seq` rnf b `seq` rnf c `seq` rnf d

-- | Hand-rolled CLI parser. Same shape as the rest of the
-- agda-optimization subcommands.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = go
  where
    sub = "fiedler"
    intK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      n <- readInt sub k v
      go (upd o n) rest
    strK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      go (upd o v) rest

    go :: Options -> [String] -> Either String Options
    go !o []     = Right o
    go !o (a:as) = case splitFlag a of
      Left err                        -> Left (sub <> ": " <> err)
      Right ("--top-n",   mv)         ->
        intK "--top-n" (\o' n -> o' { optTopN = n }) mv as o
      Right ("--eig-k",   mv)         ->
        intK "--eig-k" (\o' n -> o' { optEigK = n }) mv as o
      Right ("--helper",  mv)         ->
        strK "--helper" (\o' p -> o' { optHelper = p }) mv as o
      Right ("--python",  mv)         ->
        strK "--python" (\o' p -> o' { optPython = p }) mv as o
      Right (k, _)                    ->
        Left (sub <> ": unknown flag: " <> k)

-- | Overlay the @fiedler:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = do
  o1 <- updI "top-n"  (\v o -> o { optTopN   = v }) o0
  o2 <- updI "eig-k"  (\v o -> o { optEigK   = v }) o1
  o3 <- updS "helper" (\v o -> o { optHelper = v }) o2
  o4 <- updS "python" (\v o -> o { optPython = v }) o3
  pure o4
  where
    section = "fiedler"
    updI k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe Int)
      pure $ maybe o (`f` o) mv
    updS k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe FilePath)
      pure $ maybe o (`f` o) mv

----------------------------------------------------------------------
-- Helper path resolution.

-- | Resolve where to find @fiedler_helper.py@. Precedence:
--
--   1. Explicit @--helper=PATH@ (a non-empty 'optHelper').
--   2. @$AGDA_OPTIMIZATION_HELPER@ env var.
--   3. Cabal data-files: 'Paths.getDataFileName' @"scripts/fiedler_helper.py"@.
--   4. Fallback: @$(dirname argv0)/../scripts/fiedler_helper.py@.
--   5. Fallback: @$(dirname argv0)/../share/agda-deps-<ver>/scripts/fiedler_helper.py@.
--
-- Returns the first path that exists on disk, paired with the list of
-- paths actually probed (for diagnostics on failure).
resolveHelperPath :: Options -> IO (Maybe FilePath, [FilePath])
resolveHelperPath opts = do
  envOverride <- lookupEnv "AGDA_OPTIMIZATION_HELPER"
  let cliOverride = case optHelper opts of
                      "" -> Nothing
                      p  -> Just p

  -- Cabal data-file path: returns an absolute path under the package's
  -- data-dir whether we're running from the build tree or an installed
  -- @share/agda-deps-<ver>/@ tree.
  dataPath <- tryIO (Paths.getDataFileName "scripts/fiedler_helper.py")

  -- Argv-0-relative fallbacks. 'canonicalizePath' resolves symlinks so
  -- a binary invoked through e.g. @~/.cabal/bin/agda-optimization@
  -- (typically a symlink into the cabal store) lands on the real exe.
  exePath  <- tryIO (getExecutablePath >>= canonicalizePath)
  let exeDir      = takeDirectory <$> exePath
      siblingPath = (\d -> d </> ".." </> "scripts" </> "fiedler_helper.py")
                      <$> exeDir
      sharePath   = (\d -> d </> ".." </> "share"
                             </> ("agda-deps-" ++ pkgVersionString)
                             </> "scripts" </> "fiedler_helper.py")
                      <$> exeDir

  let candidates = catMaybes'
        [ cliOverride       -- (1)
        , envOverride       -- (2)
        , dataPath          -- (3)
        , siblingPath       -- (4)
        , sharePath         -- (5)
        ]
  resolved <- firstExisting candidates
  pure (resolved, candidates)
  where
    -- Local catMaybes; avoids a single-use import.
    catMaybes' = foldr (\m acc -> maybe acc (: acc) m) []

-- | Run an IO action that may throw and absorb any exception into
-- 'Nothing'. Used by 'resolveHelperPath' so unexpected failures from
-- 'Paths.getDataFileName' / 'getExecutablePath' / 'canonicalizePath'
-- don't kill the whole run.
tryIO :: IO a -> IO (Maybe a)
tryIO io = (Just <$> io) `catch` (\(_ :: SomeException) -> pure Nothing)

-- | First file on the candidate list whose path exists on disk.
firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting []     = pure Nothing
firstExisting (p:ps) = do
  ok <- doesFileExist p
  if ok then pure (Just p) else firstExisting ps

-- | Cabal-baked package version as a dotted string (e.g. @"1.1"@); used
-- to build the @share/agda-deps-<ver>/@ fallback path.
pkgVersionString :: String
pkgVersionString =
  intercalate "." (map show (Data.Version.versionBranch Paths.version))

----------------------------------------------------------------------
-- Helper protocol.

-- | Parsed return value from @fiedler_helper.py@.
data HelperOut = HelperOut
  { hoNTotal           :: !Int
  , hoNComponent       :: !Int
  , hoComponentIds     :: !(V.Vector Int)
    -- ^ Original node ids in the largest component, in the order the
    -- helper's eigenvectors are laid out.
  , hoDisconnected     :: !Bool
  , hoEigvals          :: !(V.Vector Double)
  , hoV2               :: !(V.Vector Double)
  , hoVK               :: !(V.Vector (V.Vector Double))
    -- ^ Higher eigenvectors @v_3 … v_{k+1}@, one row per eigenvector.
    -- May be empty if @--eig-k <= 1@ or the helper truncated.
  , hoModulesLambda2   :: !(Map Text Double)
  } deriving (Show)

instance A.FromJSON HelperOut where
  parseJSON = A.withObject "HelperOut" $ \o -> do
    nTot   <- o .:  "n_total"
    nComp  <- o .:  "n_component"
    ids    <- o .:  "component_node_ids"
    disc   <- o .:? "disconnected" .!= False
    evals  <- o .:  "eigvals"
    v2     <- o .:? "v2" .!= []
    vk     <- o .:? "vk" .!= []
    mods   <- o .:? "modules_lambda2" .!= Map.empty
    pure HelperOut
      { hoNTotal         = nTot
      , hoNComponent     = nComp
      , hoComponentIds   = V.fromList ids
      , hoDisconnected   = disc
      , hoEigvals        = V.fromList evals
      , hoV2             = V.fromList v2
      , hoVK             = V.fromList (map V.fromList vk)
      , hoModulesLambda2 = mods
      }

----------------------------------------------------------------------
-- Entry point.

-- | Top-level entry. Marshals the graph, invokes the Python helper,
-- and renders the three rankings (bridge edges, module hotspots,
-- resonant clusters). Never throws on helper failure — instead emits
-- a clear stderr diagnostic and exits cleanly (returns from 'run'
-- with no output rows).
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let !undirEdges = collectUndirectedEdges ix
      !modulesMap = collectNodeModules ix

  when (null undirEdges) $ do
    hPutStrLn stderr "[fiedler] graph has no edges; nothing to spectrally analyse."

  -- Resolve the helper path before doing any work. This is a cheap
  -- pre-check; if no candidate path exists on disk we don't bother
  -- marshalling input — we just emit an empty report with a clear
  -- diagnostic listing every path we probed.
  (mHelper, probed) <- resolveHelperPath opts
  case mHelper of
    Nothing -> do
      hPutStrLn stderr $
        "[fiedler] helper script not found.\n"
          ++ "          tried (in order):\n"
          ++ unlines (map ("            - " ++) probed)
          ++ "          set $AGDA_OPTIMIZATION_HELPER or pass "
          ++ "--helper=PATH to override."
      emitEmpty gOpts opts "helper-not-found"
    Just helperPath ->
      runWithHelper ix gOpts opts undirEdges modulesMap helperPath probed

-- | Run the helper once we know its path on disk. Split out from 'run'
-- so the resolution step stays short and the happy path is obvious.
runWithHelper
  :: Index
  -> GlobalOpts
  -> Options
  -> [(Int, Int)]               -- ^ undirected edges
  -> IM.IntMap Text             -- ^ node id -> module name
  -> FilePath                   -- ^ resolved helper path
  -> [FilePath]                 -- ^ all probed candidates (for diagnostics)
  -> IO ()
runWithHelper ix gOpts opts undirEdges modulesMap helperPath probed = do
  -- Marshal the input to a temp file.
  (inPath, inH)   <- openTempFile "/tmp" "agda-optimization-fiedler-in.json"
  (outPath, outH) <- openTempFile "/tmp" "agda-optimization-fiedler-out.json"
  hClose outH
  BL.hPut inH (A.encode (helperInputJson ix undirEdges modulesMap))
  hClose inH

  hPutStrLn stderr $
    "[fiedler] n=" ++ show (idxNodeCount ix)
      ++ ", |E|undirected=" ++ show (length undirEdges)
      ++ ", k=" ++ show (optEigK opts)
      ++ "; invoking " ++ optPython opts ++ " " ++ helperPath

  result <- try $ readProcessWithExitCode (optPython opts)
              [ helperPath
              , "--input", inPath
              , "--output", outPath
              , "--k", show (optEigK opts)
              ] ""
  -- Best-effort cleanup of the input file before we proceed.
  _ <- try (removeFile inPath) :: IO (Either SomeException ())

  case result of
    Left (e :: SomeException) -> do
      hPutStrLn stderr $
        "[fiedler] could not invoke python interpreter '"
          ++ optPython opts ++ "': " ++ show e
      _ <- try (removeFile outPath) :: IO (Either SomeException ())
      emitEmpty gOpts opts "helper-invocation-failed"
    Right (ExitSuccess, _stdout, stderrTxt) -> do
      when (not (null stderrTxt)) $
        hPutStrLn stderr ("[fiedler] helper stderr: " ++ stderrTxt)
      ho <- readHelperOutput outPath
      _  <- try (removeFile outPath) :: IO (Either SomeException ())
      case ho of
        Nothing -> emitEmpty gOpts opts "helper-output-unparseable"
        Just h  -> renderReport ix gOpts opts undirEdges h
    Right (ExitFailure code, _stdout, stderrTxt) -> do
      diagnoseHelperFailure helperPath probed code stderrTxt
      _ <- try (removeFile outPath) :: IO (Either SomeException ())
      emitEmpty gOpts opts (reasonFromCode code)

-- | Map a non-zero exit code from the helper to the 'reason' string
-- recorded in the JSON output. Keeps the JSON wire shape stable while
-- letting consumers distinguish causes programmatically.
reasonFromCode :: Int -> String
reasonFromCode 2 = "helper-not-found"
reasonFromCode 3 = "helper-python-dependency-missing"
reasonFromCode _ = "helper-nonzero-exit"

-- | Emit a stderr diagnostic appropriate for the exit code we just saw
-- from the helper.  We distinguish three families:
--
--   * Exit 2 — the Python interpreter itself signalled "file not
--     found".  We hit this if the resolved path was correct at
--     'doesFileExist' time but vanished before exec, or if the helper
--     does an internal @open()@ on a missing file.
--   * Exit 3 — our own preamble signalled "scipy/numpy not importable"
--     (see scripts/fiedler_helper.py).
--   * Anything else — generic failure, surface whatever stderr the
--     helper produced.
diagnoseHelperFailure :: FilePath -> [FilePath] -> Int -> String -> IO ()
diagnoseHelperFailure helperPath probed code stderrTxt = case code of
  2 -> hPutStrLn stderr $
         "[fiedler] helper script not found at: " ++ helperPath ++ "\n"
           ++ "          tried (in order):\n"
           ++ unlines (map ("            - " ++) probed)
           ++ "          set $AGDA_OPTIMIZATION_HELPER or pass "
           ++ "--helper=PATH to override."
           ++ (if null stderrTxt then ""
               else "\n          stderr: " ++ stderrTxt)
  3 -> hPutStrLn stderr $
         "[fiedler] helper present but Python dependency missing "
           ++ "(likely scipy or numpy);\n"
           ++ "          install with: pip install scipy numpy"
           ++ (if null stderrTxt then ""
               else "\n          stderr: " ++ stderrTxt)
  _ -> hPutStrLn stderr $
         "[fiedler] helper failed (exit " ++ show code ++ "): "
           ++ stderrTxt

-- | Read and decode the helper output JSON. We never crash with an
-- aeson error — empty/garbage files turn into 'Nothing'.
readHelperOutput :: FilePath -> IO (Maybe HelperOut)
readHelperOutput p = do
  e <- try (BL.readFile p) :: IO (Either SomeException BL.ByteString)
  case e of
    Left ex -> do
      hPutStrLn stderr ("[fiedler] could not read helper output: " ++ show ex)
      pure Nothing
    Right bs
      | BL.null bs -> do
          hPutStrLn stderr "[fiedler] helper output empty."
          pure Nothing
      | otherwise -> case A.eitherDecode bs of
          Left err -> do
            hPutStrLn stderr ("[fiedler] could not parse helper output: " ++ err)
            pure Nothing
          Right ho -> pure (Just ho)

-- | Emit an empty-but-valid report so downstream JSON consumers don't
-- crash. The @reason@ is surfaced in the stats block.
emitEmpty :: GlobalOpts -> Options -> String -> IO ()
emitEmpty gOpts opts reason = case gOutFormat gOpts of
  OutJson  -> emitJsonReport (gOutPath gOpts) (emptyJson opts reason)
  OutHuman -> withHumanOutput (gOutPath gOpts) $ do
    putStrLn (headerLine opts)
    putStrLn $ "(no output: " ++ reason ++ ")"

emptyJson :: Options -> String -> A.Value
emptyJson opts reason = A.object
  [ "subcommand"          .= ("fiedler" :: Text)
  , "options"              .= optionsJson opts
  , "stats"                .= A.object
      [ "n_total"          .= (0 :: Int)
      , "n_component"      .= (0 :: Int)
      , "disconnected"     .= False
      , "eigvals"          .= ([] :: [Double])
      , "reason"           .= reason
      ]
  , "bridges"              .= ([] :: [A.Value])
  , "module_hotspots"      .= ([] :: [A.Value])
  , "resonant_clusters"    .= ([] :: [A.Value])
  ]

----------------------------------------------------------------------
-- Marshalling: Index -> helper input JSON.

-- | Symmetrised, deduplicated edges as ordered pairs @(u, v)@ with
-- @u < v@. We strip self-loops at this layer too. The helper expects
-- both directions but it'll re-symmetrise; we keep one direction here
-- and let the helper double it (smaller wire payload).
collectUndirectedEdges :: Index -> [(Int, Int)]
collectUndirectedEdges ix =
  let !s = IM.foldlWithKey'
             (\acc u tgts ->
                IS.foldl' (step u) acc tgts)
             (Map.empty :: Map (Int, Int) ())
             (idxForward ix)
      step u !acc v
        | u == v    = acc
        | u < v     = Map.insert (u, v) () acc
        | otherwise = Map.insert (v, u) () acc
  in Map.keys s

-- | Node id -> module name. Drops nothing; every real id appears.
collectNodeModules :: Index -> IM.IntMap Text
collectNodeModules ix =
  V.ifoldl' (\acc i d -> IM.insert i (defModule d) acc) IM.empty (idxDefs ix)

-- | Build the JSON payload the helper expects.
--
-- Module map is keyed by the /string/ form of each node id because
-- JSON objects can't use integer keys; the helper parses the key back
-- with @int(k)@ on the Python side.
helperInputJson :: Index -> [(Int, Int)] -> IM.IntMap Text -> A.Value
helperInputJson ix edges mods =
  let stringKeyed :: Map String Text
      !stringKeyed = IM.foldlWithKey'
                       (\acc k v -> Map.insert (show k) v acc)
                       Map.empty mods
  in A.object
       [ "n"       .= idxNodeCount ix
       , "edges"   .= map (\(u, v) -> [u, v]) edges
       , "modules" .= stringKeyed
       ]

----------------------------------------------------------------------
-- Rendering.

-- | Compute the three rankings and emit either the human table or
-- the JSON record.
renderReport :: Index -> GlobalOpts -> Options -> [(Int, Int)] -> HelperOut -> IO ()
renderReport ix gOpts opts undirEdges ho = do
  let !lambda2 = if V.length (hoEigvals ho) >= 2
                   then hoEigvals ho V.! 1
                   else 0
      !disconnectedWarn = hoDisconnected ho
      !lowL2Warn        = lambda2 < lambda2DisconnectedEps

  when disconnectedWarn $
    hPutStrLn stderr $
      "[fiedler] graph was disconnected; analysis ran on the largest "
        ++ "component (" ++ show (hoNComponent ho)
        ++ "/" ++ show (hoNTotal ho) ++ " nodes)."
  when (lowL2Warn && not disconnectedWarn) $
    hPutStrLn stderr $
      "[fiedler] λ₂=" ++ showD3 lambda2
        ++ " is near zero; the spectral bisection is weak."

  -- Map helper's positional indices to original node ids.
  let !compIds   = hoComponentIds ho
      !v2vec     = hoV2 ho
      !vkRows    = hoVK ho     -- length = optEigK - 1 (typically); each row is a vector over the component
      idAt p
        | p >= 0 && p < V.length compIds = compIds V.! p
        | otherwise                       = -1
      !posOf =
        V.ifoldl' (\acc p oid -> IM.insert oid p acc) IM.empty compIds
      lookupV2 oid =
        IM.lookup oid posOf >>= \p ->
          if p < V.length v2vec then Just (v2vec V.! p) else Nothing

  -- Bridge edges: keep only edges with both endpoints in the largest
  -- component (others have no Fiedler value to compare).
  let !bridges = rankBridges ix opts undirEdges lookupV2

  -- Module hotspots: sort modules ascending by λ₂.
  let !hotspots = take (optTopN opts)
                $ sortOn snd
                $ Map.toList (hoModulesLambda2 ho)

  -- Resonant clusters: bucket nodes by sign pattern across (v₂ : vKRows),
  -- keep those that span ≥ 2 modules.
  let !clusters = computeClusters ix idAt v2vec vkRows minClusterSize

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        reportJson ix opts ho lambda2 bridges hotspots clusters
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn (headerLine opts)
      putStrLn (statsLine ho lambda2)
      putStrLn ""
      renderBridges ix bridges
      putStrLn ""
      renderHotspots hotspots lambda2
      putStrLn ""
      renderClusters ix clusters

-- | Below this threshold we treat λ₂ as zero (graph effectively
-- disconnected). Helpers can return tiny positive values from FP
-- noise, so we don't insist on exactly 0.
lambda2DisconnectedEps :: Double
lambda2DisconnectedEps = 1e-10

-- | A cluster must have at least this many members for us to print it.
-- (Anything smaller is noise: the sign-of-each-eigenvector signature
-- space is exponential in @k@, so tiny clusters are nearly always
-- spurious.)
minClusterSize :: Int
minClusterSize = 3

----------------------------------------------------------------------
-- Bridge ranking.

-- | One ranked bridge edge.
data Bridge = Bridge
  { brU    :: !Int
  , brV    :: !Int
  , brGap  :: !Double      -- |v₂(u) - v₂(v)|
  , brV2U  :: !Double
  , brV2V  :: !Double
  } deriving (Show)

instance NFData Bridge where
  rnf (Bridge a b c d e) =
        rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e

-- | Compute the top-N bridge edges by |v₂(u) − v₂(v)|. Edges whose
-- endpoints aren't in the largest component (no Fiedler value) are
-- dropped.
rankBridges
  :: Index
  -> Options
  -> [(Int, Int)]
  -> (Int -> Maybe Double)
  -> [Bridge]
rankBridges _ix opts edges lookupV2 =
  let mkBridge (u, v) = do
        !x <- lookupV2 u
        !y <- lookupV2 v
        let !g = abs (x - y)
        Just (Bridge u v g x y)
      !rated = foldl'
                 (\acc e -> case mkBridge e of
                              Just b  -> b : acc
                              Nothing -> acc)
                 [] edges
  in take (optTopN opts) (sortOn (Down . brGap) rated)

renderBridges :: Index -> [Bridge] -> IO ()
renderBridges ix bridges = do
  putStrLn "## Bridge edges (top by |v₂(u) − v₂(v)|)"
  let header = ["Rank", "Gap", "U", "→", "V", "v₂(U)", "v₂(V)"]
      rows =
        [ [ show r
          , showD3 (brGap b)
          , T.unpack (defName (defAt ix (brU b)))
          , "→"
          , T.unpack (defName (defAt ix (brV b)))
          , showD3 (brV2U b)
          , showD3 (brV2V b)
          ]
        | (r, b) <- zip [1 :: Int ..] bridges
        ]
  if null bridges
    then putStrLn "  (no bridges — graph too small or fully disconnected)"
    else putStr (renderTable header rows)

----------------------------------------------------------------------
-- Module hotspots.

renderHotspots :: [(Text, Double)] -> Double -> IO ()
renderHotspots hotspots globalL2 = do
  putStrLn "## Algebraic-connectivity hotspots (modules with low λ₂)"
  putStrLn $ "(global λ₂ = " ++ showD3 globalL2 ++ "; lower = stringier)"
  let header = ["Rank", "Module", "λ₂"]
      rows = [ [show r, T.unpack m, showD3 l2]
             | (r, (m, l2)) <- zip [1 :: Int ..] hotspots
             ]
  if null hotspots
    then putStrLn "  (no per-module λ₂ values — modules too small)"
    else putStr (renderTable header rows)

----------------------------------------------------------------------
-- Resonant clusters.

-- | A resonant cluster: a set of nodes sharing the same sign pattern
-- across (v₂, v₃, …, v_k), restricted to those crossing module
-- boundaries.
data Cluster = Cluster
  { clSignature :: ![Int]      -- ^ Sign pattern (-1 / 0 / 1) for each eigenvector
  , clNodes     :: !IntSet
  , clModules   :: !(Map Text Int)
    -- ^ How many cluster members each declared module contributes.
  } deriving (Show)

instance NFData Cluster where
  rnf (Cluster a b c) = rnf a `seq` rnf b `seq` rnf c

-- | Build sign-pattern clusters, dedup, restrict to those that span
-- ≥ 2 modules, sort by size (descending).
--
-- Signature is a list of @-1 / 0 / 1@ over @[v₂, v₃, …, v_k]@. We
-- collapse near-zero magnitudes (|val| < eps) to 0 so members on the
-- bisection boundary don't get split off as their own cluster.
computeClusters
  :: Index
  -> (Int -> Int)               -- ^ position p -> original node id
  -> V.Vector Double            -- ^ v₂ over the component
  -> V.Vector (V.Vector Double) -- ^ v₃ … v_k
  -> Int                        -- ^ minimum cluster size
  -> [Cluster]
computeClusters ix idAt v2 vks minSize =
  let !n = V.length v2
      !allVecs = v2 `V.cons` vks
      eps = 1e-3 :: Double
      sigOf p =
        [ signum' (vec V.! p) | vec <- V.toList allVecs ]
      signum' x
        | abs x < eps  =  0
        | x   <   0    = -1
        | otherwise    =  1
      -- Group node-positions by signature.
      buckets =
        foldl' (\acc p ->
                  let !sg = sigOf p
                      !oid = idAt p
                  in if oid < 0 then acc
                     else Map.insertWith (<>) sg (IS.singleton oid) acc)
               (Map.empty :: Map [Int] IntSet)
               [0 .. n - 1]
      withModuleSpread =
        [ Cluster sg members modBag
        | (sg, members) <- Map.toList buckets
        , IS.size members >= minSize
        , let modBag = moduleBag ix members
        , Map.size modBag >= 2
        ]
  in sortOn (Down . IS.size . clNodes) withModuleSpread

-- | Tally the modules that contribute to a cluster.
moduleBag :: Index -> IntSet -> Map Text Int
moduleBag ix members =
  IS.foldl'
    (\ !acc i ->
        let !m = defModule (defAt ix i)
        in Map.insertWith (+) m 1 acc)
    Map.empty members

renderClusters :: Index -> [Cluster] -> IO ()
renderClusters ix clusters = do
  putStrLn "## Resonant clusters (sign-pattern across v₂..v_k, crossing modules)"
  if null clusters
    then putStrLn "  (no qualifying clusters)"
    else do
      let header = ["Rank", "Size", "Signature", "#Mods", "Top modules", "Sample"]
          rows = [ [ show r
                   , show (IS.size (clNodes c))
                   , T.unpack (showSig (clSignature c))
                   , show (Map.size (clModules c))
                   , T.unpack (topModulesLabel (clModules c))
                   , T.unpack (sampleNodes ix (clNodes c))
                   ]
                 | (r, c) <- zip [1 :: Int ..] clusters
                 ]
      putStr (renderTable header rows)

showSig :: [Int] -> Text
showSig = T.pack . concatMap render
  where
    render (-1) = "-"
    render 0    = "0"
    render 1    = "+"
    render _    = "?"

topModulesLabel :: Map Text Int -> Text
topModulesLabel m =
  let sorted = take 3 (sortOn (Down . snd) (Map.toList m))
  in T.intercalate ", "
       [ mod_ <> "(" <> T.pack (show n) <> ")"
       | (mod_, n) <- sorted
       ]

sampleNodes :: Index -> IntSet -> Text
sampleNodes ix s =
  let sampled = take 3 (IS.toList s)
      lastSeg t = case T.breakOnEnd "." t of
        (_, suf) | T.null suf -> t
                 | otherwise  -> suf
  in T.intercalate ", " [ lastSeg (defName (defAt ix i)) | i <- sampled ]

----------------------------------------------------------------------
-- Header / stats rendering.

headerLine :: Options -> String
headerLine Options{..} =
     "# Fiedler — spectral bisection (k=" ++ show optEigK
  ++ ", top-n=" ++ show optTopN ++ ")"

statsLine :: HelperOut -> Double -> String
statsLine HelperOut{..} l2 =
     "# nodes=" ++ show hoNTotal
  ++ " component=" ++ show hoNComponent
  ++ (if hoDisconnected then " (disconnected — using LCC)" else "")
  ++ " λ₂=" ++ showD3 l2
  ++ " eigvals=["
  ++ intercalate ", " (map showD3 (V.toList (V.take 6 hoEigvals)))
  ++ "]"

----------------------------------------------------------------------
-- JSON rendering.

reportJson
  :: Index
  -> Options
  -> HelperOut
  -> Double            -- ^ Global λ₂.
  -> [Bridge]
  -> [(Text, Double)]  -- ^ Module hotspots.
  -> [Cluster]
  -> A.Value
reportJson ix opts ho lambda2 bridges hotspots clusters = A.object
  [ "subcommand"        .= ("fiedler" :: Text)
  , "options"           .= optionsJson opts
  , "stats"             .= A.object
      [ "n_total"       .= hoNTotal ho
      , "n_component"   .= hoNComponent ho
      , "disconnected"  .= hoDisconnected ho
      , "lambda2"       .= lambda2
      , "eigvals"       .= V.toList (hoEigvals ho)
      ]
  , "bridges"           .= map (bridgeJson ix) bridges
  , "module_hotspots"   .= map hotspotJson hotspots
  , "resonant_clusters" .= map (clusterJson ix) clusters
  ]

optionsJson :: Options -> A.Value
optionsJson Options{..} = A.object
  [ "top_n"  .= optTopN
  , "eig_k"  .= optEigK
  , "helper" .= optHelper
  , "python" .= optPython
  ]

bridgeJson :: Index -> Bridge -> A.Value
bridgeJson ix b = A.object
  [ "u_qname"  .= defName (defAt ix (brU b))
  , "v_qname"  .= defName (defAt ix (brV b))
  , "u_module" .= defModule (defAt ix (brU b))
  , "v_module" .= defModule (defAt ix (brV b))
  , "gap"      .= brGap b
  , "v2_u"     .= brV2U b
  , "v2_v"     .= brV2V b
  ]

hotspotJson :: (Text, Double) -> A.Value
hotspotJson (m, l2) = A.object
  [ "module"  .= m
  , "lambda2" .= l2
  ]

clusterJson :: Index -> Cluster -> A.Value
clusterJson ix c = A.object
  [ "signature" .= clSignature c
  , "size"      .= IS.size (clNodes c)
  , "modules"   .= [ A.object ["module" .= m, "count" .= n]
                   | (m, n) <- sortOn (Down . snd) (Map.toList (clModules c))
                   ]
  , "sample"    .= [ defName (defAt ix i)
                   | i <- take 5 (IS.toList (clNodes c))
                   ]
  ]

----------------------------------------------------------------------
-- Display helpers.

-- | Fixed-precision rendering to 3 decimals. Avoids dragging in
-- 'printf' for one function (matches the style elsewhere in
-- agda-optimization).
showD3 :: Double -> String
showD3 x =
  let n      = round (x * 1000) :: Integer
      sign   = if n < 0 then "-" else ""
      s      = show (abs n)
      padded = replicate (max 0 (4 - length s)) '0' ++ s
      (intP, fracP) = splitAt (length padded - 3) padded
  in sign ++ intP ++ "." ++ fracP
