{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Proof-debt ledger.
--
-- A hole (@defState = Hole@) is a promise: every exported definition
-- in @ancestors(h)@ is conditional on filling @h@. We treat the open
-- holes (and optionally stub postulates) as the "debt" and rank them
-- by how much exported ground each would unlock.
--
-- The schedule is built via the standard /submodular greedy/ for max
-- coverage: at each step pick the hole whose remaining contribution
-- (cov-set minus already-covered) is largest. This is the textbook
-- @(1 - 1/e)@-approximation for the union-cover problem; for the
-- corpus sizes we expect (hundreds of holes, low thousands of
-- exports) the naive @O(|H| * |Exp|)@ per step is fine.
--
-- Entry-module heuristic: the in-memory 'Index' does not carry the
-- producer's @egEntryModule@. We therefore always fall back to
-- "everything 'Public'" for the exported set, and log the choice on
-- stderr. If 'Exp' is empty we fall back to true terminals (nodes
-- with no inbound edge).
module AgdaOptimization.Debt
  ( Options(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad        ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           Data.Foldable        ( foldl' )
import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.List            ( sortBy )
import qualified Data.Map.Strict      as Map
import           Data.Ord             ( Down(..), comparing )
import qualified Data.Set             as Set
import           Data.Text            ( Text )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           System.IO            ( hPutStrLn, stderr )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), ancestors, defAt, descendants )
import           AgdaGraph.Schema     ( Access(..), Definition(..)
                                      , ExternalsSummary(..), State(..) )

import           AgdaOptimization.Common ( lastSegment, notFoundational, terminals )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , withHumanOutput )

-- | User-facing options. Fields are documented inline; defaults below.
data Options = Options
  { optIncludePostulates   :: !Bool
    -- ^ Treat stub postulates as debt too. On by default — most
    -- mid-development corpora carry placeholder @postulate@s.
  , optIncludeFoundational :: !Bool
    -- ^ Include postulates from the Agda standard prelude
    -- (@Agda.Builtin.*@, @Agda.Primitive.*@). Off by default to keep
    -- the ledger focused on user-authored debt.
  , optTopN                :: !Int
    -- ^ Maximum rows of the greedy schedule to print.
  , optFoundationalInventory :: !Bool
    -- ^ When the project carries no actionable debt, emit a
    -- foundational-postulate inventory ("trusted base") grouped by
    -- module. On by default; @--no-foundational-inventory@ opts out.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optIncludePostulates     = True
  , optIncludeFoundational   = False
  , optTopN                  = 50
  , optFoundationalInventory = True
  }

-- | Declarative flag spec for the @debt@ subcommand. Drives both the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- The three boolean toggles are 'SwitchPreGuard' switches (matched
-- against the raw token before 'splitFlag', so @--flag=x@ falls through
-- to the unknown-flag path). YAML key naming matches the underlying
-- field, not the negated CLI flag: @include-postulates: false@
-- corresponds to @--no-include-postulates@ on the command line.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "top-n" "--top-n=N                       schedule rows (default 50)"
      (\n o -> o { optTopN = n })
  , SwitchFlag "include-foundational" "--include-foundational          treat Agda.Builtin.* / Agda.Primitive postulates as debt"
      SwitchPreGuard (\o -> o { optIncludeFoundational = True })
      (Just "include-foundational") (\v o -> o { optIncludeFoundational = v })
  , SwitchFlag "no-include-postulates" "--no-include-postulates         exclude stub postulates from debt"
      SwitchPreGuard (\o -> o { optIncludePostulates = False })
      (Just "include-postulates") (\v o -> o { optIncludePostulates = v })
  , SwitchFlag "no-foundational-inventory" "--no-foundational-inventory     suppress trusted-base table on clean projects"
      SwitchPreGuard (\o -> o { optFoundationalInventory = False })
      (Just "foundational-inventory") (\v o -> o { optFoundationalInventory = v })
  ]

-- | Hand-rolled CLI parser for the @debt@ subcommand. Two boolean
-- toggles plus an int. @--no-include-postulates@ flips the default
-- (defaultOptions has @optIncludePostulates = True@); see the
-- 'Options' field for the rationale.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "debt" flagSpecs

-- | Overlay the @debt:@ YAML section onto a seed 'Options'.
--
-- YAML key naming matches the underlying field, not the negated CLI
-- flag. So @include-postulates: false@ corresponds to
-- @--no-include-postulates@ on the command line.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "debt" flagSpecs obj o0

-- | Which heuristic was used to pick the "exported" set.
data ExpSource
  = ExpAllPublic    -- ^ All nodes with 'defAccess = Public'.
  | ExpTerminals    -- ^ Fallback: nodes with no inbound edge.
  deriving (Show, Eq)

-- | Which path the foundational inventory came from.
--
-- * 'InvFromDefs': walked 'postSetAll' over the in-memory 'Index';
--   fires when @--no-externals@ was NOT used upstream and there's a
--   real set of postulate-state defs in the graph.
-- * 'InvFromExternalsSummary': the project itself has no surviving
--   postulates (e.g. @agda-deps --no-externals@ stripped them) but the
--   wire 'egExternalsSummary' carries a diagnostic listing — render
--   from there so the inventory section isn't silently empty.
data InventorySource
  = InvFromDefs
  | InvFromExternalsSummary
  deriving (Show, Eq)

inventorySourceTag :: InventorySource -> Text
inventorySourceTag InvFromDefs             = "defs"
inventorySourceTag InvFromExternalsSummary = "externals_summary"

-- | Per-hole summary held during the schedule build.
data HoleInfo = HoleInfo
  { hiId   :: !Int
  , hiCov  :: !IS.IntSet
    -- ^ @ancestors(h) /\ Exp@ — the exports unlocked by filling @h@.
  } deriving (Show)

-- | One row of the final greedy schedule.
data ScheduleRow = ScheduleRow
  { srStep      :: !Int
  , srId        :: !Int
  , srCov       :: !Int
  , srGain      :: !Int      -- ^ marginal gain (=@|cov \\ covered|@ at pick time)
  , srCumPct    :: !Double   -- ^ cumulative covered as % of @|Exp|@
  } deriving (Show)

-- | Entry point. Reads only the 'Index'; emits either a human-readable
-- ledger or a JSON object, plus diagnostic notes to stderr.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let !defs = idxDefs ix
      !n    = V.length defs

      -- 1. Exported set Exp.
      (!expSet, !expSrc) = computeExported ix
      !nExp = IS.size expSet

      -- 2. Debt nodes.
      !holeSet       = collectByState defs Hole
      !postSetAll    = collectByState defs Postulate
      !postSetKept   = if optIncludeFoundational opts
                         then postSetAll
                         else IS.filter (notFoundational . defAt ix) postSetAll
      !debtSet
        | optIncludePostulates opts = IS.union holeSet postSetKept
        | otherwise                 = holeSet

      -- 3. Coverage per debt node: ancestors(h) /\ Exp.
      -- 'ancestors' is an independent BFS per node; spark them.
      !holeCovs =
        parMap rdeepseq
          (\i -> (i, IS.intersection (ancestors ix (IS.singleton i)) expSet))
          (IS.toList debtSet)
      holes :: [HoleInfo]
      !holes = [ HoleInfo i cov
               | (i, cov) <- holeCovs
               , not (IS.null cov)
               ]

      -- 4. Greedy schedule.
      !schedule = greedy holes nExp

      -- 5. Hole prereq edges within debt set.
      !prereqEdges = holePrereqEdges ix debtSet (mkCovMap holes)

      -- 6. Failed-module panel (derived from defState = Failed).
      !failedDefs = collectByState defs Failed
      !failedMods = uniqueModules ix failedDefs

      -- Stats.
      !fullyCovered = IS.size (foldl' (\acc h -> IS.union acc (hiCov h))
                                       IS.empty holes)
      !fullyProvable = nExp - fullyCovered
      !provablePct  = pctOf fullyProvable nExp

  -- Diagnostics on stderr.
  hPutStrLn stderr $
    "agda-optimization debt: Exp source = " ++ expSourceTag expSrc
      ++ " (|Exp|=" ++ show nExp ++ ", |defs|=" ++ show n ++ ")."
  when (optIncludePostulates opts && not (optIncludeFoundational opts)
        && IS.size postSetAll > IS.size postSetKept) $
    hPutStrLn stderr $
      "agda-optimization debt: filtered "
        ++ show (IS.size postSetAll - IS.size postSetKept)
        ++ " foundational postulate(s) (Agda.Builtin.* / Agda.Primitive.*); "
        ++ "pass --include-foundational to include them."

  -- Decide whether (and from where) to emit a foundational inventory.
  -- See 'InventorySource' for the two paths.
  let invSource :: Maybe InventorySource
      !invSource
        | not (optFoundationalInventory opts) = Nothing
        | not (IS.null holeSet)               = Nothing
        | not (IS.null postSetKept)           = Nothing
        | not (null holes)                    = Nothing
        | not (IS.null postSetAll)            = Just InvFromDefs
        | externalsSummaryHasRows (idxExternalsSummary ix)
                                              = Just InvFromExternalsSummary
        | otherwise                           = Nothing

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        debtJson ix opts expSrc nExp holeSet postSetKept postSetAll
                 fullyProvable schedule prereqEdges failedMods
                 invSource
    OutHuman -> withHumanOutput (gOutPath gOpts) $ do
      putStrLn $ renderHeader opts (IS.size postSetKept)
      putStrLn ""
      putStrLn $ renderKPIs nExp (IS.size holeSet)
                             (IS.size postSetKept)
                             (optIncludePostulates opts)
                             fullyProvable provablePct
      putStrLn ""

      if null holes
        then do
          putStrLn "No proof debt found in the visible graph."
          when (optIncludePostulates opts) $
            putStrLn "No stub postulates either (per the included-set rules)."
          case invSource of
            Just InvFromDefs -> do
              putStrLn ""
              putStrLn $ renderFoundationalInventory ix postSetAll
            Just InvFromExternalsSummary -> do
              putStrLn ""
              putStrLn $ renderFoundationalInventoryFromSummary
                          (idxExternalsSummary ix)
            Nothing -> pure ()
        else do
          putStrLn $ "## Greedy schedule (top " ++ show (optTopN opts) ++ ")"
          putStrLn $ renderSchedule ix opts schedule

      -- Hole-prereq panel.
      putStrLn ""
      putStrLn "## Hole-prereq edges (capped at 10)"
      putStrLn $ renderPrereqs ix prereqEdges

      -- Failed-module panel.
      putStrLn ""
      putStrLn "## Failed modules (unknown debt — NOT folded above)"
      putStrLn $ renderFailedPanel failedMods (IS.size failedDefs)

-- ---------------------------------------------------------------------
-- Exported set
-- ---------------------------------------------------------------------

-- | Build the exported set from the index. Always uses the
-- "all-Public" heuristic; falls through to terminals if that produces
-- an empty set. Reports which branch was taken via the 'ExpSource'.
computeExported :: Index -> (IS.IntSet, ExpSource)
computeExported ix =
  let !defs   = idxDefs ix
      !publics = V.ifoldl' addPublic IS.empty defs
      addPublic !acc i d
        | defAccess d == Public = IS.insert i acc
        | otherwise             = acc
  in if IS.null publics
       then (terminals ix, ExpTerminals)
       else (publics, ExpAllPublic)

-- ---------------------------------------------------------------------
-- Hole / postulate selection
-- ---------------------------------------------------------------------

collectByState :: V.Vector Definition -> State -> IS.IntSet
collectByState defs st =
  V.ifoldl' (\ !acc i d -> if defState d == st then IS.insert i acc else acc)
            IS.empty defs


-- ---------------------------------------------------------------------
-- Greedy schedule (submodular max-coverage)
-- ---------------------------------------------------------------------

-- | Standard greedy: at each step, pick the hole with the largest
-- marginal gain, append it to the schedule, fold its cov into the
-- running covered set. Stop when no remaining hole adds anything.
greedy :: [HoleInfo] -> Int -> [ScheduleRow]
greedy holes0 nExp = go 1 IS.empty holes0 []
  where
    go !_ !_ [] acc = reverse acc
    go !step !covered candidates acc =
      let scored = [ (h, IS.size (IS.difference (hiCov h) covered))
                   | h <- candidates ]
          !best  = foldl' pickBigger Nothing scored
          pickBigger Nothing       cand@(_, g) = if g > 0 then Just cand else Nothing
          pickBigger m@(Just (_, bg)) cand@(_, g)
            | g > bg    = Just cand
            | otherwise = m
      in case best of
           Nothing            -> reverse acc
           Just (h, gain) ->
             let !covered' = IS.union covered (hiCov h)
                 !row      = ScheduleRow
                              { srStep   = step
                              , srId     = hiId h
                              , srCov    = IS.size (hiCov h)
                              , srGain   = gain
                              , srCumPct = pctOf (IS.size covered') nExp
                              }
                 !rest     = [ c | c <- candidates, hiId c /= hiId h ]
             in go (step + 1) covered' rest (row : acc)

-- ---------------------------------------------------------------------
-- Hole-prereq mini-DAG
-- ---------------------------------------------------------------------

-- | Edge @A -> B@ iff @B@ is in @descendants(A) /\ debtSet@ —
-- i.e. filling @A@ depends, transitively, on @B@ being filled.
--
-- Each edge is annotated with @|cov(A) /\ cov(B)|@ ("shared exports").
-- Sorted descending by shared count; capped at 10 by the renderer.
holePrereqEdges :: Index -> IS.IntSet -> IM.IntMap IS.IntSet
                -> [(Int, Int, Int)]
holePrereqEdges ix debtSet covByHole =
  let pairs =
        [ (a, b, shared)
        | a <- IS.toList debtSet
        , let down = IS.intersection (descendants ix (IS.singleton a)) debtSet
        , b <- IS.toList down
        , let ca     = IM.findWithDefault IS.empty a covByHole
              cb     = IM.findWithDefault IS.empty b covByHole
              !shared = IS.size (IS.intersection ca cb)
        ]
  in sortBy (comparing (\(_, _, s) -> Down s)) pairs

mkCovMap :: [HoleInfo] -> IM.IntMap IS.IntSet
mkCovMap = foldl' (\acc h -> IM.insert (hiId h) (hiCov h) acc) IM.empty

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

renderHeader :: Options -> Int -> String
renderHeader opts kStubPost =
  "# Proof-debt ledger — top "
    ++ show (optTopN opts)
    ++ " (postulates="
    ++ show kStubPost
    ++ ", foundational="
    ++ (if optIncludeFoundational opts then "on" else "off")
    ++ ")"

renderKPIs :: Int -> Int -> Int -> Bool -> Int -> Double -> String
renderKPIs nExp nHoles nStub includeStub provable provablePct =
  unlines $
    [ "Exp size                 : " ++ show nExp
    , "Open holes               : " ++ show nHoles
    ]
    ++ ( if includeStub
           then [ "Stub postulates          : " ++ show nStub ]
           else []
       )
    ++ [ "Currently fully provable : "
           ++ show provable ++ " / " ++ show nExp
           ++ "  (" ++ fmtPct provablePct ++ ")"
       ]

-- | Schedule rows are sorted purely by greedy order. We render at
-- most 'optTopN' rows; if the schedule is shorter than that we just
-- print what we have.
renderSchedule :: Index -> Options -> [ScheduleRow] -> String
renderSchedule ix opts rows =
  let !rows' = take (optTopN opts) rows
      header = ["Step", "QName", "Module", "State", "cov", "Δ", "cum %"]
      body   = map (rowCells ix) rows'
      bar    = barChart (map srGain rows')
  in renderTable header body
       ++ ( if null rows' then ""
              else "\nGain bar (one cell per scheduled hole, scaled to max Δ):\n  "
                     ++ bar ++ "\n"
          )

rowCells :: Index -> ScheduleRow -> [String]
rowCells ix ScheduleRow{..} =
  let d = defAt ix srId
  in [ show srStep
     , T.unpack (defName d)
     , T.unpack (defModule d)
     , stateTag (defState d)
     , show srCov
     , show srGain
     , fmtPct srCumPct
     ]

-- | Render gains as a coarse bar (10-step scaling). Cheap eye-candy;
-- the table already carries the numbers.
barChart :: [Int] -> String
barChart [] = ""
barChart gs =
  let !mx = maximum gs
      bucket g
        | mx <= 0   = ' '
        | otherwise = scale (fromIntegral g / fromIntegral mx :: Double)
      scale r
        | r >= 0.875 = '#'
        | r >= 0.625 = '='
        | r >= 0.375 = '-'
        | r >  0     = '.'
        | otherwise  = ' '
  in map bucket gs

renderPrereqs :: Index -> [(Int, Int, Int)] -> String
renderPrereqs _  []    = "(none)"
renderPrereqs ix edges =
  let take10 = take 10 edges
      line (a, b, s) =
        "  " ++ T.unpack (defName (defAt ix a))
             ++ " -> "
             ++ T.unpack (defName (defAt ix b))
             ++ "  (shared = " ++ show s ++ ")"
  in unlines (map line take10)

-- | Does the externals summary carry any postulate rows worth
-- rendering? Used to decide between the two inventory paths.
externalsSummaryHasRows :: Maybe ExternalsSummary -> Bool
externalsSummaryHasRows Nothing                       = False
externalsSummaryHasRows (Just (ExternalsSummary _ pm)) =
  any (not . null) (Map.elems pm)

-- | Foundational-postulate inventory: group every Postulate-state def
-- (foundational ones included) by module, sort modules by descending
-- count (alphabetic tie-break), and render a table with up to 3
-- example short names per module.
--
-- Only emitted when the project carries no actionable debt; intended
-- to answer "is the trusted base smaller this release than last?".
renderFoundationalInventory :: Index -> IS.IntSet -> String
renderFoundationalInventory ix postSetAll =
  let -- Strict fold: bucket post-state defs by module name.
      addOne :: Map.Map Text IS.IntSet -> Int -> Map.Map Text IS.IntSet
      addOne !acc i =
        let d  = defAt ix i
            !m = defModule d
        in Map.insertWith IS.union m (IS.singleton i) acc
      !byModule = IS.foldl' addOne Map.empty postSetAll

      -- Sort: descending by count, alphabetic tie-break.
      cmp (m1, s1) (m2, s2) =
        case compare (IS.size s2) (IS.size s1) of
          EQ -> compare m1 m2
          o  -> o
      !rows = sortBy cmp (Map.toList byModule)

      totalPost = IS.size postSetAll
      totalMods = Map.size byModule

      rowCells' (m, s) =
        let !n      = IS.size s
            shorts  = map (lastSegment . defName . defAt ix) (IS.toList s)
            !take3  = take 3 shorts
            ellipsis = if n > 3 then ["..."] else []
            !exs    = T.intercalate ", " (take3 ++ map T.pack ellipsis)
        in [T.unpack m, show n, T.unpack exs]

      header = ["Module", "Postulates", "Examples"]
      body   = map rowCells' rows
  in "## Foundational postulates (trusted base)\n\n"
       ++ renderTable header body
       ++ "\nTotal: " ++ show totalPost
       ++ " postulate" ++ (if totalPost == 1 then "" else "s")
       ++ " across "  ++ show totalMods
       ++ " module"   ++ (if totalMods == 1 then "" else "s")
       ++ "."

-- | Render the foundational-postulate inventory from the producer's
-- @externals_summary@ diagnostic (instead of walking the in-memory
-- 'Index'). Same table shape as 'renderFoundationalInventory'; the
-- header line tells the user *why* this path fired so an empty
-- @postSetAll@ doesn't read as "no externals at all" by mistake.
--
-- The summary's @postulates_by_module@ already carries short
-- (unqualified) names, so we don't shorten again. Modules without any
-- postulates are skipped (a module can show up in the summary if it
-- was external but contained only 'Defined' / 'Hole' state defs —
-- there's nothing to put in the inventory for those).
renderFoundationalInventoryFromSummary :: Maybe ExternalsSummary -> String
renderFoundationalInventoryFromSummary Nothing = ""
renderFoundationalInventoryFromSummary (Just (ExternalsSummary _mods pm)) =
  let -- Only modules with at least one postulate make the table.
      rowsRaw = [ (m, ps) | (m, ps) <- Map.toList pm, not (null ps) ]

      cmp (m1, p1) (m2, p2) =
        case compare (length p2) (length p1) of
          EQ -> compare m1 m2
          o  -> o
      !rows = sortBy cmp rowsRaw

      totalPost = sum (map (length . snd) rows)
      totalMods = length rows

      rowCells' (m, ps) =
        let !n      = length ps
            !take3  = take 3 ps
            ellipsis = if n > 3 then ["..."] else []
            !exs    = T.intercalate ", " (take3 ++ map T.pack ellipsis)
        in [T.unpack m, show n, T.unpack exs]

      header = ["Module", "Postulates", "Examples"]
      body   = map rowCells' rows
  in "## Foundational postulates (trusted base)\n"
       ++ "   (from externals_summary; v2 JSON's --no-externals upstream stripped the postulate nodes)\n\n"
       ++ renderTable header body
       ++ "\nTotal: " ++ show totalPost
       ++ " postulate" ++ (if totalPost == 1 then "" else "s")
       ++ " across "  ++ show totalMods
       ++ " module"   ++ (if totalMods == 1 then "" else "s")
       ++ "."

renderFailedPanel :: [Text] -> Int -> String
renderFailedPanel mods nDefs
  | null mods = "(no failed modules)"
  | otherwise =
      let names = T.intercalate ", " mods
      in "F modules: " ++ show (length mods)
          ++ " (" ++ show nDefs ++ " F-state def(s)) — names: "
          ++ T.unpack names ++ "\n"
          ++ "WARNING: schedule is computed on the visible graph; "
          ++ "resolving these may change rankings."

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

uniqueModules :: Index -> IS.IntSet -> [Text]
uniqueModules ix s =
  let go acc i = Set.insert (defModule (defAt ix i)) acc
      !set = IS.foldl' go Set.empty s
  in Set.toAscList set

expSourceTag :: ExpSource -> String
expSourceTag ExpAllPublic = "all-Public defs"
expSourceTag ExpTerminals = "terminals (no Public defs found)"

stateTag :: State -> String
stateTag Defined   = "D"
stateTag Postulate = "P"
stateTag Hole      = "H"
stateTag Failed    = "F"

-- | Percentage 'a'/'b' guarded against division by zero.
pctOf :: Int -> Int -> Double
pctOf a b
  | b <= 0    = 0
  | otherwise = 100 * fromIntegral a / fromIntegral b

----------------------------------------------------------------------
-- JSON rendering. See the schema in 'AgdaOptimization.Report'.

debtJson
  :: Index
  -> Options
  -> ExpSource             -- ^ Heuristic used for Exp.
  -> Int                   -- ^ |Exp|.
  -> IS.IntSet             -- ^ Open holes.
  -> IS.IntSet             -- ^ Stub postulates (post foundational filter).
  -> IS.IntSet             -- ^ All postulates (incl. foundational).
  -> Int                   -- ^ Currently fully provable count.
  -> [ScheduleRow]
  -> [(Int, Int, Int)]     -- ^ Hole-prereq edges (src, dst, shared).
  -> [Text]                -- ^ Failed-module names.
  -> Maybe InventorySource -- ^ Inventory source ('Nothing' = no inventory).
  -> A.Value
debtJson ix opts expSrc nExp holeSet postSetKept postSetAll
         fullyProvable schedule prereqEdges failedMods invSource =
  -- Emit the body of @foundational_inventory@ + the matching
  -- @foundational_inventory_source@ tag together. When 'invSource' is
  -- 'Nothing' neither field appears, mirroring the original wire shape.
  let inventoryFields = case invSource of
        Nothing -> []
        Just InvFromDefs ->
          [ "foundational_inventory"
              .= foundationalInventoryJson ix postSetAll
          , "foundational_inventory_source"
              .= inventorySourceTag InvFromDefs
          ]
        Just InvFromExternalsSummary ->
          [ "foundational_inventory"
              .= foundationalInventoryFromSummaryJson (idxExternalsSummary ix)
          , "foundational_inventory_source"
              .= inventorySourceTag InvFromExternalsSummary
          ]
  in A.object $
       [ "subcommand" .= ("debt" :: Text)
       , "options"    .= debtOptionsJson opts
       , "stats"      .= A.object
           [ "exp_size"                 .= nExp
           , "open_holes"               .= IS.size holeSet
           , "stub_postulates"          .= IS.size postSetKept
           , "currently_fully_provable" .= fullyProvable
           , "exp_source"               .= expSourceTag expSrc
           ]
       , "schedule"        .= A.toJSON (map (scheduleRowJson ix) schedule)
       , "prereqs"         .= A.toJSON (map (prereqEdgeJson ix) prereqEdges)
       , "failed_modules"  .= failedMods
       ]
       ++ inventoryFields

debtOptionsJson :: Options -> A.Value
debtOptionsJson Options{..} = A.object
  [ "include_postulates"      .= optIncludePostulates
  , "include_foundational"    .= optIncludeFoundational
  , "top_n"                   .= optTopN
  , "foundational_inventory"  .= optFoundationalInventory
  ]

scheduleRowJson :: Index -> ScheduleRow -> A.Value
scheduleRowJson ix ScheduleRow{..} =
  let d = defAt ix srId
  in A.object
       [ "step"    .= srStep
       , "qname"   .= defName d
       , "module"  .= defModule d
       , "state"   .= stateTag (defState d)
       , "cov"     .= srCov
       , "gain"    .= srGain
       , "cum_pct" .= srCumPct
       ]

prereqEdgeJson :: Index -> (Int, Int, Int) -> A.Value
prereqEdgeJson ix (a, b, shared) = A.object
  [ "src"    .= defName (defAt ix a)
  , "dst"    .= defName (defAt ix b)
  , "shared" .= shared
  ]

-- | Build the foundational-inventory list as JSON. Same grouping +
-- ordering as the human renderer ('renderFoundationalInventory').
foundationalInventoryJson :: Index -> IS.IntSet -> A.Value
foundationalInventoryJson ix postSetAll =
  let addOne :: Map.Map Text IS.IntSet -> Int -> Map.Map Text IS.IntSet
      addOne !acc i =
        let d  = defAt ix i
            !m = defModule d
        in Map.insertWith IS.union m (IS.singleton i) acc
      !byModule = IS.foldl' addOne Map.empty postSetAll
      cmp (m1, s1) (m2, s2) =
        case compare (IS.size s2) (IS.size s1) of
          EQ -> compare m1 m2
          o  -> o
      !rows = sortBy cmp (Map.toList byModule)
      rowJson (m, s) =
        let !n      = IS.size s
            shorts  = map (lastSegment . defName . defAt ix) (IS.toList s)
            !exs    = take 3 shorts
        in A.object
             [ "module"   .= m
             , "count"    .= n
             , "examples" .= exs
             ]
  in A.toJSON (map rowJson rows)

-- | Same row shape as 'foundationalInventoryJson', sourced from the
-- producer's @externals_summary@ instead of the in-memory 'Index'.
-- Names in the summary are already unqualified, so no 'lastSegment'
-- pass is needed. Modules with zero postulates are dropped.
foundationalInventoryFromSummaryJson :: Maybe ExternalsSummary -> A.Value
foundationalInventoryFromSummaryJson Nothing = A.toJSON ([] :: [A.Value])
foundationalInventoryFromSummaryJson (Just (ExternalsSummary _mods pm)) =
  let rowsRaw = [ (m, ps) | (m, ps) <- Map.toList pm, not (null ps) ]
      cmp (m1, p1) (m2, p2) =
        case compare (length p2) (length p1) of
          EQ -> compare m1 m2
          o  -> o
      !rows = sortBy cmp rowsRaw
      rowJson (m, ps) =
        let !n   = length ps
            !exs = take 3 ps
        in A.object
             [ "module"   .= m
             , "count"    .= n
             , "examples" .= exs
             ]
  in A.toJSON (map rowJson rows)

-- | Format a percentage to one decimal place, no locale shenanigans.
fmtPct :: Double -> String
fmtPct x =
  let scaled = round (x * 10) :: Int       -- one decimal, integer
      whole  = scaled `div` 10
      frac   = abs scaled `mod` 10
  in show whole ++ "." ++ show frac ++ "%"

