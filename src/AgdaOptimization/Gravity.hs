{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Gravity — random-walk centrality + blast radius.
--
-- Combines three structural signals to surface the "silent connective
-- tissue" lemmas that load-bearing critical-path counts miss:
--
--   1. /Reverse PageRank/ on 'idxReverse' — each node's mass is how
--      much downward demand flows into it from /every/ theorem. Power
--      iteration with damping @d = 0.85@, capped at 'optIters' sweeps
--      and stopping early at L1 delta < 'optTolerance'.
--   2. /Personalized PageRank/ (PPR) with the teleport vector
--      concentrated on the chosen result set ('ResPublic' /
--      'ResTagged' / 'ResTerminals'). One PPR per theorem so the
--      per-def /row/ across theorems gives us the entropy signal
--      below.
--   3. /HITS/ authority + hub iteration on the original forward graph,
--      normalised at every step. Authorities tend to be primitive
--      sinks; hubs are orchestration lemmas.
--
-- Final rank: @gravity(v) = reversePR(v) * H(v)@ where @H@ is Shannon
-- entropy (in bits) of @v@'s PPR distribution across theorems. The
-- product surfaces nodes with both heavy structural mass /and/ broad
-- spread.
--
-- We compute one PPR per theorem (rather than a single batched PPR) so
-- that each node has a row across theorems to take entropy over. The
-- personalization seed count is capped at 'optTopTheorems'; if there
-- are more, we sample the heaviest by reverse-PageRank mass and warn
-- on stderr.
--
-- Orientation convention:
--   * 'idxForward' edges go user -> usee.
--   * Both the global "reverse PageRank" and the per-theorem PPR walk
--     /forward/ — mass starts at a theorem (or every node, for uniform
--     teleport) and flows toward its deep usees. The "reverse" label
--     refers to where mass ends up (deep utility lemmas that many
--     theorems reach through reverse-of-forward = ancestor chains),
--     not the iteration direction.
--   * In the power-iteration recurrence the /predecessors of v/ are
--     the nodes that have an edge pointing at v in the walked graph.
--     For a forward walk that's @rev[v]@ (nodes that depend on v).
--     The divisor @outDeg(u)@ is then the forward out-degree of @u@.
--
-- All hot-path vectors are 'Data.Vector.Unboxed' keyed by node id;
-- ragged per-source adjacencies are frozen once into
-- @Vector (U.Vector Int)@ so the power-loop inner kernel is tight.
--
-- Parallelism: per-theorem PPRs are independent, sparked across
-- theorems with @parListChunk 1 rdeepseq@; per-node entropy reduction
-- is sparked across nodes with @parListChunk 256 rdeepseq@. Per
-- repo convention (Strategies only, no Async).
module AgdaOptimization.Gravity
  ( Options(..)
  , ResultMode(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq              ( NFData(..) )
import           Control.Monad                ( when )
import           Control.Monad.ST             ( ST, runST )
import           Control.Parallel.Strategies  ( parListChunk, rdeepseq
                                              , withStrategy )
import qualified Data.IntMap.Strict           as IM
import           Data.IntMap.Strict           ( IntMap )
import qualified Data.Map.Strict              as Map
import qualified Data.IntSet                  as IS
import           Data.IntSet                  ( IntSet )
import           Data.List                    ( sortBy )
import           Data.Ord                     ( Down(..), comparing )
import           Data.Text                    ( Text )
import qualified Data.Text                    as T
import qualified Data.Vector                  as V
import qualified Data.Vector.Unboxed          as U
import qualified Data.Vector.Unboxed.Mutable  as MU
import           System.IO                    ( hPutStrLn, stderr )
import           Text.Printf                  ( printf )

import qualified Data.Aeson                   as A
import           Data.Aeson                   ( (.=) )

import           AgdaGraph.Index              ( Index(..), defAt )
import           AgdaGraph.Schema             ( Access(..), Definition(..)
                                              , State(..) )

import           AgdaOptimization.FlagSpec    ( FlagSpec(..), EnumErr(..)
                                              , parseFlags, applyFlagConfig )
import           AgdaOptimization.Common      ( isTagged, terminals )
import           AgdaOptimization.Report      ( GlobalOpts(..), OutFormat(..)
                                              , renderTable, emitJsonReport
                                              , withHumanOutput
                                              , withHumanReport )

------------------------------------------------------------------------
-- Public surface
------------------------------------------------------------------------

-- | Which seed set to use for personalization. Mirrors
-- 'AgdaOptimization.LoadBearing.Results' but spelled here so the
-- @gravity@ subcommand stays self-contained.
data ResultMode = ResPublic | ResTagged | ResTerminals
  deriving (Show, Eq)

data Options = Options
  { optDamping       :: !Double
    -- ^ Damping factor @d@ in the PageRank recurrence; default @0.85@.
  , optIters         :: !Int
    -- ^ Hard cap on power-iteration sweeps; default 50. Stops early
    -- when L1 delta < 'optTolerance'.
  , optTopN          :: !Int
    -- ^ Rows to emit in the human/JSON report.
  , optResults       :: !ResultMode
    -- ^ Seed mode for the PPR personalisation vectors.
  , optTolerance     :: !Double
    -- ^ Convergence threshold on the L1 delta between successive
    -- iterates. Default @1e-6@.
  , optTopTheorems   :: !Int
    -- ^ Maximum number of theorems we compute a per-theorem PPR for.
    -- When the seed set exceeds this, sample by reverse-PR mass and
    -- warn. Bounds total work at @k * optTopTheorems@ PR steps.
    -- Default 64.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optDamping     = 0.85
  , optIters       = 50
  , optTopN        = 50
  , optResults     = ResPublic
  , optTolerance   = 1e-6
  , optTopTheorems = 64
  }

parseRes :: String -> Either String ResultMode
parseRes "public"    = Right ResPublic
parseRes "tagged"    = Right ResTagged
parseRes "terminals" = Right ResTerminals
parseRes v           =
  Left ("expected one of public|tagged|terminals, got " <> show v)

-- | Declarative flag spec for the @gravity@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
--
-- @--results@ is an enum flag parsed by 'parseRes', whose @Left@ is a
-- bare @"expected one of …"@, surfaced verbatim on the argv side
-- ('EnumVerbatim').
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ DblFlag "damping" "--damping=F                          PageRank damping (default 0.85)"
      (\x o -> o { optDamping = x })
  , IntFlag "iters" "--iters=N                            max power-iteration steps (default 50)"
      (\n o -> o { optIters = n })
  , DblFlag "tolerance" "--tolerance=F                        L1-delta convergence (default 1e-6)"
      (\x o -> o { optTolerance = x })
  , IntFlag "top-n" "--top-n=N                            rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , EnumFlag "results" "--results=public|tagged|terminals    theorem-set source (default public)"
      parseRes EnumVerbatim (\r o -> o { optResults = r })
  , IntFlag "top-theorems" "--top-theorems=N                     PPR over top-N heaviest theorems (default 64)"
      (\n o -> o { optTopTheorems = n })
  ]

-- | Hand-rolled CLI parser for the @gravity@ subcommand. Same
-- per-subcommand dispatch shape as 'AgdaOptimization.Polyglot'.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "gravity" flagSpecs

-- | Overlay the @gravity:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "gravity" flagSpecs obj o0

------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------

-- | Public entry. Dispatched from 'AgdaOptimization.CLI'.
run :: Index -> GlobalOpts -> Options -> IO ()
run !ix !gOpts !opts@Options{..} = do
  let !n = idxNodeCount ix
  if n == 0
    then emitEmpty gOpts opts
    else do
      -- Freeze adjacency into ragged unboxed-int vectors once.
      let !fwd    = freezeAdj n (idxForward ix)
          !rev    = freezeAdj n (idxReverse ix)
          -- Out-degrees for the PageRank recurrence. We walk the
          -- /forward/ graph (mass at user -> usee), so the divisor
          -- @outDeg(u)@ in @cur[u] / outDeg(u)@ is the forward
          -- out-degree of @u@ (how many things @u@ depends on).
          !outFwd = U.generate n (U.length . (fwd V.!))

      -- (1) Reverse PageRank: mass flows along forward edges from
      --     theorems toward their deep usees. The recurrence
      --     @next[v] = Σ cur[u]/outDeg(u) for u ∈ preds(v)@ models a
      --     graph @G@ with edges @u -> v@ iff @u ∈ preds(v)@. With
      --     @preds(v) = rev[v]@ ("things that depend on v"), the
      --     implicit G has edges depender -> depended, i.e. the
      --     /forward/ Agda dep direction (user -> usee). Mass
      --     therefore concentrates at nodes many depend on = utility
      --     lemmas. Divisor @outFwd[u]@ = |things u depends on|.
      --     Uniform teleport.
      --
      --     The adjacency must be passed as @(rev, outFwd)@: with
      --     personalised teleport at a top-level theorem t (no incoming
      --     forward edges, so rev[t] empty), this lets PPR mass spread
      --     downward; the reversed orientation would pin all mass at t
      --     and collapse the cross-theorem entropy to 0.
      let (!rpr, !rprIters, !rprDelta) =
            powerIter opts (uniformTeleport n) rev outFwd

      -- (2) Theorem seed selection.
      let (!seeds0, !modeUsed, !mNote) = chooseSeeds ix optResults
      mapM_ (hPutStrLn stderr . ("[gravity] " ++)) mNote
      let !nSeeds = IS.size seeds0
          (theorems, sampleNote) =
            if nSeeds <= optTopTheorems
              then (IS.toAscList seeds0, [])
              else
                let ranked = sortBy (comparing (Down . (rpr U.!)))
                                    (IS.toList seeds0)
                    picked = take optTopTheorems ranked
                    note   = [ "seed set has " ++ show nSeeds
                             ++ " theorems; sampling top "
                             ++ show optTopTheorems
                             ++ " by reverse PageRank mass."
                             ]
                in (picked, note)
      mapM_ (hPutStrLn stderr . ("[gravity] " ++)) sampleNote
      let !kTh = length theorems

      -- (3) Per-theorem PPR. Each PPR is independent => spark.
      --     Same orientation as the global reverse PR above: walk
      --     forward (preds=rev, outDeg=outFwd) so mass starting at
      --     theorem @seed@ spreads to @seed@'s deep usees.
      let pprList :: [U.Vector Double]
          !pprList =
            withStrategy (parListChunk 1 rdeepseq) $
              map (\seed ->
                     let tel = pointTeleport n seed
                         (!v, _, _) = powerIter opts tel rev outFwd
                     in v)
                  theorems
          !pprMat = V.fromListN kTh pprList

      -- (4) HITS on forward graph (auth via reverse-adj, hub via
      --     forward-adj), L1-normalised each step.
      let (!auth, !hub) = hits opts fwd rev

      -- (5) Per-def H + non-zero-PPR count over the PPR matrix.
      --     'rNzTheorems' is a blast-radius proxy used when @H@
      --     collapses to ~0 (degenerate PPR; see fallback below).
      let perNode :: Int -> Row
          perNode !v =
            let !(h, !nz) = entropyAcrossNz pprMat v
                !g = (rpr U.! v) * h
            in Row v g (rpr U.! v) h nz (auth U.! v) (hub U.! v)
          !allRows =
            withStrategy (parListChunk 256 rdeepseq) $
              map perNode [0 .. n - 1]

      -- (5a) Entropy-collapse detection. Among nodes with positive
      --      reverse-PR mass (the candidates that could even rank),
      --      count what fraction have @H ~= 0@. If most do, the
      --      entropy signal is degenerate and we fall back to
      --      revPR * |non-zero-PPR-theorems| (a simple blast-radius
      --      proxy). Threshold 0.8 picked so a healthy corpus with a
      --      long tail of pinned leaves doesn't trip the fallback.
      let !candidates = filter ((> 0) . rMass) allRows
          !nCand      = length candidates
          !nCollapsed = length (filter ((< 1e-9) . rH) candidates)
          !collapseRatio
            | nCand == 0 = 0
            | otherwise  = fromIntegral nCollapsed / fromIntegral nCand
                             :: Double
          !fallbackActive = nCand > 0 && collapseRatio >= 0.8

      when fallbackActive $ do
        hPutStrLn stderr $
          "[gravity] WARNING: H(theorems) collapsed to 0 for "
          ++ printf "%.1f%%" (100 * collapseRatio)
          ++ " of candidates; PPR distribution too narrow at damping="
          ++ printf "%.2f" optDamping
          ++ "."
        hPutStrLn stderr
          "[gravity]          Falling back to rank-by revPR * |non-zero-PPR-theorems|."
        hPutStrLn stderr
          "[gravity]          Try a smaller damping (e.g. --damping=0.5) or more iters."

      let -- Ranking key. Default: gravity = revPR * H. Fallback:
          -- revPR * nzCount. Both are non-negative.
          rankKey :: Row -> Double
          rankKey r
            | fallbackActive = rMass r * fromIntegral (rNzTheorems r)
            | otherwise      = rGravity r
          !sorted  = sortBy (comparing (Down . rankKey)) allRows
          !topRows = take optTopN sorted

      case gOutFormat gOpts of
        OutJson ->
          emitJsonReport (gOutPath gOpts) $
            gravityJson ix opts modeUsed n kTh rprIters rprDelta
                        fallbackActive collapseRatio topRows
        OutHuman -> withHumanReport gOpts "gravity" $
          renderHuman ix opts modeUsed n kTh rprIters rprDelta
                      fallbackActive collapseRatio topRows

-- | Emit a valid empty-graph report so downstream tools don't choke.
emitEmpty :: GlobalOpts -> Options -> IO ()
emitEmpty gOpts opts = case gOutFormat gOpts of
  OutJson ->
    emitJsonReport (gOutPath gOpts) $ A.object
      [ "subcommand" .= ("gravity" :: Text)
      , "options"    .= gravityOptionsJson opts
      , "stats"      .= A.object
          [ "n_nodes"    .= (0 :: Int)
          , "n_theorems" .= (0 :: Int)
          , "rpr_iters"  .= (0 :: Int)
          , "rpr_delta"  .= (0 :: Double)
          ]
      , "rows" .= ([] :: [A.Value])
      ]
  OutHuman -> withHumanOutput (gOutPath gOpts) $
    putStrLn "# Gravity — empty graph (no nodes)"

------------------------------------------------------------------------
-- Adjacency freezing
------------------------------------------------------------------------

-- | Freeze an @IntMap IntSet@ adjacency into a dense
-- @Vector (U.Vector Int)@. Missing source ids get an empty vector. The
-- inner vectors are unboxed so the power-iteration inner loop is a
-- tight unboxed traversal.
freezeAdj :: Int -> IntMap IntSet -> V.Vector (U.Vector Int)
freezeAdj n adj =
  V.generate n $ \i ->
    case IM.lookup i adj of
      Nothing -> U.empty
      Just is -> U.fromList (IS.toAscList is)

------------------------------------------------------------------------
-- Power iteration
------------------------------------------------------------------------

-- | Personalization / teleport vector. Probabilities summing to 1.
type Teleport = U.Vector Double

-- | Uniform @1/N@ teleport — used by the global reverse PageRank.
uniformTeleport :: Int -> Teleport
uniformTeleport n
  | n <= 0    = U.empty
  | otherwise = U.replicate n (1 / fromIntegral n)

-- | Single-point teleport — used by personalised PPR. All mass on
-- one node; the recurrence spreads it through the graph.
pointTeleport :: Int -> Int -> Teleport
pointTeleport n i = U.generate n (\j -> if j == i then 1 else 0)

-- | Power-iteration core.
--
-- Recurrence:
--
-- @
--   next[v] = (1 - d) * tel[v]
--           + d * Σ_{u in preds(v)} cur[u] / outDeg(u)
--           + d * dangling_mass * tel[v]
-- @
--
-- where /preds(v)/ are the nodes that have an edge pointing /to v/ in
-- the adjacency we walk, /outDeg(u)/ is the size of that adjacency
-- row, and the dangling mass is the total rank of zero-out-degree
-- nodes. We redistribute dangling mass through the TELEPORT vector
-- (uniform PR collapses to the textbook @+ d * dangling / N@ since
-- @tel[v] = 1/N@; PPR routes dangling mass back to the seed, which is
-- the correct personalised behaviour — see Jeh & Widom 2003 §3).
--
-- We pass the adjacency we /walk in the inner loop/ as the @preds@
-- argument. For a forward walk (user -> usee), @preds(v) = rev[v]@
-- (the users of @v@), and @outDeg(u) = |fwd[u]|@ (forward
-- out-degree, i.e. how many things @u@ depends on).
powerIter
  :: Options
  -> Teleport                   -- ^ (1-d) * tel[v] component.
  -> V.Vector (U.Vector Int)    -- ^ For each v, list of preds(v).
  -> U.Vector Int               -- ^ outDeg(u) for u in [0..N).
  -> (U.Vector Double, Int, Double)
        -- ^ (final rank, iters used, last L1 delta)
powerIter Options{..} tel preds outDeg
  | n == 0    = (U.empty, 0, 0)
  | otherwise = runST $ do
      cur <- U.thaw tel  -- initial guess = teleport vector
      -- Dangling node ids (outDeg = 0) are invariant across iterations;
      -- compute them once (ascending v) instead of rescanning all N nodes
      -- every iteration. Summation order is unchanged, so the Double
      -- dangling mass is bit-identical.
      let !danglingIds = U.fromList [ v | v <- [0 .. n - 1], outDeg U.! v == 0 ]
          !nDangling   = U.length danglingIds
      let loop !it = do
            -- Dangling mass: total cur[v] over the precomputed dangling set.
            let danglingAcc !acc !i
                  | i >= nDangling = pure acc
                  | otherwise = do
                      x <- MU.read cur (danglingIds U.! i)
                      danglingAcc (acc + x) (i + 1)
            !dangling <- danglingAcc 0 0
            let !danglingScale = optDamping * dangling
            -- Build next[]; we use a fresh mutable then swap.
            next <- MU.new n
            let oneNode !v
                  | v >= n = pure ()
                  | otherwise = do
                      let !row    = preds V.! v
                          !len    = U.length row
                          !telV   = tel U.! v
                          !tlv    = (1 - optDamping) * telV
                          !redist = danglingScale * telV
                      let inner !acc !i
                            | i >= len = pure acc
                            | otherwise = do
                                let !u = row U.! i
                                    !d = outDeg U.! u
                                if d <= 0
                                  then inner acc (i + 1)
                                  else do
                                    xu <- MU.read cur u
                                    inner (acc + xu / fromIntegral d) (i + 1)
                      !s <- inner 0 0
                      MU.write next v $! tlv + optDamping * s + redist
                      oneNode (v + 1)
            oneNode 0
            -- L1 delta + copy next into cur in one pass.
            let deltaAcc !acc !v
                  | v >= n = pure acc
                  | otherwise = do
                      a <- MU.read cur v
                      b <- MU.read next v
                      MU.write cur v b
                      deltaAcc (acc + abs (a - b)) (v + 1)
            !delta <- deltaAcc 0 0
            if delta < optTolerance || it + 1 >= optIters
              then do
                !frozen <- U.freeze cur
                pure (frozen, it + 1, delta)
              else loop (it + 1)
      loop 0
  where
    !n = U.length tel

------------------------------------------------------------------------
-- HITS
------------------------------------------------------------------------

-- | HITS authority + hub scores on the forward graph.
--
-- Update rule (per step, then L1-normalise each):
--
-- @
--   auth'[v] = Σ_{u : u -> v} hub[u]   = Σ_{u in revNbrs(v)} hub[u]
--   hub'[v]  = Σ_{w : v -> w} auth[w]  = Σ_{w in fwdNbrs(v)} auth[w]
-- @
--
-- Same iter cap / tolerance as the rest of the analysis. The returned
-- vectors are L1-normalised.
hits
  :: Options
  -> V.Vector (U.Vector Int)   -- ^ forward adjacency (v -> ws)
  -> V.Vector (U.Vector Int)   -- ^ reverse adjacency (v -> us where u->v)
  -> (U.Vector Double, U.Vector Double)
hits Options{..} fwd rev
  | n == 0    = (U.empty, U.empty)
  | otherwise = runST $ do
      auth <- MU.replicate n (1 / fromIntegral n)
      hub  <- MU.replicate n (1 / fromIntegral n)
      let loop !it = do
            -- auth'[v] = Σ hub[u] for u in revNbrs(v).
            newAuth <- MU.new n
            let stepAuth !v
                  | v >= n = pure ()
                  | otherwise = do
                      let !row = rev V.! v
                          !len = U.length row
                          inner !acc !i
                            | i >= len = pure acc
                            | otherwise = do
                                let !u = row U.! i
                                hu <- MU.read hub u
                                inner (acc + hu) (i + 1)
                      !s <- inner 0 0
                      MU.write newAuth v s
                      stepAuth (v + 1)
            stepAuth 0
            -- hub'[v] = Σ auth'[w] for w in fwdNbrs(v).
            newHub <- MU.new n
            let stepHub !v
                  | v >= n = pure ()
                  | otherwise = do
                      let !row = fwd V.! v
                          !len = U.length row
                          inner !acc !i
                            | i >= len = pure acc
                            | otherwise = do
                                let !w = row U.! i
                                aw <- MU.read newAuth w
                                inner (acc + aw) (i + 1)
                      !s <- inner 0 0
                      MU.write newHub v s
                      stepHub (v + 1)
            stepHub 0
            l1Normalise newAuth
            l1Normalise newHub
            -- Compute deltas and swap.
            !da <- l1DeltaAndCopy auth newAuth
            !db <- l1DeltaAndCopy hub  newHub
            let !delta = da + db
            if delta < optTolerance || it + 1 >= optIters
              then do
                !af <- U.freeze auth
                !hf <- U.freeze hub
                pure (af, hf)
              else loop (it + 1)
      loop 0
  where
    !n = V.length fwd

-- | L1-normalise an MUtable vector in place. Zero-sum is left alone
-- (would otherwise NaN); HITS on any graph with at least one edge has
-- positive sum after one step.
l1Normalise :: MU.MVector s Double -> ST s ()
l1Normalise v = do
  let !n = MU.length v
      acc !s !i
        | i >= n    = pure s
        | otherwise = do
            x <- MU.read v i
            acc (s + abs x) (i + 1)
  !s <- acc 0 0
  when (s > 0) $ do
    let scale !i
          | i >= n    = pure ()
          | otherwise = do
              x <- MU.read v i
              MU.write v i (x / s)
              scale (i + 1)
    scale 0

-- | Compute L1 difference between @dst@ (current) and @src@ (next),
-- then copy @src@ into @dst@. Advances HITS and checks convergence in
-- one pass.
l1DeltaAndCopy :: MU.MVector s Double
               -> MU.MVector s Double
               -> ST s Double
l1DeltaAndCopy dst src = do
  let !n = MU.length dst
      go !acc !i
        | i >= n    = pure acc
        | otherwise = do
            a <- MU.read dst i
            b <- MU.read src i
            MU.write dst i b
            go (acc + abs (a - b)) (i + 1)
  go 0 0

------------------------------------------------------------------------
-- Entropy
------------------------------------------------------------------------

-- | Shannon entropy in bits /and/ the count of theorems with
-- strictly-positive PPR mass at node @v@.
--
-- We treat each per-theorem PPR vector as a column; for node v, the
-- "row" is the kTh-length vector @[pprMat[t][v] | t <- theorems]@.
-- After L1-normalising the row, H is @-Σ p log2 p@ over the kTh
-- entries. An empty or zero-sum row yields @(0, 0)@.
--
-- Returns @(H, nz)@ where @nz@ is the count of columns with
-- @col[v] > 0@. The count is the blast-radius proxy used by the
-- entropy-collapse fallback; it's computed in the same single fold as
-- @H@ so we never touch the matrix twice.
entropyAcrossNz :: V.Vector (U.Vector Double) -> Int -> (Double, Int)
entropyAcrossNz pprMat v
  | k == 0    = (0, 0)
  | otherwise =
      let -- One pass: total, plus contribution to log-sum (we use
          -- @x * log x@ and re-normalise at the end via:
          -- @H = log(total) - (Σ x log x) / total@, in bits).
          -- This avoids a second pass over the matrix.
          step (!tot, !sxlx, !nz) col =
            let !x = col U.! v
            in if x > 0
                 then (tot + x, sxlx + x * log x, nz + 1)
                 else (tot, sxlx, nz)
          (!total, !sxlogx, !nzCount) =
            V.foldl' step (0 :: Double, 0 :: Double, 0 :: Int) pprMat
      in if total <= 0
           then (0, 0)
           else
             let !logBase2 = log 2
                 -- H = -Σ p log p where p = x/total.
                 -- = -(1/total) Σ x (log x - log total)
                 -- = log(total) - (Σ x log x) / total, in nats.
                 !hNats = log total - sxlogx / total
                 !h     = hNats / logBase2
             -- Numerical floor: clamp tiny negatives from FP noise.
             in (if h < 0 then 0 else h, nzCount)
  where
    !k = V.length pprMat

------------------------------------------------------------------------
-- Seed selection
------------------------------------------------------------------------

-- | Pick the personalisation seed set. Falls back to 'ResTerminals'
-- on an empty primary set so the report still has rows.
chooseSeeds :: Index -> ResultMode -> (IntSet, ResultMode, [String])
chooseSeeds !ix !mode =
  let primary = pickSeeds ix mode
  in if IS.null primary
       then let !fall = pickSeeds ix ResTerminals
                note  = [ "no seeds for results=" ++ resultsLabel mode
                          ++ "; falling back to results=terminals "
                          ++ "(|S| = " ++ show (IS.size fall) ++ ")."
                        ]
            in (fall, ResTerminals, note)
       else (primary, mode, [])

pickSeeds :: Index -> ResultMode -> IntSet
pickSeeds !ix = \case
  ResTagged ->
    IS.fromList
      [ defId d
      | d <- V.toList (idxDefs ix)
      , isTagged (defName d)
      ]
  ResPublic ->
    -- Approximate "public theorems" = Public defs in the entry module
    -- (heuristic: the module with the most Public defs). Falls back
    -- to all Public Defined defs if the heuristic finds nothing.
    let defs       = V.toList (idxDefs ix)
        entryGuess = guessEntryModule defs
        keep d     = defAccess d == Public
                  && defState  d == Defined
                  && maybe True (== defModule d) entryGuess
        seeds      = IS.fromList [ defId d | d <- defs, keep d ]
    in if IS.null seeds
         then IS.fromList [ defId d
                          | d <- defs
                          , defAccess d == Public
                          , defState d == Defined
                          ]
         else seeds
  ResTerminals ->
    -- Terminals = nothing uses them (no incoming edges = empty reverse
    -- adjacency at that id).
    terminals ix

-- | Module with the largest number of Public defs (matching the
-- LoadBearing heuristic). Tie-break by shortest module-name length.
guessEntryModule :: [Definition] -> Maybe Text
guessEntryModule defs =
  let pubs   = [ defModule d | d <- defs, defAccess d == Public ]
      counts = Map.toList (foldl' (\m k -> Map.insertWith (+) k 1 m) Map.empty pubs)
      -- Total ordering (count desc, then name length, then name) so the
      -- winner is independent of input order — no accidental reliance on
      -- the def vector's traversal order in a tie.
      ranked = sortBy (comparing (\(m, c) -> (Down c, T.length m, m))) counts
  in case ranked of
       []        -> Nothing
       ((m,_):_) -> Just m


------------------------------------------------------------------------
-- Output
------------------------------------------------------------------------

-- | One row of the gravity table.
data Row = Row
  { rNodeId     :: !Int
  , rGravity    :: !Double   -- ^ reversePR(v) * H(v)
  , rMass       :: !Double   -- ^ reverse PageRank
  , rH          :: !Double   -- ^ Shannon entropy across theorems, bits
  , rNzTheorems :: !Int      -- ^ #theorems with strictly-positive PPR
                             -- at this node — coarse blast-radius
                             -- proxy used when H collapses.
  , rAuth       :: !Double   -- ^ HITS authority
  , rHub        :: !Double   -- ^ HITS hub
  }

-- | All Row fields are already strict Doubles/Int, so rnf just nudges
-- each into WHNF. Needed because we spark per-node Row construction.
instance NFData Row where
  rnf (Row a b c d e f g) =
    a `seq` b `seq` c `seq` d `seq` e `seq` f `seq` g `seq` ()

renderHuman
  :: Index -> Options -> ResultMode
  -> Int    -- ^ Node count.
  -> Int    -- ^ Theorem count actually used.
  -> Int    -- ^ Reverse-PR iters used.
  -> Double -- ^ Reverse-PR final delta.
  -> Bool   -- ^ Fallback active? (entropy collapsed).
  -> Double -- ^ Collapse ratio (0..1).
  -> [Row]
  -> IO ()
renderHuman ix Options{..} modeUsed n kTh rprIters rprDelta
            fallback collapseRatio rows = do
  putStrLn $ "# Gravity — top " ++ show optTopN
          ++ " (results: " ++ resultsLabel modeUsed
          ++ ", damping=" ++ printf "%.2f" optDamping
          ++ ", iters<=" ++ show optIters ++ ")"
  putStrLn $ "|V| = " ++ show n
          ++ ", |theorems| = " ++ show kTh
          ++ ", revPR iters = " ++ show rprIters
          ++ ", revPR delta = " ++ printf "%.2e" rprDelta
  when fallback $ do
    putStrLn $ "# H(theorems) collapsed to ~0 for "
            ++ printf "%.1f%%" (100 * collapseRatio)
            ++ " of candidates — ranking by revPR * |non-zero-PPR-theorems|."
  putStrLn ""
  let header = ["Rank","Gravity","Mass","H(theorems)","nzTh","Auth","Hub"
               ,"Role","QName","Module","State"]
      mkRow !r !i =
        let d    = defAt ix (rNodeId r)
            role = decideRole r
        in [ show i
           , showFixed4 (rGravity r)
           , showFixed4 (rMass    r)
           , showFixed3 (rH       r) ++ " bits"
           , show (rNzTheorems r) ++ "/" ++ show kTh
           , showFixed4 (rAuth    r)
           , showFixed4 (rHub     r)
           , role
           , T.unpack (defName d)
           , T.unpack (defModule d)
           , stateLetter (defState d)
           ]
      table = zipWith mkRow rows [(1::Int)..]
  if null rows
    then putStrLn "no gravity candidates (empty graph or empty seed set)"
    else putStr (renderTable header table)

-- | Authority vs hub call. Tied -> authority because the spec's
-- "silent connective tissue" target is the primary use case.
decideRole :: Row -> String
decideRole r
  | rAuth r >= rHub r = "authority"
  | otherwise         = "hub"

------------------------------------------------------------------------
-- JSON
------------------------------------------------------------------------

gravityJson
  :: Index -> Options -> ResultMode
  -> Int -> Int -> Int -> Double
  -> Bool   -- ^ Fallback active?
  -> Double -- ^ Collapse ratio (0..1).
  -> [Row]
  -> A.Value
gravityJson ix opts modeUsed n kTh rprIters rprDelta
            fallback collapseRatio rows =
  A.object
    [ "subcommand"        .= ("gravity" :: Text)
    , "options"           .= gravityOptionsJson opts
    , "results_mode_used" .= resultsLabel modeUsed
    , "stats"             .= A.object
        [ "n_nodes"          .= n
        , "n_theorems"       .= kTh
        , "rpr_iters"        .= rprIters
        , "rpr_delta"        .= rprDelta
        , "fallback_active"  .= fallback
        , "collapse_ratio"   .= collapseRatio
        ]
    , "rows" .= A.toJSON (zipWith (gravityRowJson ix kTh) [1::Int ..] rows)
    ]

gravityOptionsJson :: Options -> A.Value
gravityOptionsJson Options{..} = A.object
  [ "damping"      .= optDamping
  , "iters"        .= optIters
  , "top_n"        .= optTopN
  , "results"      .= resultsLabel optResults
  , "tolerance"    .= optTolerance
  , "top_theorems" .= optTopTheorems
  ]

gravityRowJson :: Index -> Int -> Int -> Row -> A.Value
gravityRowJson ix kTh rank r =
  let d = defAt ix (rNodeId r)
  in A.object
       [ "rank"        .= rank
       , "qname"       .= defName d
       , "module"      .= defModule d
       , "state"       .= stateLetter (defState d)
       , "gravity"     .= rGravity r
       , "mass"        .= rMass    r
       , "h_bits"      .= rH       r
       , "nz_theorems" .= rNzTheorems r
       , "k_theorems"  .= kTh
       , "auth"        .= rAuth    r
       , "hub"         .= rHub     r
       , "role"        .= decideRole r
       ]

------------------------------------------------------------------------
-- Tiny formatting helpers
------------------------------------------------------------------------

showFixed3 :: Double -> String
showFixed3 = printf "%.3f"

showFixed4 :: Double -> String
showFixed4 = printf "%.4f"

resultsLabel :: ResultMode -> String
resultsLabel = \case
  ResPublic    -> "public"
  ResTagged    -> "tagged"
  ResTerminals -> "terminals"

stateLetter :: State -> String
stateLetter = \case
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"

