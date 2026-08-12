{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Horizon: eccentricity and proof geometry.
--
-- For every definition we compute two scalars:
--
--   * Forward eccentricity  ε⁺(v) = max distance from v to any
--     reachable /leaf/ (axiom / postulate / primitive — selectable).
--   * Backward eccentricity ε⁻(v) = max distance from any /root/
--     theorem to v.
--
-- The project-level numbers fall out directly:
--
--   * diameter  = max ε⁺;
--   * radius    = min ε⁺ over theorem-roots;
--   * periphery = nodes hitting the diameter;
--   * center    = nodes hitting the radius.
--
-- We rank nodes by @(ε⁺ + ε⁻, ε⁺ − ε⁻)@ descending — the "deepest
-- balanced" results first, then the most-axiom-distant tail.
-- @load-bearing@ is a /flow/ measure, @horizon@ is a /distance/
-- measure: a lemma can be high-flow yet shallow, or peripheral yet
-- load-bearing.
--
-- ---------------------------------------------------------------------
-- Algorithm
-- ---------------------------------------------------------------------
--
-- The real corpus contains cycles (data types co-reference their
-- constructors; mutually recursive lemmas; …), so a raw longest-path DP
-- over 'Index' would bail on a non-DAG. We therefore SCC-condense first
-- ('Data.Graph.stronglyConnCompR') and run two DPs on the
-- /condensation/ DAG:
--
--   * /forward DP (sinks-first)/ — ε⁺(scc) = 0 if the SCC contains any
--     leaf node, else @1 + max ε⁺(child SCC)@.
--   * /backward DP (sources-first)/ — ε⁻(scc) = 0 if the SCC contains
--     any root node, else @1 + max ε⁻(parent SCC)@.
--
-- Per-node eccentricities are inherited from the containing SCC. Nodes
-- that don't reach any leaf (resp. don't have any root reaching them)
-- get a sentinel @-1@ in the output; ranking sorts them to the bottom.
--
-- Per-module histogram: bucket every node's ε⁺ by its 'defModule'. A
-- module with a sharp peak is a /natural seam/ — every def in it sits
-- at the same depth, suggesting an abstraction boundary worth
-- preserving. A module whose buckets fan out is a candidate for
-- splitting.
module AgdaOptimization.Horizon
  ( Options(..)
  , LeavesMode(..)
  , RootsMode(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad             ( when )
import           AgdaOptimization.Condense ( Condensation(..), buildCondensation )
import qualified Data.IntMap.Strict        as IM
import qualified Data.IntSet               as IS
import           Data.List                 ( sortBy )
import qualified Data.Map.Strict           as Map
import           Data.Ord                  ( Down(..), comparing )
import           Data.Text                 ( Text )
import qualified Data.Text                 as T
import qualified Data.Vector               as V
import           System.IO                 ( hPutStrLn, stderr )

import qualified Data.Aeson                as A
import           Data.Aeson                ( (.=) )

import           AgdaGraph.Index           ( Index(..), defAt )
import           AgdaGraph.Schema          ( Access(..), Definition(..)
                                           , Kind(..), State(..) )

import           AgdaOptimization.FlagSpec ( FlagSpec(..), EnumErr(..)
                                           , SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Common ( computeExcludedSet, externalsSummaryHasRows
                                         , notFoundational, terminals )
import           AgdaOptimization.Report   ( GlobalOpts(..), OutFormat(..)
                                           , renderTable, emitJsonReport
                                           , withHumanReport )

------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------

-- | Which nodes are considered /leaves/ for ε⁺.
data LeavesMode
  = LvPostulatesAxioms
    -- ^ Default. Postulates (axioms) plus any KPrimitive node with no
    -- outgoing edge.
  | LvTerminalLeaves
    -- ^ Any node with no outgoing edge — useful for graphs scrubbed of
    -- their externals (@agda-deps --no-externals@).
  deriving (Show, Eq)

-- | Which nodes are considered /roots/ for ε⁻.
data RootsMode
  = RtPublicTheorems
    -- ^ Default. Public defs whose module is not part of the Agda
    -- standard prelude (@Agda.Builtin.*@ / @Agda.Primitive.*@).
  | RtTerminals
    -- ^ Nodes with no incoming edges (true terminals — nothing depends
    -- on them).
  deriving (Show, Eq)

-- | User-facing options. The CLI flags map one-to-one onto these
-- fields; see 'parseOptions' for the spellings.
data Options = Options
  { optTopN             :: !Int
    -- ^ Maximum rows of the ranked table to print. Default 50.
  , optLeaves           :: !LeavesMode
    -- ^ Which nodes count as leaves. Default 'LvPostulatesAxioms'.
  , optLeavesExplicit   :: !Bool
    -- ^ 'True' iff the user passed @--leaves@ on the CLI. Drives the
    -- auto-fallback from 'LvPostulatesAxioms' to 'LvTerminalLeaves'
    -- when the default-resolved leaf set is empty (typical when
    -- @agda-deps --no-externals@ stripped all foundational postulates
    -- upstream). Explicit @--leaves=postulates-axioms@ keeps the
    -- empty-set behaviour — the user has signalled intent.
  , optRoots            :: !RootsMode
    -- ^ Which nodes count as roots. Default 'RtPublicTheorems'.
  , optModuleHist       :: !Bool
    -- ^ Emit the per-module ε⁺ histogram. Default 'True'. Pass
    -- @--no-module-hist@ to opt out (handy for tiny corpora).
  , optExcludeNameRegex :: !Text
    -- ^ POSIX-ERE pattern matched against each definition's
    -- /unqualified/ name (last dot-component). Matching nodes are
    -- stripped from the ranked table /after/ the DP runs, so global
    -- statistics (diameter / radius / periphery membership) are NOT
    -- shifted by the filter. Empty string disables filtering.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optTopN             = 50
  , optLeaves           = LvPostulatesAxioms
  , optLeavesExplicit   = False
  , optRoots            = RtPublicTheorems
  , optModuleHist       = True
  , optExcludeNameRegex = T.empty
  }

-- | Declarative flag spec for the @horizon@ subcommand. Drives both
-- 'parseOptions' and 'applyConfig'. Each help line is verbatim from
-- 'AgdaOptimization.CLI.subFlags'.
--
-- @--leaves@ / @--roots@ are enum flags whose parser @Left@ is a bare
-- @"expected one of …"@, surfaced verbatim on the argv side
-- ('EnumVerbatim'). A @--leaves@ value (from CLI or YAML) also flips
-- 'optLeavesExplicit' to 'True', matching the "user explicitly chose"
-- semantics — the empty-set fallback to 'LvTerminalLeaves' is
-- suppressed.
--
-- @--no-module-hist@ is a 'SwitchPreGuard' switch (matched against the
-- raw token before 'splitFlag', so @--no-module-hist=x@ falls through
-- to the unknown-flag path); its YAML key is @module-hist@ and matches
-- the underlying field, not the negated CLI flag.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ EnumFlag "leaves" "--leaves=postulates-axioms|terminal-leaves    forward-leaf set (default postulates-axioms)"
      parseLeaves EnumVerbatim
      (\r o -> o { optLeaves = r, optLeavesExplicit = True })
  , EnumFlag "roots" "--roots=public-theorems|terminals             backward-root set (default public-theorems)"
      parseRoots EnumVerbatim (\r o -> o { optRoots = r })
  , SwitchFlag "no-module-hist" "--no-module-hist                              suppress per-module epsilon+ histogram"
      SwitchPreGuard (\o -> o { optModuleHist = False })
      (Just "module-hist") (\v o -> o { optModuleHist = v })
  , IntFlag "top-n" "--top-n=N                                     rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , TextFlag "exclude-name-regex" "--exclude-name-regex=PATTERN                  POSIX-ERE on unqualified name"
      (\p o -> o { optExcludeNameRegex = p })
  ]

-- | Hand-rolled CLI parser for the @horizon@ subcommand. Mirrors the
-- style used by every other 'AgdaOptimization' analysis.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "horizon" flagSpecs

parseLeaves :: String -> Either String LeavesMode
parseLeaves "postulates-axioms" = Right LvPostulatesAxioms
parseLeaves "terminal-leaves"   = Right LvTerminalLeaves
parseLeaves v                   =
  Left ("expected one of postulates-axioms|terminal-leaves, got " <> show v)

parseRoots :: String -> Either String RootsMode
parseRoots "public-theorems" = Right RtPublicTheorems
parseRoots "terminals"       = Right RtTerminals
parseRoots v                 =
  Left ("expected one of public-theorems|terminals, got " <> show v)

-- | Overlay the @horizon:@ YAML section onto a seed 'Options'.
--
-- A YAML-provided @leaves@ also flips 'optLeavesExplicit' to 'True',
-- matching the "user explicitly chose" semantics — the empty-set
-- fallback to 'LvTerminalLeaves' is suppressed.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "horizon" flagSpecs obj o0

------------------------------------------------------------------------
-- Leaf / root selection
------------------------------------------------------------------------

-- | Walk the index once and collect every node id that satisfies the
-- /leaf/ predicate for the chosen mode.
collectLeaves :: Index -> LeavesMode -> IS.IntSet
collectLeaves !ix = \case
  LvPostulatesAxioms ->
    V.ifoldl'
      (\ !acc i d ->
         if defState d == Postulate
            || (defKind d == KPrimitive && hasNoOutEdge i)
           then IS.insert i acc
           else acc)
      IS.empty (idxDefs ix)
  LvTerminalLeaves ->
    let !n = idxNodeCount ix
        go !acc i
          | i >= n   = acc
          | hasNoOutEdge i = go (IS.insert i acc) (i + 1)
          | otherwise = go acc (i + 1)
    in go IS.empty 0
  where
    hasNoOutEdge i =
      IS.null (IM.findWithDefault IS.empty i (idxForward ix))

-- | Collect every node id that satisfies the /root/ predicate.
collectRoots :: Index -> RootsMode -> IS.IntSet
collectRoots !ix = \case
  RtPublicTheorems ->
    V.ifoldl'
      (\ !acc i d ->
         if defAccess d == Public && notFoundational d
           then IS.insert i acc
           else acc)
      IS.empty (idxDefs ix)
  RtTerminals -> terminals ix


-- | Promote a node-level seed set to its SCCs. A multi-node SCC
-- inherits seed status if /any/ of its members were seeds — which is
-- the right reading both for leaves (the SCC reaches itself, hence a
-- leaf) and roots (the SCC has at least one root entry point).
seedsToSccs :: Condensation -> IS.IntSet -> IS.IntSet
seedsToSccs !cond !seeds =
  IS.foldl' (\ !acc v ->
               case IM.lookup v (cdSccOf cond) of
                 Just s  -> IS.insert s acc
                 Nothing -> acc)
            IS.empty seeds

------------------------------------------------------------------------
-- Eccentricity DPs
------------------------------------------------------------------------

-- | Forward eccentricity per SCC: longest path to a leaf SCC. Absent
-- key = doesn't reach any leaf.
--
-- Walks the condensation in /reverse/ topo order (sinks first); each
-- non-leaf SCC takes @1 + max@ over its forward children that have a
-- value.
forwardEccSCC :: Condensation -> IS.IntSet -> IM.IntMap Int
forwardEccSCC cond leafSccs =
  eccDP cond (reverse (cdTopo cond)) cdForward leafSccs

-- | Backward eccentricity per SCC: longest path /from/ a root SCC.
-- Walks the condensation forward (sources first); each non-root SCC
-- takes @1 + max@ over its parents that have a value.
backwardEccSCC :: Condensation -> IS.IntSet -> IM.IntMap Int
backwardEccSCC cond rootSccs =
  eccDP cond (cdTopo cond) cdReverse rootSccs

-- | Shared eccentricity DP over the condensation. Folds @order@ (the
-- topo order in the appropriate direction), seeding @0@ for SCCs in
-- @seeds@ and otherwise taking @1 + max@ over the neighbours given by
-- @neighbours cond@ that already have a value.
eccDP
  :: Condensation
  -> [Int]
  -> (Condensation -> IM.IntMap IS.IntSet)
  -> IS.IntSet
  -> IM.IntMap Int
eccDP !cond order neighbours !seeds =
  foldl' step IM.empty order
  where
    step !acc !scc
      | IS.member scc seeds = IM.insert scc 0 acc
      | otherwise =
          let kids = IM.findWithDefault IS.empty scc (neighbours cond)
              best = IS.foldl' bestStep Nothing kids
              bestStep !mb !k = case IM.lookup k acc of
                Just d  -> Just $! case mb of
                  Nothing -> d + 1
                  Just b  -> max b (d + 1)
                Nothing -> mb
          in case best of
               Just d  -> IM.insert scc d acc
               Nothing -> acc

-- | Lift an SCC-level ε map to a node-level map. Every node inherits
-- the value of its containing SCC; nodes whose SCC has no value
-- (didn't reach the seed set) are absent.
sccMapToNodeMap :: Condensation -> IM.IntMap Int -> IM.IntMap Int
sccMapToNodeMap !cond !sccMap =
  IM.foldlWithKey'
    (\acc scc v ->
       let mems = IM.findWithDefault IS.empty scc (cdMembers cond)
       in IS.foldl' (\ !m n -> IM.insert n v m) acc mems)
    IM.empty sccMap

------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------

-- | Entry point. Reads only the 'Index'; emits either a human-readable
-- table + optional histogram, or a self-describing JSON object.
--
-- /Leaf-set fallback./ If the user is on the default
-- @--leaves=postulates-axioms@ but the resolved leaf set is empty
-- (typical when @agda-deps --no-externals@ stripped every foundational
-- postulate upstream), we transparently fall back to
-- @--leaves=terminal-leaves@ and emit a stderr note. Explicit
-- @--leaves=postulates-axioms@ keeps the empty-set behaviour — that's
-- the user's deliberate choice.
run :: Index -> GlobalOpts -> Options -> IO ()
run !ix !gOpts !opts0 = do
  let !leafSet0      = collectLeaves ix (optLeaves opts0)
      !defaultEmpty  =     optLeaves opts0 == LvPostulatesAxioms
                        && not (optLeavesExplicit opts0)
                        && IS.null leafSet0
      !extSumPresent = externalsSummaryHasRows (idxExternalsSummary ix)

  when defaultEmpty $ do
    if extSumPresent
      then hPutStrLn stderr $
              "[horizon] note: --leaves=postulates-axioms resolved to empty"
           ++ " (idxExternalsSummary present — likely --no-externals upstream stripped"
           ++ " every foundational postulate;\n"
           ++ "          its names aren't in the in-memory node table so we can't"
           ++ " resurrect them as leaves);\n"
           ++ "          falling back to --leaves=terminal-leaves."
           ++ " Pass --leaves=postulates-axioms explicitly to error instead."
      else hPutStrLn stderr $
              "[horizon] note: --leaves=postulates-axioms resolved to empty (likely"
           ++ " --no-externals upstream);\n"
           ++ "          falling back to --leaves=terminal-leaves."
           ++ " Pass --leaves=postulates-axioms explicitly to error instead."

  let !opts
        | defaultEmpty = opts0 { optLeaves = LvTerminalLeaves }
        | otherwise    = opts0
      !leafSet
        | defaultEmpty = collectLeaves ix LvTerminalLeaves
        | otherwise    = leafSet0
      !rootSet = collectRoots  ix (optRoots opts)
      !cond    = buildCondensation ix
      !leafSccs = seedsToSccs cond leafSet
      !rootSccs = seedsToSccs cond rootSet
      !epPlusSCC  = forwardEccSCC  cond leafSccs
      !epMinusSCC = backwardEccSCC cond rootSccs
      !epPlus     = sccMapToNodeMap cond epPlusSCC
      !epMinus    = sccMapToNodeMap cond epMinusSCC

  -- Diagnostics. An empty leaf set or root set is a real degradation:
  -- the corresponding eccentricities will all be sentinel -1. Surface
  -- it so the caller doesn't read a blank table as "nothing wrong".
  when (IS.null leafSet) $
    hPutStrLn stderr
      "[horizon] no leaves under the chosen --leaves mode — ε⁺ will be empty."
  when (IS.null rootSet) $
    hPutStrLn stderr
      "[horizon] no roots under the chosen --roots mode — ε⁻ will be empty."

  let -- diameter & radius
      !diameter
        | IM.null epPlus = 0
        | otherwise      = maximum (IM.elems epPlus)
      -- Radius: minimum ε⁺ over /theorem-root/ nodes that actually
      -- have a value. Falls back to 0 if no root reaches a leaf.
      !radiusCandidates =
        [ d | r <- IS.toList rootSet
            , Just d <- [IM.lookup r epPlus] ]
      !radius
        | null radiusCandidates = 0
        | otherwise             = minimum radiusCandidates

      -- Periphery: every node with ε⁺ == diameter (only when diameter
      -- > 0 — otherwise everything below the diameter is "periphery"
      -- which is meaningless).
      !periphery
        | diameter <= 0 = IS.empty
        | otherwise = IM.foldlWithKey'
                        (\ !acc v d -> if d == diameter
                                          then IS.insert v acc else acc)
                        IS.empty epPlus
      !center
        | null radiusCandidates = IS.empty
        | otherwise = IM.foldlWithKey'
                        (\ !acc v d -> if d == radius
                                          then IS.insert v acc else acc)
                        IS.empty epPlus

      -- Exclude regex applies only to the ranked table.
      !excluded = computeExcludedSet ix (optExcludeNameRegex opts)

      -- Candidates: every node that has at least one of ε⁺ / ε⁻ set.
      -- Nodes that are wholly disconnected from both leaves and roots
      -- get filtered out — they don't have a meaningful "horizon".
      candidateIds :: [Int]
      !candidateIds =
        [ v | v <- [0 .. idxNodeCount ix - 1]
            , IM.member v epPlus || IM.member v epMinus
            , not (IS.member v excluded)
        ]

      ecc v = IM.findWithDefault (-1) v epPlus
      ecb v = IM.findWithDefault (-1) v epMinus
      -- Rank by (ε⁺ + ε⁻, ε⁺ − ε⁻) descending.
      !ranked = sortBy
        (comparing (\v ->
            let !ep = ecc v
                !em = ecb v
            in Down (ep + em, ep - em, ep)))
        candidateIds
      !topRows = take (optTopN opts) ranked

  when (not (IS.null excluded)) $
    hPutStrLn stderr $
      "[horizon] excluded " ++ show (IS.size excluded)
      ++ " definitions matching " ++ T.unpack (optExcludeNameRegex opts) ++ "."

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        horizonJson ix opts cond
                    leafSet rootSet
                    epPlus epMinus
                    diameter radius
                    periphery center
                    excluded topRows
    OutHuman -> withHumanReport gOpts "horizon" $ do
      putStrLn $ "# Horizon — top " ++ show (optTopN opts)
              ++ " (leaves: " ++ leavesLabel (optLeaves opts)
              ++ ", roots: "  ++ rootsLabel  (optRoots  opts) ++ ")"
      putStrLn $ "|V| = " ++ show (idxNodeCount ix)
              ++ ", |leaves| = " ++ show (IS.size leafSet)
              ++ ", |roots| = "  ++ show (IS.size rootSet)
              ++ ", |SCC| = "    ++ show (cdCount cond)
      putStrLn $ "diameter = " ++ show diameter
              ++ ", radius = "  ++ show radius
              ++ ", periphery = " ++ show (IS.size periphery)
              ++ ", center = "    ++ show (IS.size center)
      putStrLn ""

      putStrLn "## Ranked by (ε⁺ + ε⁻, ε⁺ − ε⁻)"
      putStrLn $ renderRanked ix topRows ecc ecb periphery center

      when (optModuleHist opts) $ do
        putStrLn ""
        putStrLn "## Per-module ε⁺ histogram"
        putStrLn $ renderModuleHist ix epPlus

------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------

renderRanked
  :: Index
  -> [Int]
  -> (Int -> Int)         -- ^ ε⁺
  -> (Int -> Int)         -- ^ ε⁻
  -> IS.IntSet            -- ^ periphery
  -> IS.IntSet            -- ^ center
  -> String
renderRanked ix rows ecc ecb periphery center
  | null rows = "  (no candidates — empty leaves or roots, or trivial graph)\n"
  | otherwise =
      let header = ["Rank","QName","Module","State","ε⁺","ε⁻","ε⁺+ε⁻","tag"]
          body   =
            [ [ show r
              , T.unpack (defName d)
              , T.unpack (defModule d)
              , stateLetter (defState d)
              , showEcc (ecc v)
              , showEcc (ecb v)
              , showSum (ecc v) (ecb v)
              , tagFor v
              ]
            | (r, v) <- zip [1 :: Int ..] rows
            , let !d = defAt ix v
            ]
      in renderTable header body
  where
    tagFor v
      | IS.member v periphery && IS.member v center = "periphery+center"
      | IS.member v periphery = "periphery"
      | IS.member v center    = "center"
      | ecb v == 0            = "root"
      | ecc v == 0            = "leaf"
      | otherwise             = ""

    showEcc (-1) = "-"
    showEcc d    = show d
    showSum a b
      | a < 0 || b < 0 = "-"
      | otherwise      = show (a + b)

-- | Per-module histogram of ε⁺. One row per module; columns are the
-- bucket counts in ascending bucket order. Sorted by descending peak
-- value (so /thin waists/ and /spikes/ are at the top of the table).
renderModuleHist :: Index -> IM.IntMap Int -> String
renderModuleHist !ix !epPlus
  | IM.null epPlus = "  (empty — no node reaches a leaf)\n"
  | otherwise =
      let !byModule = buildModuleHist ix epPlus

          -- module-level peak (max bucket count) for ranking
          peakOf bm = case IM.elems bm of
            [] -> 0
            xs -> maximum xs

          !rows = sortBy
            (comparing (\(_, bm) ->
                Down (peakOf bm, IM.size bm)))
            (Map.toList byModule)

          -- Render each module as "module  total  peak@d  buckets: 0:x 1:y …".
          renderRow (m, bm) =
            let buckets   = IM.toAscList bm
                !total    = sum (map snd buckets)
                (peakD, peakC) = peakOfBuckets buckets
                bucketStr = unwords
                  [ show d ++ ":" ++ show c | (d, c) <- buckets ]
            in [ T.unpack m
               , show total
               , show peakD ++ "@" ++ show peakC
               , bucketStr
               ]

          header = ["Module","Total","peakEps+@count","Buckets"]
          body   = map renderRow rows
      in renderTable header body

-- | Build the per-module ε⁺ bucket histogram once. Shared by the human
-- ('renderModuleHist') and JSON ('moduleHistJson') renderers, which
-- each apply their own downstream ordering to the result.
buildModuleHist :: Index -> IM.IntMap Int -> Map.Map Text (IM.IntMap Int)
buildModuleHist ix epPlus =
  let step :: Map.Map Text (IM.IntMap Int)
           -> Int -> Int -> Map.Map Text (IM.IntMap Int)
      step !acc v d =
        let m = defModule (defAt ix v)
            bump = IM.insertWith (+) d (1 :: Int)
        in Map.insertWith (IM.unionWith (+)) m (bump IM.empty) acc
  in IM.foldlWithKey' step Map.empty epPlus

-- | Peak @(bucket, count)@ over a module's ascending bucket list: the
-- highest-count bucket, ties resolved to the earliest bucket. @(-1,-1)@
-- for an empty list. Shared by the human and JSON renderers.
peakOfBuckets :: [(Int, Int)] -> (Int, Int)
peakOfBuckets =
  foldl' (\(bd, bc) (d, c) ->
            if c > bc then (d, c) else (bd, bc))
         (-1, -1)

------------------------------------------------------------------------
-- Display tags
------------------------------------------------------------------------

leavesLabel :: LeavesMode -> String
leavesLabel = \case
  LvPostulatesAxioms -> "postulates-axioms"
  LvTerminalLeaves   -> "terminal-leaves"

rootsLabel :: RootsMode -> String
rootsLabel = \case
  RtPublicTheorems -> "public-theorems"
  RtTerminals      -> "terminals"

stateLetter :: State -> String
stateLetter = \case
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"

------------------------------------------------------------------------
-- JSON rendering
------------------------------------------------------------------------

-- | Self-describing JSON object. Same conventions as the other
-- subcommands: @"subcommand"@ first, then @"options"@, then @"stats"@,
-- then the body.
horizonJson
  :: Index
  -> Options
  -> Condensation
  -> IS.IntSet            -- ^ leaf node ids.
  -> IS.IntSet            -- ^ root node ids.
  -> IM.IntMap Int        -- ^ ε⁺ per node.
  -> IM.IntMap Int        -- ^ ε⁻ per node.
  -> Int                  -- ^ diameter.
  -> Int                  -- ^ radius.
  -> IS.IntSet            -- ^ periphery.
  -> IS.IntSet            -- ^ center.
  -> IS.IntSet            -- ^ excluded by regex.
  -> [Int]                -- ^ ranked top-N node ids.
  -> A.Value
horizonJson ix opts cond leafSet rootSet epPlus epMinus
            diameter radius periphery center excluded rows =
  A.object $
    [ "subcommand" .= ("horizon" :: Text)
    , "options"    .= horizonOptionsJson opts
    , "stats"      .= A.object
        [ "n_nodes"           .= idxNodeCount ix
        , "n_scc"             .= cdCount cond
        , "n_leaves"          .= IS.size leafSet
        , "n_roots"           .= IS.size rootSet
        , "diameter"          .= diameter
        , "radius"            .= radius
        , "n_periphery"       .= IS.size periphery
        , "n_center"          .= IS.size center
        , "excluded_by_regex" .= IS.size excluded
        ]
    , "rows" .= A.toJSON
        (zipWith (rowJson ix epPlus epMinus periphery center)
                 [1 :: Int ..] rows)
    , "periphery" .= namesOf ix periphery
    , "center"    .= namesOf ix center
    ]
    ++ (if optModuleHist opts
          then [ "module_histogram" .= moduleHistJson ix epPlus ]
          else [])

horizonOptionsJson :: Options -> A.Value
horizonOptionsJson Options{..} = A.object
  [ "top_n"              .= optTopN
  , "leaves"             .= leavesLabel optLeaves
  , "roots"              .= rootsLabel  optRoots
  , "module_hist"        .= optModuleHist
  , "exclude_name_regex" .= optExcludeNameRegex
  ]

rowJson
  :: Index
  -> IM.IntMap Int
  -> IM.IntMap Int
  -> IS.IntSet
  -> IS.IntSet
  -> Int
  -> Int
  -> A.Value
rowJson ix epPlus epMinus periphery center rank v =
  let d   = defAt ix v
      ep  = IM.findWithDefault (-1) v epPlus
      em  = IM.findWithDefault (-1) v epMinus
      tag :: Text
      tag
        | IS.member v periphery && IS.member v center = "periphery+center"
        | IS.member v periphery = "periphery"
        | IS.member v center    = "center"
        | em == 0               = "root"
        | ep == 0               = "leaf"
        | otherwise             = ""
  in A.object
       [ "rank"      .= rank
       , "qname"     .= defName d
       , "module"    .= defModule d
       , "state"     .= stateLetter (defState d)
       , "eps_plus"  .= ep
       , "eps_minus" .= em
       , "eps_sum"   .= (if ep < 0 || em < 0 then (-1 :: Int) else ep + em)
       , "tag"       .= tag
       ]

-- | Per-module histogram as a JSON object: module -> {bucket :: count}.
moduleHistJson :: Index -> IM.IntMap Int -> A.Value
moduleHistJson !ix !epPlus =
  let !byModule = buildModuleHist ix epPlus
      rowJ (m, bm) =
        let buckets  = IM.toAscList bm
            !total   = sum (map snd buckets)
            (peakD, peakC) = peakOfBuckets buckets
        in A.object
             [ "module"  .= m
             , "total"   .= total
             , "peak"    .= A.object
                 [ "eps_plus" .= peakD
                 , "count"    .= peakC ]
             , "buckets" .= A.toJSON
                 [ A.object [ "eps_plus" .= d, "count" .= c ]
                 | (d, c) <- buckets ]
             ]
  in A.toJSON (map rowJ (Map.toAscList byModule))

-- | Marshal an 'IS.IntSet' of node ids to a JSON array of their QNames.
-- Order is ascending by id (i.e. the order in which the producer
-- listed them in 'egDefinitions'); downstream tooling that wants a
-- particular order should sort itself.
namesOf :: Index -> IS.IntSet -> A.Value
namesOf ix s = A.toJSON [ defName (defAt ix v) | v <- IS.toAscList s ]
