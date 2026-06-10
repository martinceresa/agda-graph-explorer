{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Pyre — typecheck-cost prediction via graph-only proxies.
--
-- Per definition @d@ we approximate the elaborator's cost of checking
-- @d@ as a weighted sum of four graph-structural features evaluated on
-- the SCC condensation of the dependency graph:
--
-- @
-- C(d) = w1 * |reach⁺(d)|
--      + w2 * Σ_{c ∈ reach⁺(d)} fanIn(c) * fanOut(c)
--      + w3 * Σ_{c ∈ reach⁺(d)} wKind(c)
--      + w4 * depthRank(d)
-- @
--
-- where:
--
--   * @reach⁺(d)@ is the forward transitive closure on the
--     /condensation/ (every SCC counts once, regardless of internal
--     size — this is intentionally a structural proxy, not a node
--     count).
--   * @fanIn / fanOut@ are taken on the condensation too.
--   * @wKind@ approximates per-construct unfolding cost (record /
--     datatype heavy, postulate / primitive zero).
--   * @depthRank(d)@ is the position of @d@'s SCC in a longest-path
--     reverse-topological ranking, normalised to @[0, 1]@.
--
-- The graph is materialised as an SCC condensation because the real
-- corpus contains cycles (datatype <-> constructor self-references);
-- see 'AgdaOptimization.LoadBearing' for the same machinery and the
-- gotcha that motivated it.
--
-- Reach sets are computed exactly via reverse-topo @IntSet@ merging.
-- For a typical reference-corpus-sized project (~4500 SCCs) this peaks around
-- a dozen MB of resident state and finishes in a single linear pass.
--
-- == Typecheck-profile analyzer (@--profile=PATH@)
--
-- The graph-only score above is a /relative ranking/, not a wall-clock
-- estimate. @--profile=PATH@ ingests a JSON profile of observed
-- per-definition typecheck cost (derived from @agda --profile=*@; see
-- 'parseProfile' for the accepted shapes), joins it to the graph by
-- qname, and reports:
--
--   * coverage (how many real defs were matched);
--   * Spearman rank-correlation between the model score and the
--     observed cost — i.e. /does the proxy track reality/;
--   * ridge-regression-fitted weights @(w1..w4, intercept)@ over the
--     same four features, plus the post-fit Spearman ρ.
--
-- With @--calibrate@ the fitted weights replace the defaults for the
-- ranking itself; to /cache/ them across runs, copy the printed values
-- into the @pyre:@ section of @.agda-optimization.yml@ (the existing
-- config layer — no separate calibration store).
--
-- == Lever detector (@--levers@)
--
-- The main table ranks by @C(d)@ — the cost of checking @d@, dominated
-- by deep/wide results. The /lever/ table answers the dual question:
-- /which definition, if made cheaper, would cut the most aggregate
-- cost across everything that depends on it?/ For each node @x@ we
-- attribute its per-dependent cost contribution to every definition
-- that reaches it:
--
-- @
-- lever(x) = nodeReachers(x) * selfUnit(x)
-- @
--
-- where @nodeReachers(x)@ is the count of definitions whose
-- @reach⁺@ contains @x@ (reverse-reach on the condensation, weighted
-- by SCC member count) and @selfUnit(x)@ is @x@'s own per-reacher cost
-- — the modeled @w1 + w2·fanProd(x) + w3·kindSum(x)@, or the /observed/
-- self-time when @--profile@ is supplied. This is an attribution, not
-- an exact counterfactual: it assumes only @x@ leaves the reach sets,
-- not the descendants @x@ might have been the sole path to (cf.
-- 'AgdaOptimization.LoadBearing''s masked-recompute perturbation Δ).
module AgdaOptimization.Pyre
  ( Options(..)
  , defaultOptions
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.DeepSeq             ( NFData(..) )
import           Control.Exception           ( IOException, try )
import           Control.Monad               ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import qualified Data.ByteString             as BS
import           AgdaOptimization.Condense   ( Condensation(..), buildCondensation )
import           Data.Foldable               ( foldl' )
import qualified Data.HashMap.Strict         as HM
import qualified Data.IntMap.Strict          as IM
import qualified Data.IntSet                 as IS
import           Data.List                   ( sortBy )
import           Data.Maybe                  ( fromMaybe )
import           Data.Ord                    ( Down(..), comparing )
import           Data.Text                   ( Text )
import qualified Data.Text                   as T
import qualified Data.Vector                 as V
import           System.Exit                 ( exitFailure )
import           System.IO                   ( hPutStrLn, stderr )

import qualified Data.Aeson                  as A
import           Data.Aeson                  ( (.=) )
import qualified Data.Aeson.Key              as K
import qualified Data.Aeson.KeyMap           as KM

import           AgdaGraph.Index             ( Index(..), defAt )
import           AgdaGraph.Schema            ( Definition(..), Kind(..)
                                             , State(..) )
import           AgdaOptimization.CLIParse   ( splitFlag, valueFor
                                             , readInt, readDbl )
import           AgdaOptimization.Common     ( computeExcludedSet )
import           AgdaOptimization.Config     ( lookupKey )
import           AgdaOptimization.Report     ( GlobalOpts(..), OutFormat(..)
                                             , emitJsonReport, renderTable
                                             , withHumanOutput )

------------------------------------------------------------------------
-- Public surface
------------------------------------------------------------------------

-- | Pyre-specific configuration. All four weights are flag-tunable so
-- callers can sweep the cost model without recompiling.
data Options = Options
  { optTopN              :: !Int     -- ^ Rows to print. Default 50.
  , optW1                :: !Double  -- ^ Reach weight. Default 1.0.
  , optW2                :: !Double  -- ^ fanIn*fanOut weight. Default 0.5.
  , optW3                :: !Double  -- ^ Kind weight. Default 2.0.
  , optW4                :: !Double  -- ^ depthRank weight. Default 10.0.
  , optExcludeNameRegex  :: !Text
    -- ^ POSIX-ERE matched against the unqualified (last
    -- dot-component) name of each definition. Matching nodes are
    -- removed from the candidate pool BEFORE ranking. Empty string =
    -- no exclusion. Mirrors 'AgdaOptimization.LoadBearing'.
  , optProfilePath       :: !(Maybe FilePath)
    -- ^ @--profile=PATH@: JSON profile of observed per-definition
    -- typecheck cost (qname -> number). Enables the calibration
    -- report. 'Nothing' = graph-only ranking (the default).
  , optCalibrate         :: !Bool
    -- ^ @--calibrate@: replace @w1..w4@ with the ridge-fitted weights
    -- for the actual ranking. Requires 'optProfilePath'. Default off
    -- (profile is report-only).
  , optRidgeLambda       :: !Double
    -- ^ @--ridge-lambda=F@: L2 regularisation added to the four
    -- feature diagonals of the normal matrix (the intercept is left
    -- unregularised). @> 0@ also guarantees the 5x5 solve is
    -- non-singular. Default 1.0.
  , optLevers            :: !Bool
    -- ^ @--levers@: emit the lever table (aggregate downstream cost
    -- attribution). Default off.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optTopN             = 50
  , optW1               = 1.0
  , optW2               = 0.5
  , optW3               = 2.0
  , optW4               = 10.0
  , optExcludeNameRegex = T.empty
  , optProfilePath      = Nothing
  , optCalibrate        = False
  , optRidgeLambda      = 1.0
  , optLevers           = False
  }

-- | Hand-rolled CLI parser for @pyre@. Same shape as the other
-- subcommands (see 'AgdaOptimization.LoadBearing.parseOptions').
parseOptions :: Options -> [String] -> Either String Options
parseOptions = go
  where
    sub = "pyre"
    intK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      n         <- readInt sub k v
      go (upd o n) rest
    dblK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      x         <- readDbl sub k v
      go (upd o x) rest
    textK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      go (upd o (T.pack v)) rest
    pathK k upd mv as o = do
      (v, rest) <- valueFor sub k mv as
      go (upd o (Just v)) rest

    go :: Options -> [String] -> Either String Options
    go !o []     = Right o
    go !o (a:as) = case splitFlag a of
      Left err                    -> Left (sub <> ": " <> err)
      Right ("--top-n", mv)       -> intK  "--top-n" (\o' n -> o' { optTopN = n }) mv as o
      Right ("--w1",    mv)       -> dblK  "--w1"    (\o' x -> o' { optW1   = x }) mv as o
      Right ("--w2",    mv)       -> dblK  "--w2"    (\o' x -> o' { optW2   = x }) mv as o
      Right ("--w3",    mv)       -> dblK  "--w3"    (\o' x -> o' { optW3   = x }) mv as o
      Right ("--w4",    mv)       -> dblK  "--w4"    (\o' x -> o' { optW4   = x }) mv as o
      Right ("--exclude-name-regex", mv) ->
        textK "--exclude-name-regex"
              (\o' p -> o' { optExcludeNameRegex = p }) mv as o
      Right ("--profile", mv)     -> pathK "--profile"
                                       (\o' p -> o' { optProfilePath = p }) mv as o
      Right ("--ridge-lambda", mv) -> dblK "--ridge-lambda"
                                       (\o' x -> o' { optRidgeLambda = x }) mv as o
      Right ("--calibrate", _)    -> go (o { optCalibrate = True }) as
      Right ("--levers", _)       -> go (o { optLevers     = True }) as
      Right (k, _)                -> Left (sub <> ": unknown flag: " <> k)

-- | Overlay the @pyre:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = do
  o1 <- updI "top-n" (\v o -> o { optTopN = v }) o0
  o2 <- updD "w1"    (\v o -> o { optW1   = v }) o1
  o3 <- updD "w2"    (\v o -> o { optW2   = v }) o2
  o4 <- updD "w3"    (\v o -> o { optW3   = v }) o3
  o5 <- updD "w4"    (\v o -> o { optW4   = v }) o4
  o6 <- updT "exclude-name-regex"
                     (\v o -> o { optExcludeNameRegex = v }) o5
  o7 <- updS "profile"      (\v o -> o { optProfilePath = Just v }) o6
  o8 <- updD "ridge-lambda" (\v o -> o { optRidgeLambda = v }) o7
  o9 <- updB "calibrate"    (\v o -> o { optCalibrate   = v }) o8
  oA <- updB "levers"       (\v o -> o { optLevers      = v }) o9
  pure oA
  where
    section = "pyre"
    updI k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe Int)
      pure $ maybe o (`f` o) mv
    updD k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe Double)
      pure $ maybe o (`f` o) mv
    updT k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe Text)
      pure $ maybe o (`f` o) mv
    updS k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe FilePath)
      pure $ maybe o (`f` o) mv
    updB k f o = do
      mv <- lookupKey section obj k :: Either String (Maybe Bool)
      pure $ maybe o (`f` o) mv

------------------------------------------------------------------------
-- SCC condensation (same shape as LoadBearing's; kept private here to
-- avoid coupling the two modules)
------------------------------------------------------------------------

-- 'Condensation' + 'buildCondensation' moved to "AgdaOptimization.Condense".

------------------------------------------------------------------------
-- Per-SCC primitives: kind aggregation, fanIn*fanOut, reach sets,
-- depthRank.
------------------------------------------------------------------------

-- | Approximate per-construct unfolding cost. Matches the spec's
-- table verbatim:
--
-- @
-- KRecord=6, KDatatype=4, KProjection=3, KFunction=2,
-- KConstructor=1, KOther=1, KPostulate=0, KPrimitive=0
-- @
--
-- The rationale is that records and datatypes carry the bulk of
-- unfolding work; postulates and primitives are terminal and
-- contribute nothing to elaboration.
wKindOf :: Kind -> Int
wKindOf KRecord      = 6
wKindOf KDatatype    = 4
wKindOf KProjection  = 3
wKindOf KFunction    = 2
wKindOf KConstructor = 1
wKindOf KOther       = 1
wKindOf KPostulate   = 0
wKindOf KPrimitive   = 0

-- | Aggregate @wKind@ over the original nodes that landed in each SCC.
-- A multi-node SCC contributes the sum of its members' kind weights —
-- this preserves the "cost of unfolding the whole SCC" intuition when
-- a record / datatype is cyclically tied to its constructors.
kindSumPerSCC :: Index -> Condensation -> IM.IntMap Int
kindSumPerSCC !ix !cond =
  IM.foldlWithKey'
    (\ !acc scc mems ->
       let !s = IS.foldl' (\ !n v ->
                             n + wKindOf (defKind (defAt ix v))) 0 mems
       in IM.insert scc s acc)
    IM.empty (cdMembers cond)

-- | Pre-compute @fanIn(c) * fanOut(c)@ on the condensation per SCC.
fanProductPerSCC :: Condensation -> IM.IntMap Int
fanProductPerSCC !cond =
  let allSccs = cdTopo cond
      sizeAt m k = IS.size (IM.findWithDefault IS.empty k m)
      fwd = cdForward cond
      rev = cdReverse cond
  in foldl'
       (\ !acc s ->
          let !fo = sizeAt fwd s
              !fi = sizeAt rev s
          in IM.insert s (fi * fo) acc)
       IM.empty
       allSccs

-- | Reverse-topo accumulation of exact forward-reach sets on the
-- condensation. @reachSet[v]@ is @{v}@ ∪ ⋃ children's reach sets.
--
-- Memory: O(|SCCs|² / w) worst case.
reachSetsPerSCC :: Condensation -> IM.IntMap IS.IntSet
reachSetsPerSCC !cond =
  -- Walk SCCs in REVERSE topo order (sinks first). Each child's
  -- reach set is already populated by the time we visit a parent.
  foldl' step IM.empty (reverse (cdTopo cond))
  where
    fwd = cdForward cond
    step !acc s =
      let kids = IM.findWithDefault IS.empty s fwd
          !merged =
            IS.foldl'
              (\ !r k ->
                 IS.union r (IM.findWithDefault IS.empty k acc))
              IS.empty kids
          !full = IS.insert s merged
      in IM.insert s full acc

-- | Longest-path-from-any-sink rank per SCC. A sink has rank 0; a
-- non-sink gets @1 + max(child rank)@.
--
-- Operates on the DAG condensation so there is no cycle handling to
-- worry about. Caller normalises to @[0, 1]@.
depthRankSCC :: Condensation -> IM.IntMap Int
depthRankSCC !cond =
  let rev = reverse (cdTopo cond)  -- sinks first
      fwd = cdForward cond
      step !acc s =
        let kids = IM.findWithDefault IS.empty s fwd
        in if IS.null kids
             then IM.insert s 0 acc
             else let !best = IS.foldl'
                                (\ !m k ->
                                   max m (IM.findWithDefault 0 k acc + 1))
                                0
                                kids
                  in IM.insert s best acc
  in foldl' step IM.empty rev

------------------------------------------------------------------------
-- Scoring
------------------------------------------------------------------------

-- | Per-SCC score (computed once, then projected onto member nodes).
-- All four components are evaluated on the condensation, so a
-- multi-node SCC inherits a single score for every member — this is
-- the intended semantic (reach is structurally identical for any
-- member of an SCC).
data SccScore = SccScore
  { sccReach   :: !Int      -- ^ |reach⁺(s)| including s itself (see note).
  , sccFanProd :: !Int      -- ^ Σ_{c ∈ reach⁺(s)} fanIn(c)*fanOut(c).
  , sccKindSum :: !Int      -- ^ Σ_{c ∈ reach⁺(s)} wKind(c).
  , sccDepth   :: !Int      -- ^ Raw depth rank (un-normalised).
  , sccScore   :: !Double   -- ^ Final composite C(s).
  } deriving (Show)

-- All fields are strict and primitive — WHNF coincides with NF, so
-- 'rdeepseq' on a 'SccScore' is equivalent to a single 'seq'. Kept
-- explicit so 'parMap rdeepseq' in 'scoreSCCs' has a witness.
instance NFData SccScore where
  rnf (SccScore a b c d e) =
        rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e

-- Note on reach inclusion: the spec writes @reach⁺(d)@. We include
-- the SCC itself in the reach set because (a) the kind-sum and
-- fan-product contributions of the def itself genuinely matter to
-- elaboration cost, and (b) it keeps the formulas tidy. This is the
-- same convention used by 'AgdaGraph.Index' callers elsewhere.

-- | Compute every SCC's score independently. The per-SCC work is
-- O(|reach⁺(s)|); we shard across SCCs using @parMap rdeepseq@ so
-- the work parallelises cleanly when the binary is run with
-- @+RTS -N@.
scoreSCCs
  :: Options
  -> Condensation
  -> IM.IntMap IS.IntSet    -- ^ reach sets per SCC (incl. self)
  -> IM.IntMap Int          -- ^ fanIn*fanOut per SCC
  -> IM.IntMap Int          -- ^ kind sum per SCC
  -> IM.IntMap Int          -- ^ raw depth rank per SCC
  -> Int                    -- ^ max depth (for normalisation)
  -> IM.IntMap SccScore
scoreSCCs !opts !cond !reach !fanProd !kindSum !depth !dMax =
  let sccs    = cdTopo cond
      !denom  = if dMax <= 0 then 1.0 else fromIntegral dMax :: Double
      scoreOne s =
        let !rs        = IM.findWithDefault IS.empty s reach
            !reachSize = IS.size rs
            !fp        = IS.foldl'
                           (\ !n c ->
                              n + IM.findWithDefault 0 c fanProd)
                           0 rs
            !ks        = IS.foldl'
                           (\ !n c ->
                              n + IM.findWithDefault 0 c kindSum)
                           0 rs
            !dr        = IM.findWithDefault 0 s depth
            !drNorm    = fromIntegral dr / denom :: Double
            !sc        = optW1 opts * fromIntegral reachSize
                       + optW2 opts * fromIntegral fp
                       + optW3 opts * fromIntegral ks
                       + optW4 opts * drNorm
        in (s, SccScore
                 { sccReach   = reachSize
                 , sccFanProd = fp
                 , sccKindSum = ks
                 , sccDepth   = dr
                 , sccScore   = sc
                 })
      !scored = parMap rdeepseq scoreOne sccs
  in IM.fromList scored

------------------------------------------------------------------------
-- Lever detection: aggregate downstream cost attribution.
--
-- The cost table ranks @C(d)@ — the price of checking @d@. The lever
-- table ranks the dual: how much aggregate cost is attributable to a
-- single node @x@ across everything that reaches it. See the module
-- haddock for the closed form and its (deliberate) approximation.
------------------------------------------------------------------------

-- | Per-SCC reverse-reach sets: @revReach[s]@ is @{s}@ ∪ the reverse-
-- reach of every SCC that has an edge /into/ @s@ on the condensation
-- (i.e. every SCC whose members use @s@'s members). Symmetric to
-- 'reachSetsPerSCC' but walks 'cdReverse' in /forward/ topo order
-- (users precede usees), so each user's set is already populated when
-- we reach the usee.
reverseReachPerSCC :: Condensation -> IM.IntMap IS.IntSet
reverseReachPerSCC !cond =
  foldl' step IM.empty (cdTopo cond)
  where
    rev = cdReverse cond
    step !acc s =
      let users   = IM.findWithDefault IS.empty s rev
          !merged =
            IS.foldl'
              (\ !r u -> IS.union r (IM.findWithDefault IS.empty u acc))
              IS.empty users
          !full   = IS.insert s merged
      in IM.insert s full acc

-- | @nodeReachers[s]@ — number of /node-level/ definitions whose
-- @reach⁺@ contains @s@. Each reaching SCC contributes its member
-- count (every member shares the same forward reach, so each is a
-- distinct definition whose cost includes @s@).
nodeReachersPerSCC :: Condensation -> IM.IntMap IS.IntSet -> IM.IntMap Int
nodeReachersPerSCC !cond !revReach =
  IM.map
    (\rs -> IS.foldl'
              (\ !n s' -> n + IS.size (IM.findWithDefault IS.empty s' (cdMembers cond)))
              0 rs)
    revReach

-- | Sum observed per-node costs onto their containing SCC.
observedPerSCC :: Condensation -> IM.IntMap Double -> IM.IntMap Double
observedPerSCC !cond !obs =
  IM.foldlWithKey'
    (\ !acc v t ->
       let !s = IM.findWithDefault (-1) v (cdSccOf cond)
       in IM.insertWith (+) s t acc)
    IM.empty obs

-- | Per-SCC lever score. @selfUnit@ is the observed self-time when a
-- profile is supplied, otherwise the modeled per-reacher contribution
-- @w1 + w2·fanProd + w3·kindSum@. Multiplied by the reacher count.
data Lever = Lever
  { lvLever    :: !Double   -- ^ nodeReachers * selfUnit.
  , lvReachers :: !Int      -- ^ |definitions that reach this node|.
  , lvUnit     :: !Double   -- ^ selfUnit actually used for the ranking.
  , lvModeled  :: !Double   -- ^ modeled self-unit (always present).
  , lvObserved :: !(Maybe Double)  -- ^ observed self-time, if profiled.
  } deriving (Show)

instance NFData Lever where
  rnf (Lever a b c d e) =
        rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e

-- | Compute every SCC's lever, sharded across SCCs like 'scoreSCCs'.
leverSCCs
  :: Options
  -> Condensation
  -> IM.IntMap Int            -- ^ reacher count per SCC.
  -> IM.IntMap Int            -- ^ fanIn*fanOut per SCC (self, not reach-summed).
  -> IM.IntMap Int            -- ^ kind sum per SCC (self).
  -> Maybe (IM.IntMap Double) -- ^ observed self-time per SCC (Just when profiled).
  -> IM.IntMap Lever
leverSCCs !opts !cond !reachers !fanProd !kindSum !mObs =
  let sccs = cdTopo cond
      leverOne s =
        let !rc       = IM.findWithDefault 0 s reachers
            !fp       = IM.findWithDefault 0 s fanProd
            !ks       = IM.findWithDefault 0 s kindSum
            !modeled  = optW1 opts
                      + optW2 opts * fromIntegral fp
                      + optW3 opts * fromIntegral ks
            !mObsSelf = fmap (IM.findWithDefault 0 s) mObs
            !unit     = fromMaybe modeled mObsSelf
            !lv       = fromIntegral rc * unit
        in (s, Lever
                 { lvLever    = lv
                 , lvReachers = rc
                 , lvUnit     = unit
                 , lvModeled  = modeled
                 , lvObserved = mObsSelf
                 })
      !scored = parMap rdeepseq leverOne sccs
  in IM.fromList scored

------------------------------------------------------------------------
-- Typecheck-profile ingest + calibration.
------------------------------------------------------------------------

-- | Read and decode a profile file, exiting with a clean diagnostic on
-- any failure (unreadable file, bad JSON, wrong shape, empty map).
loadProfileMap :: FilePath -> IO (HM.HashMap Text Double)
loadProfileMap p = do
  r <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
  bs <- case r of
    Left e  -> die ("--profile: cannot read " ++ p ++ ": " ++ show e)
    Right b -> pure b
  case A.eitherDecodeStrict' bs of
    Left e  -> die ("--profile: " ++ p ++ ": JSON parse error: " ++ e)
    Right v -> case parseProfile v of
      Left e  -> die ("--profile: " ++ p ++ ": " ++ e)
      Right m
        | HM.null m -> die ("--profile: " ++ p ++ ": no (qname, cost) entries found.")
        | otherwise -> pure m
  where
    die msg = hPutStrLn stderr ("pyre: " ++ msg) >> exitFailure

-- | Decode a profile 'A.Value' into a @qname -> cost@ map. Two shapes
-- are accepted (the numeric value is an arbitrary cost — milliseconds,
-- say; units cancel out of the rank correlation and are absorbed by
-- the fitted scale/intercept):
--
--   * a JSON object @{ "Full.QName": 123.4, ... }@;
--   * a JSON array @[ { "name": "Full.QName", "cost": 123.4 }, ... ]@
--     where the name key is @name@ or @qname@ and the cost key is one
--     of @cost@ / @ms@ / @time@ / @value@.
parseProfile :: A.Value -> Either String (HM.HashMap Text Double)
parseProfile val = case val of
  A.Object o -> HM.fromList <$> traverse fromKV (KM.toList o)
  A.Array  a -> HM.fromList <$> traverse fromRec (V.toList a)
  _          -> Left "expected a JSON object {qname: cost} or array of \
                     \{name, cost} records"
  where
    fromKV (k, v) = do
      d <- asNum ("key " ++ show (K.toText k)) v
      pure (K.toText k, d)
    fromRec (A.Object r) = do
      name <- firstText  r ["name", "qname"]
      cost <- firstNum   r ["cost", "ms", "time", "value"]
      pure (name, cost)
    fromRec _ = Left "array elements must be objects with a name and a numeric cost"

    asNum _   (A.Number n) = Right (realToFrac n)
    asNum ctx _            = Left (ctx ++ ": expected a number")

    firstText r keys = case [ t | key <- keys
                                , Just (A.String t) <- [KM.lookup (K.fromText key) r] ] of
      (t:_) -> Right t
      []    -> Left ("record missing a string name field (one of " ++ show keys ++ ")")
    firstNum r keys = case [ realToFrac n | key <- keys
                                          , Just (A.Number n) <- [KM.lookup (K.fromText key) r] ] of
      (d:_) -> Right d
      []    -> Left ("record missing a numeric cost field (one of " ++ show keys ++ ")")

-- | The fitted cost model: four feature weights plus an intercept.
data Calibration = Calibration
  { calW1        :: !Double
  , calW2        :: !Double
  , calW3        :: !Double
  , calW4        :: !Double
  , calIntercept :: !Double
  } deriving (Show)

-- | Ridge-regress observed cost against the four graph features.
-- @rows@ are @(featureVector, observedCost)@ where the feature vector
-- is @[reach, fanProd, kindSum, drNorm, 1]@ (last column = intercept).
-- L2 regularisation @lam@ is added to the four feature diagonals only
-- (never the intercept), which also keeps the 5x5 normal matrix
-- non-singular for any @lam > 0@. 'Nothing' if the (regularised)
-- system is still singular or there are too few rows.
calibrate :: Double -> [([Double], Double)] -> Maybe Calibration
calibrate lam rows
  | length rows < 2 = Nothing
  | otherwise       =
      let !(xtx, xty) = normalEquations lam rows
      in case cramer xtx xty of
           Just [w1, w2, w3, w4, c] ->
             Just (Calibration w1 w2 w3 w4 c)
           _ -> Nothing

-- | Accumulate @XᵀX@ (with ridge on the feature diagonals) and @Xᵀy@.
normalEquations :: Double -> [([Double], Double)] -> ([[Double]], [Double])
normalEquations lam rows =
  let k = 5
      step (!m, !v) (!f, !y) =
        ( [ [ (m !! i !! j) + (f !! i) * (f !! j) | j <- [0 .. k - 1] ]
          | i <- [0 .. k - 1] ]
        , [ (v !! i) + (f !! i) * y | i <- [0 .. k - 1] ] )
      (xtx, xty) = foldl' step (replicate k (replicate k 0), replicate k 0) rows
      ridged = [ [ (xtx !! i !! j) + (if i == j && i < 4 then lam else 0)
                 | j <- [0 .. k - 1] ]
               | i <- [0 .. k - 1] ]
  in (ridged, xty)

-- | Solve @A x = b@ for a small dense system via Cramer's rule.
-- Adequate (and obviously correct) for the 5x5 here; ridge keeps the
-- determinant away from zero. 'Nothing' on a singular @A@.
cramer :: [[Double]] -> [Double] -> Maybe [Double]
cramer a b =
  let d = determinant a
  in if abs d < 1e-12
       then Nothing
       else Just [ determinant (replaceCol i a b) / d | i <- [0 .. length b - 1] ]
  where
    replaceCol i mat col = [ setAt i (col !! r) (mat !! r) | r <- [0 .. length mat - 1] ]
    setAt i x xs = take i xs ++ [x] ++ drop (i + 1) xs

-- | Laplace-expansion determinant. Only ever called on tiny matrices.
determinant :: [[Double]] -> Double
determinant []      = 1
determinant [[x]]   = x
determinant m       =
  sum [ sign j * (head m !! j) * determinant (minor j) | j <- [0 .. n - 1] ]
  where
    n        = length m
    sign j   = if even j then 1 else -1
    minor j  = [ delAt j row | row <- tail m ]
    delAt k xs = take k xs ++ drop (k + 1) xs

------------------------------------------------------------------------
-- Spearman rank correlation (ties handled via average ranks).
------------------------------------------------------------------------

-- | Spearman ρ over paired observations. 'Nothing' for < 2 points or a
-- degenerate (zero-variance) input.
spearman :: [(Double, Double)] -> Maybe Double
spearman ps
  | length ps < 2 = Nothing
  | otherwise     =
      let rx = averageRanks (map fst ps)
          ry = averageRanks (map snd ps)
      in pearson (zip rx ry)

-- | Fractional (average) ranks, aligned to the input order. Ties share
-- the mean of the ranks they would otherwise occupy.
averageRanks :: [Double] -> [Double]
averageRanks xs =
  let idxVals = sortBy (comparing snd) (zip [0 :: Int ..] xs)
      go _    [] = []
      go !pos rest =
        let v          = snd (head rest)
            (tie, more) = span ((== v) . snd) rest
            m          = length tie
            avg        = fromIntegral (sum [pos .. pos + m - 1])
                       / fromIntegral m :: Double
        in [ (i, avg) | (i, _) <- tie ] ++ go (pos + m) more
  in map snd (sortBy (comparing fst) (go (1 :: Int) idxVals))

-- | Pearson correlation. 'Nothing' if either side has zero variance.
pearson :: [(Double, Double)] -> Maybe Double
pearson ps =
  let n   = fromIntegral (length ps) :: Double
      sx  = sum (map fst ps)
      sy  = sum (map snd ps)
      sxx = sum (map (\(x, _) -> x * x) ps)
      syy = sum (map (\(_, y) -> y * y) ps)
      sxy = sum (map (\(x, y) -> x * y) ps)
      cov = n * sxy - sx * sy
      vx  = n * sxx - sx * sx
      vy  = n * syy - sy * sy
      den = sqrt (vx * vy)
  in if den <= 0 then Nothing else Just (cov / den)

------------------------------------------------------------------------
-- Regex exclusion (mirrors LoadBearing.computeExcludedSet)
------------------------------------------------------------------------

-- (computeExcludedSet / lastSegment moved to "AgdaOptimization.Common".)

------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------

-- | A profile-derived calibration report, assembled once in 'run' and
-- consumed by both the human renderer and 'pyreJson'.
data ProfileReport = ProfileReport
  { prPath    :: !FilePath
  , prEntries :: !Int               -- ^ Entries in the profile file.
  , prMatched :: !Int               -- ^ Real defs matched by qname.
  , prLambda  :: !Double            -- ^ Ridge λ used for the fit.
  , prRhoPre  :: !(Maybe Double)    -- ^ Spearman ρ with the pre-fit weights.
  , prCal     :: !(Maybe Calibration)
  , prRhoFit  :: !(Maybe Double)    -- ^ Spearman ρ with the fitted weights.
  }

-- | Entry point. Pure compute + single output dump. @stderr@ carries
-- the exclusion / profile / calibration breadcrumbs; the report goes
-- to stdout (or @--out FILE@) as text or JSON.
run :: Index -> GlobalOpts -> Options -> IO ()
run !ix !gOpts !opts = do
  when (optCalibrate opts && isNothingPath (optProfilePath opts)) $ do
    hPutStrLn stderr "pyre: --calibrate requires --profile=PATH."
    exitFailure

  let !cond     = buildCondensation ix
      !excluded = computeExcludedSet ix (optExcludeNameRegex opts)
  when (not (IS.null excluded)) $
    hPutStrLn stderr $
      "[pyre] excluded " ++ show (IS.size excluded)
      ++ " definitions matching " ++ T.unpack (optExcludeNameRegex opts) ++ "."

  -- Load + join the profile up front (IO) so the rest stays pure.
  mProf <- case optProfilePath opts of
    Nothing -> pure Nothing
    Just p  -> do
      pm <- loadProfileMap p
      pure (Just (p, pm))

  let -- Weight-independent structural maps (shared by every weighting).
      !reach     = reachSetsPerSCC cond
      !fanProd   = fanProductPerSCC cond
      !kindSum   = kindSumPerSCC ix cond
      !depth     = depthRankSCC cond
      !dMax      = if IM.null depth then 0 else maximum (IM.elems depth)
      !scoreMap0 = scoreSCCs opts cond reach fanProd kindSum depth dMax

      sccOfNode :: Int -> Int
      sccOfNode v = IM.findWithDefault (-1) v (cdSccOf cond)

      zeroScore = SccScore 0 0 0 0 0.0

      -- Feature vector for a node: [reach, fanProd, kindSum, drNorm, 1].
      -- Read off 'scoreMap0' (weight-independent fields).
      denom = if dMax <= 0 then 1.0 else fromIntegral dMax :: Double
      featOf :: Int -> [Double]
      featOf v =
        let sc = IM.findWithDefault zeroScore (sccOfNode v) scoreMap0
        in [ fromIntegral (sccReach sc)
           , fromIntegral (sccFanProd sc)
           , fromIntegral (sccKindSum sc)
           , fromIntegral (sccDepth sc) / denom
           , 1.0 ]
      predictWith :: [Double] -> Int -> Double
      predictWith ws v = sum (zipWith (*) ws (take 4 (featOf v)))

      -- Profile join: real defs whose qname appears in the profile.
      observedOf :: IM.IntMap Double
      !observedOf = case mProf of
        Nothing      -> IM.empty
        Just (_, pm) ->
          IM.fromList
            [ (defId d, t)
            | d <- V.toList (idxDefs ix)
            , defId d < idxRealCount ix
            , Just t <- [HM.lookup (defName d) pm]
            ]
      !nMatched = IM.size observedOf

      -- Ridge fit (only when a profile is present).
      mCal :: Maybe Calibration
      !mCal = case mProf of
        Nothing -> Nothing
        Just _  -> calibrate (optRidgeLambda opts)
                             [ (featOf v, t) | (v, t) <- IM.toList observedOf ]

      -- Effective weights: fitted ones replace the defaults iff
      -- --calibrate AND the fit succeeded.
      (effOpts, calibratedApplied) = case (optCalibrate opts, mCal) of
        (True, Just c) ->
          ( opts { optW1 = calW1 c, optW2 = calW2 c
                 , optW3 = calW3 c, optW4 = calW4 c }
          , True )
        _ -> (opts, False)

      !scoreMap
        | calibratedApplied = scoreSCCs effOpts cond reach fanProd kindSum depth dMax
        | otherwise         = scoreMap0

      scoreOf :: Int -> Double
      scoreOf v = maybe 0.0 sccScore (IM.lookup (sccOfNode v) scoreMap)

      -- Correlations over the matched set.
      rhoPre = spearman [ (predictWith [optW1 opts, optW2 opts, optW3 opts, optW4 opts] v, t)
                        | (v, t) <- IM.toList observedOf ]
      rhoFit = case mCal of
        Just c  -> spearman [ (predictWith [calW1 c, calW2 c, calW3 c, calW4 c] v, t)
                            | (v, t) <- IM.toList observedOf ]
        Nothing -> Nothing

      mReport = case mProf of
        Nothing      -> Nothing
        Just (p, pm) -> Just ProfileReport
          { prPath    = p
          , prEntries = HM.size pm
          , prMatched = nMatched
          , prLambda  = optRidgeLambda opts
          , prRhoPre  = rhoPre
          , prCal     = mCal
          , prRhoFit  = rhoFit
          }

      -- Candidates: every real def, minus regex-excluded ones.
      -- Synthetic (edge-only) nodes are deliberately included — they
      -- still carry a meaningful reach / depth.
      candidates :: [Int]
      !candidates =
        [ v | v <- [0 .. idxNodeCount ix - 1], not (IS.member v excluded) ]

      -- Cost ranking: score desc, then defName asc for a stable tiebreak.
      !topN =
        take (optTopN opts) $
          sortBy (comparing (\v -> (Down (scoreOf v), defName (defAt ix v)))) candidates

      -- Lever ranking (only materialised when --levers is set).
      mObsSCC   = fmap (\_ -> observedPerSCC cond observedOf) mProf
      revReach  = reverseReachPerSCC cond
      reachers  = nodeReachersPerSCC cond revReach
      leverMap  = leverSCCs effOpts cond reachers fanProd kindSum mObsSCC
      leverOf v = maybe 0.0 lvLever (IM.lookup (sccOfNode v) leverMap)
      !topNLever =
        take (optTopN opts) $
          sortBy (comparing (\v -> (Down (leverOf v), defName (defAt ix v)))) candidates
      mLevers = if optLevers opts then Just (topNLever, leverMap) else Nothing

  case mProf of
    Just (p, _) ->
      hPutStrLn stderr $
        "[pyre] profile: matched " ++ show nMatched ++ "/"
        ++ show (idxRealCount ix) ++ " real defs from " ++ p ++ "."
    Nothing -> pure ()
  when calibratedApplied $
    hPutStrLn stderr "[pyre] calibrate: applied fitted weights to the ranking."

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        pyreJson ix cond effOpts excluded scoreMap sccOfNode dMax topN
                 calibratedApplied mReport mLevers
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn $ "# Pyre — predicted typecheck cost (top " ++ show (optTopN opts) ++ ")"
      putStrLn $ "|V| = " ++ show (idxNodeCount ix)
              ++ ", |SCC| = " ++ show (cdCount cond)
              ++ ", D (max depth rank) = " ++ show dMax
              ++ ", excluded by regex = " ++ show (IS.size excluded)
      putStrLn $ "weights: w1=" ++ showD (optW1 effOpts)
              ++ ", w2=" ++ showD (optW2 effOpts)
              ++ ", w3=" ++ showD (optW3 effOpts)
              ++ ", w4=" ++ showD (optW4 effOpts)
              ++ (if calibratedApplied then "  (calibrated)" else "")
      putStrLn ""
      let header = [ "Rank","QName","Module","State"
                   , "score","reach","recDeps","depth"
                   ]
          rows =
            [ [ show r
              , T.unpack (defName d)
              , T.unpack (defModule d)
              , stateLetter (defState d)
              , showFixed1 (sccScore sc)
              , show (sccReach sc)
              , show (sccKindSum sc)
              , show (sccDepth sc)
              ]
            | (r, v) <- zip [1 :: Int ..] topN
            , let !d  = defAt ix v
                  !sc = IM.findWithDefault zeroScore (sccOfNode v) scoreMap
            ]
      putStr (renderTable header rows)
      mapM_ (printCalibration ix calibratedApplied) mReport
      mapM_ (printLevers ix sccOfNode opts (maybe False (const True) mProf)) mLevers

-- | 'True' iff no @--profile@ path was supplied. Avoids an 'Eq'
-- constraint on the loaded profile map.
isNothingPath :: Maybe FilePath -> Bool
isNothingPath Nothing = True
isNothingPath _       = False

-- | Render the calibration section under the cost table.
printCalibration :: Index -> Bool -> ProfileReport -> IO ()
printCalibration ix calibratedApplied ProfileReport{..} = do
  putStrLn ""
  putStrLn $ "## Calibration (profile: " ++ prPath ++ ")"
  putStrLn $ "matched " ++ show prMatched ++ "/" ++ show (idxRealCount ix)
          ++ " real defs; profile entries = " ++ show prEntries
          ++ "; ridge lambda = " ++ showD prLambda
  putStrLn $ "Spearman rho (current weights) = " ++ maybe "n/a" showFixed3 prRhoPre
  case prCal of
    Nothing ->
      putStrLn "fitted weights: unavailable (need >= 2 matched defs and a \
               \non-singular fit)."
    Just c  -> do
      putStrLn $ "fitted weights: w1=" ++ showFixed3 (calW1 c)
              ++ ", w2=" ++ showFixed3 (calW2 c)
              ++ ", w3=" ++ showFixed3 (calW3 c)
              ++ ", w4=" ++ showFixed3 (calW4 c)
              ++ ", intercept=" ++ showFixed3 (calIntercept c)
      putStrLn $ "Spearman rho (fitted weights)  = " ++ maybe "n/a" showFixed3 prRhoFit
      if calibratedApplied
        then putStrLn "  (applied to the ranking above via --calibrate)"
        else putStrLn $ "  re-run with --calibrate to apply, or persist via "
                     ++ "pyre: { w1: " ++ showD (calW1 c) ++ ", w2: " ++ showD (calW2 c)
                     ++ ", w3: " ++ showD (calW3 c) ++ ", w4: " ++ showD (calW4 c)
                     ++ " } in .agda-optimization.yml."

-- | Render the lever section under the cost (and calibration) tables.
printLevers :: Index -> (Int -> Int) -> Options -> Bool -> ([Int], IM.IntMap Lever) -> IO ()
printLevers ix sccOfNode opts profiled (topNLever, leverMap) = do
  putStrLn ""
  putStrLn $ "## Levers — aggregate downstream cost attribution (top "
          ++ show (optTopN opts) ++ ")"
  putStrLn $ "lever = reachers x selfCost; selfCost = "
          ++ (if profiled then "observed self-time"
                          else "modeled w1 + w2*fanProd + w3*kindSum")
  putStrLn ""
  let header = ["Rank","QName","Module","State","lever","reachers","selfCost"]
      rows =
        [ [ show r
          , T.unpack (defName d)
          , T.unpack (defModule d)
          , stateLetter (defState d)
          , showFixed1 (lvLever lv)
          , show (lvReachers lv)
          , showFixed1 (lvUnit lv)
          ]
        | (r, v) <- zip [1 :: Int ..] topNLever
        , let !d  = defAt ix v
              !lv = IM.findWithDefault (Lever 0 0 0 0 Nothing) (sccOfNode v) leverMap
        ]
  putStr (renderTable header rows)

------------------------------------------------------------------------
-- Display helpers
------------------------------------------------------------------------

stateLetter :: State -> String
stateLetter Defined   = "D"
stateLetter Postulate = "P"
stateLetter Hole      = "H"
stateLetter Failed    = "F"

-- | Lower-case wire label for a 'Kind' (parallels the producer JSON).
kindLabel :: Kind -> Text
kindLabel KFunction    = "function"
kindLabel KProjection  = "projection"
kindLabel KDatatype    = "datatype"
kindLabel KRecord      = "record"
kindLabel KConstructor = "constructor"
kindLabel KPostulate   = "postulate"
kindLabel KPrimitive   = "primitive"
kindLabel KOther       = "other"

-- | @showFixed1 1.234@ = @"1.2"@. Local helper to avoid pulling in
-- @Text.Printf@ for one call site.
showFixed1 :: Double -> String
showFixed1 !x =
  let n      = round (x * 10) :: Int
      (q, r) = divMod (abs n) 10
      sign   = if n < 0 then "-" else ""
  in sign ++ show q ++ "." ++ show r

-- | @showFixed3 1.2345@ = @"1.234"@ (round-half-to-even via 'round').
-- Used for the ρ / fitted-weight figures, where 1 decimal is too
-- coarse.
showFixed3 :: Double -> String
showFixed3 !x =
  let n      = round (x * 1000) :: Int
      (q, r) = divMod (abs n) 1000
      sign   = if n < 0 then "-" else ""
      pad3 v = let s = show v in replicate (3 - length s) '0' ++ s
  in sign ++ show q ++ "." ++ pad3 r

-- | Bare @Show@ for a 'Double' weight value — keeps trailing zeroes
-- off the printed banner.
showD :: Double -> String
showD = show

------------------------------------------------------------------------
-- JSON rendering
------------------------------------------------------------------------

pyreJson
  :: Index
  -> Condensation
  -> Options                -- ^ /Effective/ options (calibrated weights folded in).
  -> IS.IntSet              -- ^ Excluded by regex.
  -> IM.IntMap SccScore     -- ^ Per-SCC score table.
  -> (Int -> Int)           -- ^ node -> scc.
  -> Int                    -- ^ Max depth rank (for the stats block).
  -> [Int]                  -- ^ Top-N node ids in rank order.
  -> Bool                   -- ^ Whether fitted weights were applied.
  -> Maybe ProfileReport    -- ^ Calibration report, if profiled.
  -> Maybe ([Int], IM.IntMap Lever)  -- ^ Lever table, if requested.
  -> A.Value
pyreJson ix cond opts excluded scoreMap sccOfNode dMax topN
         calibrated mReport mLevers =
  A.object $
    [ "subcommand" .= ("pyre" :: Text)
    , "options"    .= pyreOptionsJson opts
    , "stats"      .= A.object
        [ "n_nodes"           .= idxNodeCount ix
        , "n_scc"             .= cdCount cond
        , "max_depth_rank"    .= dMax
        , "excluded_by_regex" .= IS.size excluded
        , "calibrated"        .= calibrated
        ]
    , "rows" .= A.toJSON
        (zipWith (pyreRowJson ix sccOfNode scoreMap)
                 [1 :: Int ..] topN)
    ]
    ++ maybe [] (\r -> [ "profile" .= profileJson ix r ]) mReport
    ++ maybe [] (\(tl, lm) ->
                   [ "levers" .= A.toJSON
                       (zipWith (leverRowJson ix sccOfNode lm)
                                [1 :: Int ..] tl) ])
                mLevers

pyreOptionsJson :: Options -> A.Value
pyreOptionsJson Options{..} = A.object
  [ "top_n"              .= optTopN
  , "w1"                 .= optW1
  , "w2"                 .= optW2
  , "w3"                 .= optW3
  , "w4"                 .= optW4
  , "exclude_name_regex" .= optExcludeNameRegex
  , "profile"            .= optProfilePath
  , "calibrate"          .= optCalibrate
  , "ridge_lambda"       .= optRidgeLambda
  , "levers"             .= optLevers
  ]

-- | The @"profile"@ block: coverage, both Spearman ρ figures, and the
-- ridge-fitted coefficients (when the fit succeeded).
profileJson :: Index -> ProfileReport -> A.Value
profileJson ix ProfileReport{..} =
  A.object $
    [ "path"             .= prPath
    , "entries"          .= prEntries
    , "matched"          .= prMatched
    , "n_real"           .= idxRealCount ix
    , "ridge_lambda"     .= prLambda
    , "spearman_current" .= prRhoPre
    , "spearman_fitted"  .= prRhoFit
    ]
    ++ case prCal of
         Nothing -> [ "fitted" .= A.Null ]
         Just c  -> [ "fitted" .= A.object
                        [ "w1"        .= calW1 c
                        , "w2"        .= calW2 c
                        , "w3"        .= calW3 c
                        , "w4"        .= calW4 c
                        , "intercept" .= calIntercept c
                        ] ]

pyreRowJson
  :: Index
  -> (Int -> Int)
  -> IM.IntMap SccScore
  -> Int
  -> Int
  -> A.Value
pyreRowJson ix sccOfNode scoreMap rank v =
  let d  = defAt ix v
      sc = IM.findWithDefault (SccScore 0 0 0 0 0.0)
                              (sccOfNode v) scoreMap
  in A.object
       [ "rank"       .= rank
       , "qname"      .= defName d
       , "module"     .= defModule d
       , "state"      .= stateLetter (defState d)
       , "kind"       .= kindLabel (defKind d)
       , "score"      .= sccScore sc
       , "reach"      .= sccReach sc
       , "fan_prod"   .= sccFanProd sc
       , "kind_sum"   .= sccKindSum sc
       , "depth_rank" .= sccDepth sc
       ]

leverRowJson
  :: Index
  -> (Int -> Int)
  -> IM.IntMap Lever
  -> Int
  -> Int
  -> A.Value
leverRowJson ix sccOfNode leverMap rank v =
  let d  = defAt ix v
      lv = IM.findWithDefault (Lever 0 0 0 0 Nothing) (sccOfNode v) leverMap
  in A.object $
       [ "rank"       .= rank
       , "qname"      .= defName d
       , "module"     .= defModule d
       , "state"      .= stateLetter (defState d)
       , "kind"       .= kindLabel (defKind d)
       , "lever"      .= lvLever lv
       , "reachers"   .= lvReachers lv
       , "self_cost"  .= lvUnit lv
       , "modeled"    .= lvModeled lv
       ]
       ++ maybe [] (\o -> [ "observed" .= o ]) (lvObserved lv)
