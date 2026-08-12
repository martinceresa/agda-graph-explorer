{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Strata — declared-hierarchy module cohesion.
--
-- Per-module Henderson-Sellers LCOM\' against the /declared/ module
-- tree (the dot-separated path of @defModule@), plus Martin's
-- instability and abstractness, condensed into a single incoherence
-- score.
--
-- For each module @m@, every out-edge of one of its defs is classified
-- by where the target lives:
--
--   * /internal/        — target's module is exactly @m@.
--   * /parent-internal/ — target's module is a strict dotted prefix of
--                         @m@ (i.e. an ancestor in the declared tree).
--                         These are ordinary hierarchy references; they
--                         are deliberately neither rewarded nor
--                         punished and are dropped from LCOM\'.
--   * /external/        — anything else (sibling subtree, unrelated
--                         module).
--
-- Per-module metrics:
--
--   * @LCOM\'@ = @1 - internal / (internal + external)@
--   * /fan-out spread/ = number of distinct sibling-disjoint module
--     prefixes the externals reach (see 'spreadOf').
--   * @I = Ce / (Ca + Ce)@ — Martin's instability. @Ce@ counts
--     /distinct external modules @m@ depends on/; @Ca@ counts distinct
--     external modules that depend on @m@.
--   * @A@ = abstract-shape ratio over the module's defs:
--     @(records + postulates + holes + datatypes) / |m|@. We have no
--     "interface" concept in Agda's schema — we proxy with /datatypes/
--     since they share the "structural shape" role with records. The
--     choice is documented in 'abstractnessOf'.
--   * @D = |A + I - 1|@ — distance from Martin's main sequence.
--
-- Ranking: @incoherence = LCOM\' * log(1 + spread) * |D - (1 - I)|@.
--
-- The "Top out-of-place external" finding reports the modal /sibling
-- subtree/ leak — a child of @parent(m)@ that is not @m@'s own subtree.
-- See 'siblingPrefixOf' and 'TopSibling'.
--
-- No parallelism: per-module work is tiny (a few arithmetic ops) and
-- the dominant cost is the single linear pass over edges.
module AgdaOptimization.Strata
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.List            ( sortBy )
import qualified Data.Map.Strict      as Map
import           Data.Maybe           ( fromMaybe )
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Set             as Set
import           Data.Text            ( Text )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           Text.Printf          ( printf )
import           Text.Regex.TDFA      ( Regex, makeRegex, matchTest )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), defAt )
import           AgdaGraph.Schema     ( Definition(..), Kind(..), State(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report   ( GlobalOpts(..), OutFormat(..)
                                           , renderTable, emitJsonReport
                                           , withHumanReport )

-- ---------------------------------------------------------------------------
-- Options

-- | User-facing knobs. See module header for the semantics.
data Options = Options
  { optTopN               :: !Int
    -- ^ Maximum number of rows in the report table.
  , optMinSize            :: !Int
    -- ^ Skip modules with fewer than this many defs; below the
    -- threshold the metrics are too noisy to be actionable.
  , optExcludeModuleRegex :: !Text
    -- ^ POSIX-ERE matched against each module name; an empty pattern
    -- disables the filter. Typical use: @^Agda\\.Builtin\\.@.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optTopN               = 50
  , optMinSize            = 3
  , optExcludeModuleRegex = T.empty
  }

-- | Declarative flag spec for the @strata@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "top-n" "--top-n=N                        rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , IntFlag "min-size" "--min-size=N                     skip modules with fewer than N defs (default 3)"
      (\n o -> o { optMinSize = n })
  , TextFlag "exclude-module-regex" "--exclude-module-regex=PATTERN   POSIX-ERE on the full module name"
      (\p o -> o { optExcludeModuleRegex = p })
  ]

-- | Hand-rolled CLI parser for the @strata@ subcommand. Mirrors the
-- per-flag dispatch shape used by all the other @AgdaOptimization.*@
-- modules — see e.g. 'AgdaOptimization.Polyglot.parseOptions'.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "strata" flagSpecs

-- | Overlay the @strata:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "strata" flagSpecs obj o0

-- ---------------------------------------------------------------------------
-- Public entry

-- | Build the per-module accumulators, rank, render.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts@Options{..} = do
  let !defs       = idxDefs ix
      !modOfNode  = moduleOfNode ix
      !defsByMod  = bucketDefsByModule defs
      !excludeRe
        | T.null optExcludeModuleRegex = Nothing
        | otherwise                    = Just (makeRegex (T.unpack optExcludeModuleRegex) :: Regex)
      moduleAllowed :: Text -> Bool
      moduleAllowed m = case excludeRe of
        Nothing -> True
        Just re -> not (matchTest re (T.unpack m))

      -- One forward-edge pass produces, per module:
      --   * (internal, parentInternal, external) edge counts
      --   * sibling-disjoint prefix -> count of externals reaching it
      --     (for the spread metric)
      --   * sibling-subtree -> count of externals leaking to it
      --     (for the "top out-of-place external" finding)
      --   * Ce set (distinct external modules m depends on)
      --   * Ca set (distinct external modules that depend on m)
      !edgeStats = classifyAllEdges ix modOfNode

      -- Score every qualifying module.
      !scored
        = [ s
          | (m, defIds) <- Map.toAscList defsByMod
          , length defIds >= optMinSize
          , moduleAllowed m
          , let s = scoreModule ix m defIds
                                (Map.findWithDefault emptyAcc m edgeStats)
          ]

      !ranked = sortBy (comparing (Down . sIncoherence)) scored

      !topRows = take optTopN ranked

      -- Header stats.
      !nModulesTotal     = Map.size defsByMod
      !nModulesScored    = length scored
      !nModulesSkipped   = nModulesTotal - nModulesScored

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        strataJson opts nModulesTotal nModulesScored nModulesSkipped topRows
    OutHuman -> withHumanReport gOpts "strata" $ do
      putStrLn $ "# Strata - top " ++ show optTopN
              ++ " (min-size=" ++ show optMinSize ++ ")"
      putStrLn $ "  modules total           : " ++ show nModulesTotal
      putStrLn $ "  modules scored          : " ++ show nModulesScored
      putStrLn $ "  modules skipped (size)  : " ++ show nModulesSkipped
      putStrLn ""

      case topRows of
        [] -> putStrLn "no modules meet the min-size threshold"
        _  -> do
          let header = ["Rank","Module","|m|","LCOM'","spread","I","A","D","inc"]
              rowOf rank s =
                [ show rank
                , T.unpack (sModule s)
                , show (sSize s)
                , fmt2 (sLcom s)
                , show (sSpread s)
                , fmt2 (sInstability s)
                , fmt2 (sAbstract s)
                , fmt2 (sDistance s)
                , fmt2 (sIncoherence s)
                ]
              rows = zipWith rowOf [(1::Int)..] topRows
          putStr (renderTable header rows)

          -- Findings (one per row): top out-of-place external.
          putStrLn ""
          putStrLn "## Top out-of-place external (per module)"
          mapM_ (putStrLn . renderFinding) topRows

-- ---------------------------------------------------------------------------
-- Per-module bucket

-- | Bucket every def-id by its declared 'defModule'. Strict map; values
-- are reverse-insertion-ordered (cons-prepend) — the order is not
-- semantically meaningful since downstream consumers only need the
-- /count/ and a per-kind/per-state tally.
bucketDefsByModule :: V.Vector Definition -> Map.Map Text [Int]
bucketDefsByModule = V.ifoldl' step Map.empty
  where
    step :: Map.Map Text [Int] -> Int -> Definition -> Map.Map Text [Int]
    step !acc i d =
      let !m = defModule d
      in Map.insertWith (\new old -> head new : old) m [i] acc

-- | Lookup the module of every node id in a single pass. Returns a
-- strict 'IntMap' so the edge-classifier doesn't need to re-dispatch
-- through 'Vector.!' for every edge.
moduleOfNode :: Index -> IM.IntMap Text
moduleOfNode ix =
  V.ifoldl' (\ !acc i d -> IM.insert i (defModule d) acc)
            IM.empty
            (idxDefs ix)

-- ---------------------------------------------------------------------------
-- Edge classification

-- | Per-module accumulators, filled by the single edge pass.
data ModAcc = ModAcc
  { aInternal       :: !Int
  , aParentInternal :: !Int
  , aExternal       :: !Int
    -- ^ Externals attributed BY this module (i.e. out-edges leaving
    -- @m@ to a non-prefix module).
  , aOutMods        :: !(Set.Set Text)
    -- ^ Distinct external target modules (= Ce).
  , aInMods         :: !(Set.Set Text)
    -- ^ Distinct external /source/ modules with an edge into @m@
    -- (= Ca).
  , aExtPrefixHits  :: !(Map.Map Text Int)
    -- ^ External target modules grouped by their longest-shared dotted
    -- prefix with the owning module. The key is the prefix; the value
    -- is the count of out-edges that landed in that group. Used only
    -- for the spread metric (it's a count of distinct buckets); the
    -- "Top out-of-place external" finding uses 'aSiblingHits' instead.
  , aSiblingHits    :: !(Map.Map Text Int)
    -- ^ Externals bucketed by /sibling subtree/ of the owning module
    -- @m@ — i.e. the child of @parent(m)@ that the external lives
    -- under, where that child is NOT @m@'s own subtree. See
    -- 'siblingPrefixOf'. This is the bucket the "Top out-of-place
    -- external" finding reports on.
  } deriving (Show)

emptyAcc :: ModAcc
emptyAcc = ModAcc
  { aInternal       = 0
  , aParentInternal = 0
  , aExternal       = 0
  , aOutMods        = Set.empty
  , aInMods         = Set.empty
  , aExtPrefixHits  = Map.empty
  , aSiblingHits    = Map.empty
  }

-- | Single linear pass over 'idxForward'. For each @(srcMod, tgtMod)@:
--
--   * Classify the edge as internal / parent-internal / external from
--     the source's point of view; bump @src@'s counters.
--   * When external, also add @tgtMod@ to @src.aOutMods@ (Ce) and add
--     @srcMod@ to @tgt.aInMods@ (Ca), bucket the external target by
--     its longest-shared prefix with @srcMod@ (for /spread/), and (if
--     the external lives in a sibling subtree of @srcMod@) bucket it
--     by sibling subtree (for the /top out-of-place external/
--     finding).
--
-- Parent-internal edges intentionally do NOT contribute to Ce / Ca —
-- climbing the declared tree to a parent is not "coupling to another
-- subsystem", it is using the hierarchy as designed.
classifyAllEdges
  :: Index
  -> IM.IntMap Text                 -- ^ node id -> module
  -> Map.Map Text ModAcc
classifyAllEdges ix modOf =
  IM.foldlWithKey' visitSrc Map.empty (idxForward ix)
  where
    lookupMod :: Int -> Text
    lookupMod n = fromMaybe (defModule (defAt ix n)) (IM.lookup n modOf)

    -- Split every distinct module name into its dot-components ONCE. The
    -- external-edge classification below otherwise re-runs @T.splitOn "."@
    -- on the same module strings once per edge (O(E·L)); with the cache it
    -- is O(M·L) splits + O(E) lookups.
    compCache :: Map.Map Text [Text]
    compCache = Map.fromSet (T.splitOn ".")
                  (Set.fromList [ lookupMod n | n <- [0 .. idxNodeCount ix - 1] ])
    comps :: Text -> [Text]
    comps m = Map.findWithDefault (T.splitOn "." m) m compCache

    visitSrc :: Map.Map Text ModAcc -> Int -> IS.IntSet -> Map.Map Text ModAcc
    visitSrc !acc src tgts =
      let !srcMod = lookupMod src
      in IS.foldl' (visitEdge srcMod) acc tgts

    visitEdge :: Text -> Map.Map Text ModAcc -> Int -> Map.Map Text ModAcc
    visitEdge !srcMod !acc tgt =
      let !tgtMod = lookupMod tgt
      in case classifyMod srcMod tgtMod of
           Internal       -> bumpInternal       srcMod acc
           ParentInternal -> bumpParentInternal srcMod acc
           External       -> bumpExternal       srcMod tgtMod acc

    bumpInternal :: Text -> Map.Map Text ModAcc -> Map.Map Text ModAcc
    bumpInternal m =
      Map.alter (\mo -> let a = fromMaybe emptyAcc mo
                            !n = aInternal a + 1
                        in Just $! a { aInternal = n })
                m

    bumpParentInternal :: Text -> Map.Map Text ModAcc -> Map.Map Text ModAcc
    bumpParentInternal m =
      Map.alter (\mo -> let a = fromMaybe emptyAcc mo
                            !n = aParentInternal a + 1
                        in Just $! a { aParentInternal = n })
                m

    bumpExternal
      :: Text     -- ^ src module
      -> Text     -- ^ tgt module
      -> Map.Map Text ModAcc -> Map.Map Text ModAcc
    bumpExternal !srcMod !tgtMod !acc =
      let !srcC    = comps srcMod
          !tgtC    = comps tgtMod
          !pfx     = sharedPrefixOrRoot srcC tgtC
          !mSib    = siblingPrefixOf srcC tgtC
          updSrc mo =
            let a   = fromMaybe emptyAcc mo
                !ex = aExternal a + 1
                !om = Set.insert tgtMod (aOutMods a)
                !ph = Map.insertWith (+) pfx 1 (aExtPrefixHits a)
                !sh = case mSib of
                        Nothing  -> aSiblingHits a
                        Just sib -> Map.insertWith (+) sib 1 (aSiblingHits a)
            in Just $! a { aExternal      = ex
                         , aOutMods       = om
                         , aExtPrefixHits = ph
                         , aSiblingHits   = sh
                         }
          updTgt mo =
            let a   = fromMaybe emptyAcc mo
                !im = Set.insert srcMod (aInMods a)
            in Just $! a { aInMods = im }
          !acc1 = Map.alter updSrc srcMod acc
          !acc2 = Map.alter updTgt tgtMod acc1
      in acc2

-- | Classification of one edge between two declared modules. See module
-- header for the rationale.
data EdgeClass = Internal | ParentInternal | External
  deriving (Show, Eq)

classifyMod :: Text -> Text -> EdgeClass
classifyMod src tgt
  | src == tgt                 = Internal
  | isPrefixModule tgt src     = ParentInternal
  | otherwise                  = External

-- | @isPrefixModule prefix m@ — does @prefix@ name an ancestor of @m@
-- (or @m@ itself) in the dot-separated declared module tree? Crucially,
-- @Foo.Bar@ is NOT a prefix of @Foo.BarBaz@ — only of @Foo.Bar.X@. We
-- implement that by demanding either an exact match or a @prefix <> "."@
-- prefix match on the string.
isPrefixModule :: Text -> Text -> Bool
isPrefixModule prefix m
  | prefix == m = True
  | otherwise   = (prefix `T.append` ".") `T.isPrefixOf` m

-- | The longest common dot-prefix of two module names, given as their
-- dot-split component lists and dotted back together — or the empty Text
-- if they share no root component.
--
-- Example: @["A","B","C"]@ vs @["A","B","D"]@ ⇒ @"A.B"@;
--          @["A","B"]@      vs @["X","Y"]@     ⇒ @""@.
longestSharedPrefix :: [Text] -> [Text] -> Text
longestSharedPrefix pa pb =
  T.intercalate "." (takeWhilePair (==) pa pb)
  where
    takeWhilePair :: (x -> y -> Bool) -> [x] -> [y] -> [x]
    takeWhilePair p (x:xs) (y:ys) | p x y = x : takeWhilePair p xs ys
    takeWhilePair _ _      _              = []

-- | The bucket key used for sibling-disjoint grouping (see
-- 'spreadOf'), on the component lists of owning module @m@ and external
-- target @e@: the /longest shared prefix/ if non-empty, otherwise @e@'s
-- first component as a fallback root group. We keep the fallback
-- non-empty so root-level externals can't collide into a single
-- ambiguous "" bucket.
sharedPrefixOrRoot :: [Text] -> [Text] -> Text
sharedPrefixOrRoot mC eC =
  let !sp = longestSharedPrefix mC eC
  in if T.null sp
       then case eC of { (h:_) -> h; [] -> "" }
       else sp

-- | @siblingPrefixOf m e@ — name the /sibling subtree/ of @m@ that the
-- external module @e@ lives in, or 'Nothing' if @e@ is not in a sibling
-- subtree of @m@.
--
-- A sibling subtree is a child of @parent(m)@ that is /not/ @m@'s own
-- subtree. Concretely, for @m = "A.B.C.D"@:
--
--   * @parent(m) = "A.B.C"@, @m@'s own child of parent is @"D"@.
--   * @e = "A.B.C.E.foo"@ → sibling subtree is @"A.B.C.E"@ (count it).
--   * @e = "A.B.C.D.helper"@ → same subtree as @m@ (don't count).
--   * @e = "A.B.Z"@         → uncle / ancestor leak, not a sibling
--                              (don't count).
--   * @e = "X.Y"@           → unrelated, not a sibling (don't count).
--
-- When @m@ is at depth 1 (e.g. @m = "Protocol"@), @parent(m)@ is the
-- empty root and has no parent itself — there is no sibling-subtree
-- concept at the root, so we return 'Nothing'. Callers surface that as
-- a different finding line; see 'renderFinding'.
siblingPrefixOf :: [Text] -> [Text] -> Maybe Text
siblingPrefixOf mParts eParts =
  case mParts of
    []     -> Nothing  -- defensive; T.splitOn never returns []
    [_]    -> Nothing  -- m at depth 1 -> parent has no parent
    _      ->
      let parentParts = init mParts
          mOwnChild   = last mParts
      in case stripListPrefix parentParts eParts of
           Just (eChild : _) | eChild /= mOwnChild ->
             Just $! T.intercalate "." (parentParts ++ [eChild])
           _ -> Nothing

-- | @stripListPrefix pfx xs@ — drop @pfx@ from the front of @xs@,
-- returning the remainder, or 'Nothing' if @pfx@ isn't a prefix.
-- Equivalent in spirit to "Data.List".'Data.List.stripPrefix' but kept
-- local so the import surface stays small.
stripListPrefix :: Eq a => [a] -> [a] -> Maybe [a]
stripListPrefix []     ys     = Just ys
stripListPrefix (_:_)  []     = Nothing
stripListPrefix (x:xs) (y:ys)
  | x == y    = stripListPrefix xs ys
  | otherwise = Nothing

-- ---------------------------------------------------------------------------
-- Per-module score

-- | Per-module summary returned by 'scoreModule'. Strict fields throughout
-- because every value is consumed unconditionally by the renderer / JSON
-- encoder downstream.
data ModuleScore = ModuleScore
  { sModule      :: !Text
  , sSize        :: !Int
    -- ^ |m| — total defs declared in the module.
  , sInternal    :: !Int
  , sExternal    :: !Int
  , sLcom        :: !Double
  , sSpread      :: !Int
  , sCa          :: !Int
  , sCe          :: !Int
  , sInstability :: !Double
  , sAbstract    :: !Double
  , sDistance    :: !Double
  , sIncoherence :: !Double
  , sTopSibling  :: !TopSibling
    -- ^ The "Top out-of-place external" finding for this module. See
    -- 'TopSibling' for the four possible states.
  } deriving (Show)

-- | Outcome of the sibling-subtree analysis for one module.
--
-- Reports the modal /sibling subtree/ — a child of @parent(m)@ that is
-- not @m@'s own subtree — which is the actionable leak signal.
data TopSibling
  = TSNoExternals
    -- ^ Module has no external out-edges; nothing to report.
  | TSRootModule
    -- ^ Module is at depth 1; @parent(m)@ has no parent, so there is no
    -- sibling-subtree concept.
  | TSNoSiblingLeak
    -- ^ Module has externals but none land in a sibling subtree; the
    -- leaks are all to uncles / unrelated modules.
  | TSSibling !Text !Int !Double
    -- ^ @TSSibling prefix count share@ — the modal sibling subtree
    -- @prefix@, the number of externals that landed there, and the
    -- share of total externals that represents.
  deriving (Show)

-- | Combine the per-module def list with the edge-pass accumulator to
-- produce a ranked score. All ratios are guarded against div-by-zero;
-- the score itself is well-defined even for tiny modules (we delegate
-- the "too small" filter to the caller via 'optMinSize').
scoreModule
  :: Index
  -> Text
  -> [Int]                -- ^ defs in this module
  -> ModAcc
  -> ModuleScore
scoreModule ix m defIds ModAcc{..} =
  let !sz    = length defIds
      -- Abstractness: count defs in shapes that are "structural"
      -- rather than computational.
      !aCount = abstractnessCount ix defIds
      !aRatio = ratio aCount sz
      -- LCOM\': what fraction of cross-module edges escape? When the
      -- module has no internal- or external-class edges at all there is
      -- nothing to measure; treat as 0 (perfectly cohesive) rather than
      -- the 1 - 0/0 = 1 the naive formula would give, which would
      -- spuriously flag inert leaf modules.
      !intExt = aInternal + aExternal
      !lcom   = if intExt == 0 then 0 else 1 - ratio aInternal intExt
      -- Instability.
      !ca   = Set.size aInMods
      !ce   = Set.size aOutMods
      !inst = ratio ce (ca + ce)
      -- Spread.
      !spread = Map.size aExtPrefixHits
      -- Distance from the main sequence: A + I should be ~1.
      !dist = abs (aRatio + inst - 1)
      -- The headline ranking number.
      !inc  = lcom * log (1 + fromIntegral spread)
                   * abs (dist - (1 - inst))
      !topSib = topSiblingFinding m aExternal aSiblingHits
  in ModuleScore
       { sModule      = m
       , sSize        = sz
       , sInternal    = aInternal
       , sExternal    = aExternal
       , sLcom        = lcom
       , sSpread      = spread
       , sCa          = ca
       , sCe          = ce
       , sInstability = inst
       , sAbstract    = aRatio
       , sDistance    = dist
       , sIncoherence = inc
       , sTopSibling  = topSib
       }

-- | Count the abstract-shape defs in a module. We have no dedicated
-- "interface" concept in Agda's schema; we proxy with /datatypes/ — they
-- play the same "this is a shape, not an operation" role as records do.
-- Holes and postulates count too: a hole is a *promise of* a definition;
-- a postulate is an axiomatic shape with no body.
abstractnessCount :: Index -> [Int] -> Int
abstractnessCount ix = foldl' step 0
  where
    step !n i =
      let d = defAt ix i
          k = defKind d
          s = defState d
          hit = k == KRecord
             || k == KDatatype
             || s == Postulate
             || s == Hole
      in if hit then n + 1 else n

-- | Pick the modal sibling subtree, classifying the four no-signal
-- cases ('TopSibling') so the renderer can produce a sensible finding
-- line. Strict fold; ties are broken by 'Map.toList' order
-- (lexicographic on prefix), which is stable across runs.
topSiblingFinding :: Text -> Int -> Map.Map Text Int -> TopSibling
topSiblingFinding m !ex hits
  | ex <= 0       = TSNoExternals
  | atRootDepth   = TSRootModule
  | Map.null hits = TSNoSiblingLeak
  | otherwise =
      let !(p, n) = foldl' best (T.empty, 0) (Map.toList hits)
          best old@(_, !bn) new@(_, !nn)
            | nn > bn   = new
            | otherwise = old
          !share = fromIntegral n / fromIntegral ex :: Double
      in TSSibling p n share
  where
    -- Depth = number of dot-components; @T.splitOn "."@ never returns
    -- @[]@ so this matches the "m at depth 1" case used by
    -- 'siblingPrefixOf'.
    atRootDepth = case T.splitOn "." m of
      [_] -> True
      _   -> False

-- | Safe ratio that yields 0 when the denominator is non-positive.
ratio :: Int -> Int -> Double
ratio _ 0 = 0
ratio a b = fromIntegral a / fromIntegral b

-- ---------------------------------------------------------------------------
-- Rendering

-- | One line of the "Top out-of-place external" section. Reports the
-- modal /sibling subtree/ leak when one exists, and surfaces the three
-- no-signal cases ('TopSibling') explicitly rather than emitting a
-- misleading prefix.
renderFinding :: ModuleScore -> String
renderFinding ModuleScore{..} =
  let modName = T.unpack sModule
  in case sTopSibling of
       TSNoExternals     -> "  " ++ modName ++ " - no external out-edges"
       TSRootModule      ->
         "  " ++ modName
              ++ " - (no sibling subtree available - m is at root)"
       TSNoSiblingLeak   ->
         "  " ++ modName
              ++ " - (no sibling-subtree leak; externals leak elsewhere)"
       TSSibling pfx n share ->
         "  " ++ modName ++ ": "
            ++ printf "%.0f%% (%d/%d) of externals share prefix \"%s\""
                      (share * 100) n sExternal (T.unpack pfx)

fmt2 :: Double -> String
fmt2 = printf "%.2f"

-- ---------------------------------------------------------------------------
-- JSON

strataJson :: Options -> Int -> Int -> Int -> [ModuleScore] -> A.Value
strataJson opts nModulesTotal nModulesScored nModulesSkipped topRows =
  A.object
    [ "subcommand" .= ("strata" :: Text)
    , "options"    .= strataOptionsJson opts
    , "stats"      .= A.object
        [ "modules_total"           .= nModulesTotal
        , "modules_scored"          .= nModulesScored
        , "modules_skipped_by_size" .= nModulesSkipped
        ]
    , "rows" .= A.toJSON (zipWith (rowJson) [1 :: Int ..] topRows)
    ]

strataOptionsJson :: Options -> A.Value
strataOptionsJson Options{..} = A.object
  [ "top_n"                 .= optTopN
  , "min_size"              .= optMinSize
  , "exclude_module_regex"  .= optExcludeModuleRegex
  ]

rowJson :: Int -> ModuleScore -> A.Value
rowJson rank ModuleScore{..} = A.object $
  [ "rank"        .= rank
  , "module"      .= sModule
  , "size"        .= sSize
  , "internal"    .= sInternal
  , "external"    .= sExternal
  , "lcom_prime"  .= sLcom
  , "spread"      .= sSpread
  , "ca"          .= sCa
  , "ce"          .= sCe
  , "instability" .= sInstability
  , "abstractness" .= sAbstract
  , "distance"    .= sDistance
  , "incoherence" .= sIncoherence
  , "top_sibling_status" .= siblingStatusTag sTopSibling
  ] ++ siblingFields
  where
    -- Small tag so JSON consumers can dispatch without parsing the
    -- human message. Mirrors the four 'TopSibling' constructors.
    siblingStatusTag :: TopSibling -> Text
    siblingStatusTag TSNoExternals     = "no_externals"
    siblingStatusTag TSRootModule      = "root_module"
    siblingStatusTag TSNoSiblingLeak   = "no_sibling_leak"
    siblingStatusTag TSSibling{}       = "sibling"

    siblingFields = case sTopSibling of
      TSSibling p n share ->
        [ "top_sibling_prefix"       .= p
        , "top_sibling_prefix_count" .= n
        , "top_sibling_prefix_share" .= share
        ]
      _ -> []
