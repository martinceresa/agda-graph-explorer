{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Load-bearing analysis: which definitions sit on the most critical
-- paths between user-facing "results" (theorems / exports / dependency
-- terminals) and the primitive leaves they rest on?
--
-- Three per-node metrics:
--
--   * /depthRank/ — how deep a node sits in the dependency tree under
--     some result. Higher means it carries a longer chain of users
--     above it.
--   * /spanBetweenness/ — fraction of per-result critical-path
--     witnesses that pass through this node.
--   * /perturbation Δ/ — by how much the project's longest critical
--     path would shrink if this node were virtually deleted. Cheap
--     approximation: re-run the longest-path DP with the node masked.
--
-- Graph orientation: 'idxForward' edges go user -> usee. "Results" sit
-- at the TOP of the dep tree (no in-edges, or exported, or tagged).
-- Critical paths therefore walk /forward/ from a result down to a leaf
-- — the opposite direction from a sinks-first longest-path DP. We use
-- a small local DP that propagates depth forward from each seed.
--
-- Cycles: the real corpus is /not/ a DAG (data types co-reference
-- their constructors, etc.). We condense to SCCs ('Data.Graph') and
-- run the DP on the condensation; per-node metrics are inherited from
-- the containing SCC.
module AgdaOptimization.LoadBearing
  ( -- * Surface
    Options(..)
  , Results(..)
  , Weight(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
  ) where

import           Control.Monad          ( when )
import           Control.Parallel.Strategies ( parMap, rdeepseq )
import           AgdaOptimization.Condense ( Condensation(..), buildCondensation )
import qualified Data.IntMap.Strict     as IM
import qualified Data.Map.Strict        as Map
import qualified Data.IntSet            as IS
import           Data.List              ( sortBy, sortOn )
import           Data.Maybe             ( fromMaybe, mapMaybe )
import           Data.Ord               ( Down(..), comparing )
import           Data.Text              ( Text )
import qualified Data.Text              as T
import qualified Data.Vector            as V
import           System.IO              ( hPutStrLn, stderr )

import qualified Data.Aeson             as A
import           Data.Aeson             ( (.=) )

import           AgdaGraph.Index        ( Index(..), defAt )
import           AgdaGraph.Schema       ( Access(..), Definition(..), State(..) )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Common ( computeExcludedSet, isTagged )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , withHumanReport )

------------------------------------------------------------------------
-- Public surface (signature MUST stay stable — wired by callers).
------------------------------------------------------------------------

-- | What counts as a "result" — the seeds we anchor critical paths at.
data Results
  = ResultsTagged      -- ^ QNames matching a built-in @-thm@ / @theorem-@ regex.
  | ResultsExported    -- ^ Public defs in the entry module (default).
  | ResultsTerminals   -- ^ Nodes with no incoming edges (no users).
  deriving (Show, Eq)

-- | How to weight critical-path lengths.
data Weight
  = WeightUnit         -- ^ Every node weighs 1.
  | WeightLoc          -- ^ LOC weighting (currently approximated as 1).
  deriving (Show, Eq)

data Options = Options
  { optResults           :: !Results
  , optWeight            :: !Weight
  , optTopN              :: !Int
  , optExcludeNameRegex  :: !Text
    -- ^ Regex applied to the unqualified (last dot-component) name of
    -- every definition. Matching nodes are stripped from the candidate
    -- set BEFORE ranking. Empty string disables filtering.
    --
    -- Default targets purely-separator operator names like
    -- @──────_@ / @═══_@ that some Agda preludes declare as their own
    -- definitions and which otherwise dominate the top-N table.
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optResults          = ResultsExported
  , optWeight           = WeightUnit
  , optTopN             = 50
  , optExcludeNameRegex = T.pack "^[_\x2500\x2550]+$"
  }

-- | Declarative flag spec for the @load-bearing@ subcommand. Drives
-- both 'parseOptions' and 'applyConfig'. Each help line is verbatim
-- from 'AgdaOptimization.CLI.subFlags'.
--
-- The enum-valued flags @--results@ (@tagged|exported|terminals@) and
-- @--weight@ (@unit|loc@) accept the short tags only and surface the
-- parser's @Left@ verbatim ('EnumVerbatim'). @--exclude-name-regex@
-- takes a POSIX-ERE pattern (matched against each definition's
-- unqualified name); an empty string disables it.
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ EnumFlag "results" "--results=tagged|exported|terminals  result-set selector (default exported)"
      parseResults EnumVerbatim (\r o -> o { optResults = r })
  , EnumFlag "weight" "--weight=unit|loc                    span weighting (default unit)"
      parseWeight EnumVerbatim (\w o -> o { optWeight = w })
  , IntFlag "top-n" "--top-n=N                            rows to keep (default 50)"
      (\n o -> o { optTopN = n })
  , TextFlag "exclude-name-regex" "--exclude-name-regex=PATTERN         POSIX-ERE on unqualified name (default ^[_─═]+$)"
      (\p o -> o { optExcludeNameRegex = p })
  ]

-- | Hand-rolled CLI parser for the @load-bearing@ subcommand.
--
-- The enum-valued flags @--results@ (@tagged|exported|terminals@) and
-- @--weight@ (@unit|loc@) accept the short tags only.
--
-- @--exclude-name-regex@ takes a POSIX-ERE pattern (matched against
-- each definition's unqualified name); an empty string disables it.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "load-bearing" flagSpecs

parseResults :: String -> Either String Results
parseResults "tagged"    = Right ResultsTagged
parseResults "exported"  = Right ResultsExported
parseResults "terminals" = Right ResultsTerminals
parseResults v           = Left ("expected one of tagged|exported|terminals, got " <> show v)

parseWeight :: String -> Either String Weight
parseWeight "unit" = Right WeightUnit
parseWeight "loc"  = Right WeightLoc
parseWeight v      = Left ("expected one of unit|loc, got " <> show v)

-- | Overlay the @load-bearing:@ YAML section onto a seed 'Options'.
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "load-bearing" flagSpecs obj o0

------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------

-- | Entry point. Pure compute, single stdout dump, plus a couple of
-- stderr notes when fallbacks fire.
run :: Index -> GlobalOpts -> Options -> IO ()
run !ix !gOpts !opts = do
  when (optWeight opts == WeightLoc) $
    hPutStrLn stderr
      "[load-bearing] note: WeightLoc is approximated as 1 in v1 \
      \(loc spans not in schema)."
  let (seeds0, modeUsed, mNote) = chooseSeeds ix (optResults opts)
  mapM_ (hPutStrLn stderr . ("[load-bearing] " ++)) mNote
  -- Compile the exclusion regex once. Empty pattern => no filter.
  let !excluded = computeExcludedSet ix (optExcludeNameRegex opts)
  when (not (IS.null excluded)) $
    hPutStrLn stderr $
      "[load-bearing] excluded " ++ show (IS.size excluded)
      ++ " definitions matching " ++ T.unpack (optExcludeNameRegex opts) ++ "."
  let !cond = buildCondensation ix
  -- A cyclic graph is normal here; the SCC condensation always exists.
  runAnalysis ix cond gOpts opts seeds0 modeUsed excluded

-- | Pure analysis core. Split out from 'run' so the IO surface is tiny.
--
-- @excluded@ is the set of node ids the regex filter removed from the
-- candidate pool before ranking. It does NOT affect seed selection or
-- the longest-path DP — only the final candidate list.
runAnalysis :: Index -> Condensation -> GlobalOpts -> Options -> IS.IntSet -> Results -> IS.IntSet -> IO ()
runAnalysis !ix !cond !gOpts !opts !seeds !modeUsed !excluded = do
  let !sCount     = IS.size seeds
      sccOf       = cdSccOf cond
      members     = cdMembers cond

      -- Map seeds to their SCCs. Multiple seeds may share one SCC.
      sccSeeds :: IS.IntSet
      !sccSeeds =
        IS.fromList
          [ IM.findWithDefault (-1) s sccOf | s <- IS.toList seeds ]

      -- Per-SCC-seed: forward DP on the SCC DAG. Returns (depth, parent).
      -- Each call is independent; spark across seed SCCs.
      perResult :: [(Int, IM.IntMap Int, IM.IntMap Int)]
      !perResult  =
        parMap rdeepseq
          (\sScc -> let (d, p) = longestPathFromSeed cond sScc
                    in (sScc, d, p))
          (IS.toList sccSeeds)

      -- depthRankSCC(scc) = max over seed SCCs of longest path to scc.
      depthRankSCC :: IM.IntMap Int
      !depthRankSCC = foldl' mergeMax IM.empty
                        [ d | (_, d, _) <- perResult ]
      mergeMax !acc !m = IM.unionWith max acc m

      -- Per-node depthRank inherited from containing SCC.
      depthRank :: IM.IntMap Int
      !depthRank =
        IM.foldlWithKey'
          (\acc scc rk ->
             let mems = IM.findWithDefault IS.empty scc members
             in IS.foldl' (\ !m v -> IM.insert v rk m) acc mems)
          IM.empty depthRankSCC

      -- One longest-path witness per seed SCC: a chain of SCC ids.
      cpSccPaths :: [[Int]]
      !cpSccPaths = [ recoverLongestPath d p s | (s, d, p) <- perResult ]

      -- Project depth = max SCC chain length minus one.
      !d_project  = maximum (0 : [length p - 1 | p <- cpSccPaths, not (null p)])

      -- spanBetweenness: count how often each NODE appears in a CP
      -- witness. A node inherits membership from its SCC: if SCC X is
      -- on the witness, every node in X gets +1 for that path.
      spanCount :: IM.IntMap Int
      !spanCount =
        let bump !acc sccPath =
              let !pathSet = IS.fromList sccPath
                  visitedNodes =
                    IS.foldl' (\ !s scc ->
                                 IS.union s (IM.findWithDefault IS.empty
                                                                 scc members))
                              IS.empty pathSet
              in IS.foldl' (\ !m v -> IM.insertWith (+) v 1 m)
                           acc visitedNodes
        in foldl' bump IM.empty cpSccPaths

      spanBet :: Int -> Double
      spanBet v
        | sCount == 0 = 0.0
        | otherwise   =
            fromIntegral (IM.findWithDefault 0 v spanCount)
              / fromIntegral (length perResult)
        -- Note: divide by |seed SCCs|, not |seeds|, since multiple
        -- seeds in the same SCC produce identical critical paths.

      -- Candidates: nodes that landed in some reachable SCC, minus
      -- any explicitly excluded by --exclude-name-regex.
      candidates :: [Int]
      !candidates =
        [ v | v <- IM.keys depthRank, not (IS.member v excluded) ]

      -- Cap for perturbation Δ — only compute it for the most-spanning
      -- nodes; the rest get a "-" in the table.
      !pertCap    = max 200 (optTopN opts * 2)

      bySpan :: [Int]
      !bySpan = sortBy
        (comparing (\v ->
            Down ( spanBet v
                 , IM.findWithDefault 0 v depthRank
                 )))
        candidates

      pertSet :: IS.IntSet
      !pertSet  = IS.fromList (take pertCap bySpan)

      -- Δ approximation: we only meaningfully delete singleton SCCs;
      -- for nodes in a multi-node SCC, removing one node doesn't shrink
      -- the SCC's reachability set in the condensation, so Δ ≈ 0.
      -- We return Nothing for non-singletons too — easier to interpret.
      --
      -- Precomputed in parallel: 'projectDepthWithoutSCC' is the
      -- dominant cost on big condensations (each call O(|seeds| ×
      -- |SCCs|)). parMap over the ~pertCap members, freeze into an
      -- IntMap; lookup is O(log n).
      computePert :: Int -> Maybe Int
      computePert !v =
        let !scc = sccOf IM.! v
            !mems = IM.findWithDefault IS.empty scc members
        in if IS.size mems /= 1
             then Just 0   -- non-singleton SCCs: delete doesn't decompose it.
             else Just $!
                    d_project - projectDepthWithoutSCC cond sccSeeds scc

      pertResults :: IM.IntMap (Maybe Int)
      !pertResults =
        IM.fromList $
          parMap rdeepseq
                 (\v -> (v, computePert v))
                 (IS.toAscList pertSet)

      pertOf :: Int -> Maybe Int
      pertOf v = IM.findWithDefault Nothing v pertResults

      -- Composite ranking: spanBet * max(1, Δ).
      composite :: Int -> Double
      composite v =
        let !sb   = spanBet v
            !pert = fromMaybe 0 (pertOf v)
            !w    = fromIntegral (max 1 pert) :: Double
        in sb * w

      -- 'sortOn' computes each candidate's key once (Schwartzian
      -- transform); 'sortBy (comparing …)' would re-evaluate it
      -- O(log n) times per element, multiplying every 'composite' /
      -- 'pertOf' lookup.
      topN :: [Int]
      !topN     = take (optTopN opts) $
        sortOn (\v -> Down ( composite v
                           , spanBet v
                           , IM.findWithDefault 0 v depthRank
                           ))
               candidates

  -- ------------- output -------------
  let !adviceVs = take 3 $ sortOn
        (\v -> Down ( spanBet v
                    * fromIntegral
                        (max 1 (fromMaybe 0 (pertOf v)))
                    , spanBet v
                    ))
        topN
  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        loadBearingJson ix cond opts modeUsed sCount d_project excluded
                        perResult depthRank spanBet pertOf topN adviceVs
    OutHuman -> withHumanReport gOpts "load-bearing" $ do
      putStrLn $ "# LoadBearing — top " ++ show (optTopN opts)
              ++ " (results: " ++ resultsLabel modeUsed
              ++ ", weight: " ++ weightLabel (optWeight opts) ++ ")"
      putStrLn $ "|V| = " ++ show (idxNodeCount ix)
              ++ ", |S| = " ++ show sCount
              ++ ", |SCC| = " ++ show (cdCount cond)
              ++ ", D (project depth) = " ++ show d_project
      putStrLn ""

      let header = ["Rank","QName","Module","State","dr","spanBet","Δ"]
          rows   =
            [ [ show r
              , T.unpack (defName d) ++ stateBracket (defState d)
              , T.unpack (defModule d)
              , stateLetter (defState d)
              , show (IM.findWithDefault (-1) v depthRank)
              , showFixed3 (spanBet v)
              , maybe "-" show (pertOf v)
              ]
            | (r, v) <- zip [1::Int ..] topN
            , let !d = defAt ix v
            ]
      putStr (renderTable header rows)
      putStrLn ""
      putStrLn "## Advice"
      if null adviceVs
        then putStrLn "  (no candidates — empty seed set or trivial graph)"
        else mapM_ (printAdvice ix cond perResult pertOf spanBet) adviceVs

------------------------------------------------------------------------
-- Seed selection
------------------------------------------------------------------------

-- | Pick the sink set @S@ for the chosen 'Results' mode.
--
-- Returns the seed set, the mode actually used (after any fallback),
-- and any stderr notes the caller should emit. Falls back to
-- 'ResultsTerminals' when the requested mode yields an empty set.
chooseSeeds :: Index -> Results -> (IS.IntSet, Results, [String])
chooseSeeds !ix !mode =
  let primary = pickSeeds ix mode
  in if IS.null primary
       then let !fall = pickSeeds ix ResultsTerminals
                note  =
                  [ "no seeds for results=" ++ resultsLabel mode
                    ++ "; falling back to results=terminals "
                    ++ "(|S| = " ++ show (IS.size fall) ++ ")."
                  ]
            in (fall, ResultsTerminals, note)
       else (primary, mode, [])

-- | Mode-specific seed selection.
pickSeeds :: Index -> Results -> IS.IntSet
pickSeeds !ix = \case
  ResultsTagged ->
    IS.fromList
      [ defId d
      | d <- V.toList (idxDefs ix)
      , isTagged (defName d)
      ]

  ResultsExported ->
    let allDefs = V.toList (idxDefs ix)
        entryGuess = guessEntryModule allDefs
        keep d = defAccess d == Public
              && maybe True (== defModule d) entryGuess
        seeds  = IS.fromList [ defId d | d <- allDefs, keep d ]
    in if IS.null seeds
         then IS.fromList [ defId d | d <- allDefs, defAccess d == Public ]
         else seeds

  ResultsTerminals ->
    IS.fromList
      [ i
      | i <- [0 .. idxNodeCount ix - 1]
      , IS.null (IM.findWithDefault IS.empty i (idxReverse ix))
      ]

-- | Heuristic for the entry module when 'egEntryModule' isn't carried
-- by the 'Index'. Pick the module with the largest number of Public
-- defs; tie-break by shortest module-name length.
guessEntryModule :: [Definition] -> Maybe Text
guessEntryModule defs =
  let pubs   = [ defModule d | d <- defs, defAccess d == Public ]
      -- Per-module public-def counts via a strict Map, O(P·log M).
      counts :: [(Text, Int)]
      counts = Map.toList (foldl' (\m k -> Map.insertWith (+) k 1 m) Map.empty pubs)
      -- Total order (count desc, name length, then name) so the winner is
      -- independent of the def vector's traversal order in a tie.
      ranked = sortBy (comparing (\(m, c) -> (Down c, T.length m, m))) counts
  in case ranked of
       []        -> Nothing
       ((m,_):_) -> Just m

------------------------------------------------------------------------
-- Longest-path DP on the condensation (forward from a seed SCC)
------------------------------------------------------------------------

-- | Longest forward path from a single seed SCC to every reachable SCC.
-- Returns (depth map, parent pointers). Walks 'cdTopo' (ancestors first).
longestPathFromSeed
  :: Condensation
  -> Int                              -- ^ Seed SCC id.
  -> (IM.IntMap Int, IM.IntMap Int)   -- ^ (depth, parent SCC).
longestPathFromSeed !cond !s =
  foldl' step (IM.singleton s 0, IM.empty) (cdTopo cond)
  where
    rev = cdReverse cond
    step (!dAcc, !pAcc) !n
      | n == s = (dAcc, pAcc)
      | otherwise =
          let parents = IM.findWithDefault IS.empty n rev
              (best, who) = IS.foldl' pick (Nothing, -1) parents
              pick (!mb, !w) p = case IM.lookup p dAcc of
                Nothing -> (mb, w)
                Just dp -> case mb of
                  Nothing -> (Just (dp + 1), p)
                  Just b  -> if dp + 1 > b
                               then (Just (dp + 1), p)
                               else (mb, w)
          in case best of
               Nothing -> (dAcc, pAcc)
               Just dn ->
                 let !dAcc' = IM.insert n dn dAcc
                     !pAcc' = IM.insert n who pAcc
                 in (dAcc', pAcc')

-- | Trace back from the deepest reached node to the seed.
-- Returns the path [seed, ..., deepest].
recoverLongestPath
  :: IM.IntMap Int   -- ^ Depth from seed.
  -> IM.IntMap Int   -- ^ Parent pointers.
  -> Int             -- ^ Seed.
  -> [Int]
recoverLongestPath !d !p !s
  | IM.null d = [s]
  | otherwise =
      let (!maxV, _) = IM.foldlWithKey'
                        (\(!bv, !bd) !k !v ->
                           if v > bd then (k, v) else (bv, bd))
                        (s, -1) d
          walk !n
            | n == s    = [s]
            | otherwise = case IM.lookup n p of
                Nothing  -> [n]
                Just par -> n : walk par
      in reverse (walk maxV)

------------------------------------------------------------------------
-- Perturbation Δ
------------------------------------------------------------------------

-- | Project depth after virtually deleting an entire SCC. We mask the
-- SCC from the per-seed DPs and take the max depth across seeds.
-- O(|seedSCCs| * |SCCs|).
projectDepthWithoutSCC :: Condensation -> IS.IntSet -> Int -> Int
projectDepthWithoutSCC !cond !seedSccs !victim =
  foldl' (\ !acc s ->
            max acc (longestPathFromSeedMasked cond victim s))
         0
         (IS.toList seedSccs)

-- | Like 'longestPathFromSeed' but skips @victim@ and returns only the
-- maximum depth reached (no parent map). If @victim == seed@, return 0
-- (every CP is trivially length 0).
longestPathFromSeedMasked
  :: Condensation
  -> Int    -- ^ Victim SCC.
  -> Int    -- ^ Seed SCC.
  -> Int    -- ^ Max depth reachable from seed avoiding victim.
longestPathFromSeedMasked !cond !victim !s
  | s == victim = 0
  | otherwise   = snd (foldl' step (IM.singleton s 0, 0) (cdTopo cond))
  where
    rev = cdReverse cond
    step (!dAcc, !best) !n
      | n == victim = (dAcc, best)
      | n == s      = (dAcc, best)
      | otherwise   =
          let parents = IM.findWithDefault IS.empty n rev
              picked  = IS.foldl' pick Nothing parents
              pick !mb !p
                | p == victim = mb
                | otherwise   = case IM.lookup p dAcc of
                    Nothing -> mb
                    Just dp -> case mb of
                      Nothing -> Just (dp + 1)
                      Just b  -> Just (max b (dp + 1))
          in case picked of
               Nothing -> (dAcc, best)
               Just dn ->
                 let !dAcc' = IM.insert n dn dAcc
                     !b'    = max best dn
                 in (dAcc', b')

------------------------------------------------------------------------
-- Display helpers
------------------------------------------------------------------------

resultsLabel :: Results -> String
resultsLabel = \case
  ResultsTagged    -> "tagged"
  ResultsExported  -> "exported"
  ResultsTerminals -> "terminals"

weightLabel :: Weight -> String
weightLabel = \case
  WeightUnit -> "unit"
  WeightLoc  -> "loc(approx)"

stateLetter :: State -> String
stateLetter = \case
  Defined   -> "D"
  Postulate -> "P"
  Hole      -> "H"
  Failed    -> "F"

stateBracket :: State -> String
stateBracket s = case s of
  Defined -> ""
  _       -> " [" ++ stateLetter s ++ "]"

-- | Format a 'Double' with 3 fractional digits, no library dependency.
showFixed3 :: Double -> String
showFixed3 !x =
  let n      = (round (x * 1000) :: Int)
      (q, r) = divMod (abs n) 1000
      sign   = if n < 0 then "-" else ""
      pad3 v = let s = show v in replicate (3 - length s) '0' ++ s
  in sign ++ show q ++ "." ++ pad3 r

----------------------------------------------------------------------
-- JSON rendering. See the schema in 'AgdaOptimization.Report'.

loadBearingJson
  :: Index
  -> Condensation
  -> Options
  -> Results             -- ^ Mode actually used (after fallback).
  -> Int                 -- ^ Seed count.
  -> Int                 -- ^ Project depth.
  -> IS.IntSet           -- ^ Excluded by --exclude-name-regex.
  -> [(Int, IM.IntMap Int, IM.IntMap Int)]  -- ^ per-seed CP data.
  -> IM.IntMap Int       -- ^ depthRank.
  -> (Int -> Double)     -- ^ spanBet.
  -> (Int -> Maybe Int)  -- ^ pertOf.
  -> [Int]               -- ^ topN node ids.
  -> [Int]               -- ^ advice node ids.
  -> A.Value
loadBearingJson ix cond opts modeUsed sCount d_project excluded
                perResult depthRank spanBet pertOf topN adviceVs =
  A.object
    [ "subcommand" .= ("load-bearing" :: T.Text)
    , "options"    .= loadBearingOptionsJson opts
    , "stats"      .= A.object
        [ "n_nodes"          .= idxNodeCount ix
        , "n_seeds"          .= sCount
        , "n_scc"            .= cdCount cond
        , "project_depth"    .= d_project
        , "excluded_by_regex" .= IS.size excluded
        ]
    , "results_mode_used" .= resultsTag modeUsed
    , "weight_mode_used"  .= weightTag (optWeight opts)
    , "rows"  .= A.toJSON (zipWith (lbRowJson ix depthRank spanBet pertOf)
                                   [1 :: Int ..] topN)
    , "advice" .= A.toJSON (map (lbAdviceJson ix cond perResult spanBet pertOf)
                                adviceVs)
    ]

loadBearingOptionsJson :: Options -> A.Value
loadBearingOptionsJson Options{..} = A.object
  [ "results"            .= resultsTag optResults
  , "weight"             .= weightTag optWeight
  , "top_n"              .= optTopN
  , "exclude_name_regex" .= optExcludeNameRegex
  ]

resultsTag :: Results -> T.Text
resultsTag = T.pack . resultsLabel

weightTag :: Weight -> T.Text
weightTag WeightUnit = "unit"
weightTag WeightLoc  = "loc"

lbRowJson
  :: Index
  -> IM.IntMap Int
  -> (Int -> Double)
  -> (Int -> Maybe Int)
  -> Int
  -> Int
  -> A.Value
lbRowJson ix depthRank spanBet pertOf rank v =
  let d = defAt ix v
  in A.object $
       [ "rank"            .= rank
       , "qname"           .= defName d
       , "module"          .= defModule d
       , "state"           .= stateLetter (defState d)
       , "depth_rank"      .= IM.findWithDefault (-1) v depthRank
       , "span_betweenness" .= spanBet v
       ] ++ case pertOf v of
              Nothing -> []
              Just k  -> [ "delta" .= k ]

lbAdviceJson
  :: Index
  -> Condensation
  -> [(Int, IM.IntMap Int, IM.IntMap Int)]
  -> (Int -> Double)
  -> (Int -> Maybe Int)
  -> Int
  -> A.Value
lbAdviceJson ix cond perResult spanBet pertOf v =
  let d          = defAt ix v
      victimScc  = IM.findWithDefault (-1) v (cdSccOf cond)
      pos        = length [ () | (_, dm, _) <- perResult
                               , IM.member victimScc dm
                               ]
      worst      = case mapMaybe
                      (\(s, dm, _) -> fmap (\dv -> (s, dv))
                                            (IM.lookup victimScc dm))
                      perResult of
        []  -> Nothing
        xs  -> Just $! foldr1 (\a@(_,da) b@(_,db) -> if da >= db then a else b) xs
      deepest   = case worst of
        Nothing      -> Nothing
        Just (sScc, _) ->
          let mems = IM.findWithDefault IS.empty sScc (cdMembers cond)
          in case IS.toAscList mems of
               (m:_) -> Just (defName (defAt ix m))
               []    -> Nothing
  in A.object $
       [ "qname"            .= defName d
       , "module"           .= defModule d
       , "affects"          .= pos
       , "span_betweenness" .= spanBet v
       ] ++ (case pertOf v of
               Nothing -> []
               Just k  -> [ "delta" .= k ])
         ++ (case deepest of
               Nothing -> []
               Just n  -> [ "deepest_under" .= n ])

-- | Emit a one-line advice string for a single top node.
printAdvice
  :: Index
  -> Condensation
  -> [(Int, IM.IntMap Int, IM.IntMap Int)]
  -> (Int -> Maybe Int)             -- ^ pertOf
  -> (Int -> Double)                -- ^ spanBet
  -> Int                            -- ^ victim node id
  -> IO ()
printAdvice !ix !cond !perResult !pertOf !spanBet !v = do
  let d          = defAt ix v
      victimScc  = IM.findWithDefault (-1) v (cdSccOf cond)
      pos        = length [ () | (_, dm, _) <- perResult
                               , IM.member victimScc dm
                               ]
      worst      = case mapMaybe
                      (\(s, dm, _) -> fmap (\dv -> (s, dv))
                                            (IM.lookup victimScc dm))
                      perResult of
        []  -> Nothing
        xs  -> Just $! foldr1 (\a@(_,da) b@(_,db) -> if da >= db then a else b) xs
      worstStr   = case worst of
        Nothing      -> "(none)"
        Just (sScc, _) ->
          let mems = IM.findWithDefault IS.empty sScc (cdMembers cond)
          in case IS.toAscList mems of
               (m:_) -> T.unpack (defName (defAt ix m))
               []    -> "(scc " ++ show sScc ++ ")"
      pertStr    = case pertOf v of Just k -> show k; Nothing -> "?"
  putStrLn $ "  - removing " ++ T.unpack (defName d)
          ++ " (mod " ++ T.unpack (defModule d) ++ ")"
          ++ " would affect " ++ show pos ++ " critical-path proof(s)"
          ++ "; spanBet=" ++ showFixed3 (spanBet v)
          ++ "; Δ=" ++ pertStr
          ++ "; deepest under: " ++ worstStr
