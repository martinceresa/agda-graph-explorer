{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
-- | Trust-set ledger.
--
-- Per public theorem, compute its /trust budget/: the set of
-- postulates it transitively depends on, partitioned into a
-- /foundational/ part (@Agda.Builtin.*@ / @Agda.Primitive.*@) and a
-- /paper-level/ part (every other postulate — typically the
-- user-authored axioms of the project).
--
-- Three views are produced from the same per-theorem data:
--
--   * /Per-theorem trust footprint/: @(|T_found|, |T_axiom|, T_axiom)@.
--   * /Axiom leverage/: for each paper-level axiom, how many public
--     theorems depend on it.
--   * /Cohorts/: equivalence classes of theorems by their exact
--     paper-level axiom set. Same axioms => same cohort.
--
-- When the producer ran with @--no-externals@ the in-memory 'Index'
-- carries the surviving postulate names in its 'ExternalsSummary';
-- we surface that as a "foundational tail" section, mirroring
-- 'AgdaOptimization.Debt.renderFoundationalInventoryFromSummary'.
--
-- Axiom- and theorem-side scoping flags:
--
--   * @--axiom-source=postulate|record-field|both@ — some projects
--     encode paper-axioms as record fields ('KProjection') of an
--     @Assumptions@ record, which the default postulate-only detector
--     misses.
--   * @--axiom-module-prefix=PREFIX@ — repeatable; scopes which
--     record-fields count as axioms.
--   * @--theorem-prefix=PREFIX@ — repeatable; scopes the public
--     theorem set. Without a prefix, the default is project-only
--     modules when 'idxExternalsSummary' is present.
module AgdaOptimization.Ledger
  ( Options(..)
  , AxiomSource(..)
  , defaultOptions
  , flagSpecs
  , parseOptions
  , applyConfig
  , run
    -- * Exposed for the offline suite
  , TheoremTrust(..)
  , computeTrust
  , partitionAxioms
  , collectPublicTheorems
  , buildLeverage
  ) where

import           Control.DeepSeq      ( NFData(..) )
import           Control.Monad        ( when )
import           Control.Parallel.Strategies ( parListChunk, rdeepseq
                                             , withStrategy )
import qualified Data.IntMap.Strict   as IM
import qualified Data.IntSet          as IS
import           Data.List            ( intercalate, sortBy )
import qualified Data.Map.Strict      as Map
import           Data.Maybe           ( catMaybes )
import           Data.Ord             ( comparing )
import           Data.Text            ( Text )
import qualified Data.Text            as T
import qualified Data.Vector          as V
import           System.IO            ( hPutStrLn, stderr )

import qualified Data.Aeson           as A
import           Data.Aeson           ( (.=) )

import           AgdaGraph.Index      ( Index(..), defAt, descendants )
import           AgdaGraph.Schema     ( Access(..), Definition(..)
                                      , ExternalsSummary(..), Kind(..)
                                      , State(..) )

import           AgdaOptimization.Common ( isFoundationalModule )
import           AgdaOptimization.FlagSpec ( FlagSpec(..), SwitchVal(..), EnumErr(..)
                                           , parseFlags, applyFlagConfig )
import           AgdaOptimization.Report ( GlobalOpts(..), OutFormat(..)
                                         , renderTable, emitJsonReport
                                         , withHumanReport )

-- ---------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------

-- | Where to source "axioms" from when partitioning postulate / axiom
-- nodes. 'KPostulate'-kinded nodes are the default; 'AsRecordField' /
-- 'AsBoth' also count /record fields/ ('KProjection') of an
-- @Assumptions@-style record, scoped by 'optAxiomModulePrefixes', for
-- projects that encode their paper-axioms that way.
data AxiomSource
  = AsPostulate     -- ^ @kind="postulate"@ only.
  | AsRecordField   -- ^ projections of records under axiom-module prefix.
  | AsBoth          -- ^ union of the two.
  deriving (Show, Eq)

-- | User-facing options. Defaults below.
data Options = Options
  { optTopN                :: !Int
    -- ^ Maximum rows of the per-theorem trust-footprint table.
  , optIncludeFoundational :: !Bool
    -- ^ Render the foundational-tail section (when an externals_summary
    -- is available). On by default; @--no-foundational@ opts out.
  , optMinAxioms           :: !Int
    -- ^ Only show theorems with at least N paper-level axioms.
  , optCohortMinSize       :: !Int
    -- ^ Only show cohorts with at least N members.
  , optAxiomSource         :: !AxiomSource
    -- ^ Which 'defKind's are considered paper-level axioms. Default
    -- 'AsPostulate'.
  , optAxiomModulePrefixes :: ![Text]
    -- ^ When 'optAxiomSource' is 'AsRecordField' or 'AsBoth', only
    -- record-field defs whose 'defModule' starts with one of these
    -- prefixes count as axioms. Empty list = "no explicit scope",
    -- which falls back to /project-only/ modules (see 'run').
  , optTheoremPrefixes     :: ![Text]
    -- ^ Scope the public-theorem set: only defs whose 'defModule'
    -- starts with one of these prefixes count as theorems. Empty
    -- list = use the default theorem set ('run' decides: project-only
    -- if externals_summary is present, otherwise the prelude-strip
    -- heuristic).
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optTopN                = 50
  , optIncludeFoundational = True
  , optMinAxioms           = 0
  , optCohortMinSize       = 2
  , optAxiomSource         = AsPostulate
  , optAxiomModulePrefixes = []
  , optTheoremPrefixes     = []
  }

-- | Parse an @--axiom-source@ value. Top-level so 'applyConfig' can
-- re-use it.
parseAxiomSource :: String -> Either String AxiomSource
parseAxiomSource v = case v of
  "postulate"    -> Right AsPostulate
  "record-field" -> Right AsRecordField
  "both"         -> Right AsBoth
  _ -> Left ("expected one of postulate|record-field|both, got " <> show v)

-- | Declarative flag spec for the @ledger@ subcommand. Drives both the
-- argv parser ('parseOptions') and the YAML overlay ('applyConfig'), and
-- is the single source of truth the help-derivation stage reads. Each
-- help line is verbatim from 'AgdaOptimization.CLI.subFlags'.
--
-- @--no-foundational@ is a 'SwitchPreGuard' switch (matched against the
-- raw token before 'splitFlag'); its YAML key is @foundational@.
-- @--axiom-source@ is an 'EnumWrapped' enum (a rejected token is wrapped
-- @ledger: --axiom-source: …@). The two repeatable list flags append on
-- the argv side and /replace/ on the config side; CLI repetitions of
-- each still append, so the final list is (config's list) ++ (CLI
-- repetitions).
flagSpecs :: [FlagSpec Options]
flagSpecs =
  [ IntFlag "top-n" "--top-n=N                          theorem rows (default 50)"
      (\n o -> o { optTopN = n })
  , IntFlag "min-axioms" "--min-axioms=N                     only show theorems with >= N axioms (default 0)"
      (\n o -> o { optMinAxioms = n })
  , IntFlag "cohort-min-size" "--cohort-min-size=N                only show cohorts with >= N members (default 2)"
      (\n o -> o { optCohortMinSize = n })
  , SwitchFlag "no-foundational" "--no-foundational                  suppress foundational tail section"
      SwitchPreGuard (\o -> o { optIncludeFoundational = False })
      (Just "foundational") (\v o -> o { optIncludeFoundational = v })
  , EnumFlag "axiom-source" "--axiom-source=postulate|record-field|both  what counts as an axiom (default postulate)"
      parseAxiomSource EnumWrapped (\v o -> o { optAxiomSource = v })
  , TextListFlag "axiom-module-prefix" "--axiom-module-prefix=PREFIX       repeatable; record-field-axiom module scope"
      (\tv o -> o { optAxiomModulePrefixes = optAxiomModulePrefixes o ++ [tv] })
      (\v o -> o { optAxiomModulePrefixes = v })
  , TextListFlag "theorem-prefix" "--theorem-prefix=PREFIX            repeatable; theorem-set scope (else project-only via externals_summary)"
      (\tv o -> o { optTheoremPrefixes = optTheoremPrefixes o ++ [tv] })
      (\v o -> o { optTheoremPrefixes = v })
  ]

-- | Hand-rolled CLI parser. Mirrors the dispatch shape of
-- 'AgdaOptimization.Debt.parseOptions'.
parseOptions :: Options -> [String] -> Either String Options
parseOptions = parseFlags "ledger" flagSpecs

-- | Overlay the @ledger:@ YAML section onto a seed 'Options'.
--
-- The two list-valued keys (@axiom-module-prefix@, @theorem-prefix@)
-- accept either a single YAML string or a YAML list of strings, and
-- /replace/ the seed list rather than appending. CLI repetitions of
-- the corresponding flag still append, so the final list is
-- (config's list) ++ (CLI repetitions).
applyConfig :: A.Object -> Options -> Either String Options
applyConfig obj o0 = applyFlagConfig "ledger" flagSpecs obj o0

-- ---------------------------------------------------------------------
-- Core data shapes (kept tiny on purpose — the hot loop is sparked)
-- ---------------------------------------------------------------------

-- | Trust budget for one public theorem.
--
-- Fields are strict so the chunked 'rdeepseq' spark over a list of 'TheoremTrust'
-- forces the full intersection result inside the spark, not later in
-- the main thread.
data TheoremTrust = TheoremTrust
  { ttId         :: !Int
  , ttAxioms     :: !IS.IntSet   -- ^ paper-level postulates only
  , ttFoundCount :: !Int         -- ^ |foundational postulates reached|
  } deriving (Show)

-- 'TheoremTrust' has fully-strict fields of primitive / strict types,
-- so 'rnf' just walks the constructor.
instance NFData TheoremTrust where
  rnf TheoremTrust{..} =
        rnf ttId
    `seq` rnf ttAxioms
    `seq` rnf ttFoundCount

-- ---------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------

-- | Read-only entry. Builds the trust budget for every public
-- theorem, then dispatches on the global output format.
run :: Index -> GlobalOpts -> Options -> IO ()
run ix gOpts opts = do
  let !defs = idxDefs ix
      !mes  = idxExternalsSummary ix

      -- (1) Partition into foundational + paper-axiom sets per options.
      (!foundSet, !axiomSet) = partitionAxioms opts mes defs

      -- (2) Collect public theorems, scoped per --theorem-prefix (or
      -- the default fallback: project-only if externals_summary is
      -- available, else a prelude-strip heuristic).
      !theoremIds = collectPublicTheorems opts mes defs

      -- (3) Per-theorem trust budget. descendants() is an independent
      -- BFS per node, so spark it — but in CHUNKS, not one spark per
      -- theorem: at stdlib scale (18k theorems) a spark-per-node overflows
      -- the pool and over half get re-run serially on the reducing thread.
      -- Order-preserving, so the -N1/-NK byte-identity contract holds.
      !theorems =
        withStrategy (parListChunk 64 rdeepseq)
          (map (computeTrust ix axiomSet foundSet) theoremIds)

      !nTheorems = length theorems
      !nAxioms   = IS.size axiomSet
      !nFound    = IS.size foundSet

  -- Diagnostic line, same shape as the other analyses' stderr lines.
  hPutStrLn stderr $
    "agda-optimization ledger: |theorems|=" ++ show nTheorems
      ++ ", |paper-axioms|=" ++ show nAxioms
      ++ ", |foundational|=" ++ show nFound ++ "."
  emitFilterDiagnostics opts mes

  let -- (4) Filter & sort for display. Sort by descending axiom
      -- count, then descending foundational count (tie-break:
      -- module/qname). Stable enough for deterministic output.
      passesMin TheoremTrust{..} = IS.size ttAxioms >= optMinAxioms opts
      !filtered = filter passesMin theorems
      cmp a b =
        case compare (IS.size (ttAxioms b)) (IS.size (ttAxioms a)) of
          EQ -> case compare (ttFoundCount b) (ttFoundCount a) of
            EQ -> compare (qnameOf ix (ttId a)) (qnameOf ix (ttId b))
            o  -> o
          o  -> o
      !sortedThms = sortBy cmp filtered

      -- (5) Cohorts. Cohort identity is the sorted [Int] of paper-
      -- level axiom ids; foundational postulates intentionally do
      -- not drive equivalence (they're "shared by everyone").
      !cohorts = buildCohorts theorems (optCohortMinSize opts)

      -- (6) Axiom leverage: invert per-theorem T_axiom into a map
      -- of "this axiom is used by N theorems". Strict insert.
      !leverage = buildLeverage theorems

  -- Tripwire: axioms detected but reached by nobody. The header count and
  -- an empty leverage table then contradict each other, and every footprint
  -- reads a confident 0 — so say which of the two scopes is wrong instead of
  -- rendering the contradiction silently.
  when (nAxioms > 0 && IM.null leverage) $
    hPutStrLn stderr $
      "ledger: warning: " ++ show nAxioms ++ " paper-level axiom"
        ++ (if nAxioms == 1 then "" else "s")
        ++ " detected, but no considered theorem depends on any of them"
        ++ " (every trust footprint is empty).\n"
        ++ "        Check --theorem-prefix / --axiom-module-prefix scope:"
        ++ " the two sets may name disjoint parts of the graph."

  case gOutFormat gOpts of
    OutJson ->
      emitJsonReport (gOutPath gOpts) $
        ledgerJson ix opts theorems sortedThms cohorts leverage
                   nTheorems nAxioms nFound
    OutHuman -> withHumanReport gOpts "ledger" $ do
      putStrLn renderHeader
      putStrLn ""
      mapM_ putStrLn (renderFilterHeader opts mes)
      putStrLn $ renderKPIs nTheorems nAxioms nFound
      putStrLn ""
      putStrLn $ "## Per-theorem trust footprint  (top " ++ show (optTopN opts) ++ ")"
      putStrLn $ renderTheoremsTable ix opts sortedThms
      putStrLn ""
      putStrLn "## Axiom leverage"
      putStrLn $ renderLeverageTable ix leverage
      putStrLn ""
      putStrLn "## Cohorts (theorems sharing exact axiom set)"
      putStrLn $ renderCohorts ix cohorts
      when (optIncludeFoundational opts) $ do
        let foundSection =
              renderFoundationalTailFromSummary (idxExternalsSummary ix)
        when (not (null foundSection)) $ do
          putStrLn ""
          putStrLn foundSection

-- ---------------------------------------------------------------------
-- Selection helpers
-- ---------------------------------------------------------------------

-- | Walk 'idxDefs' once and partition the axiom-side and foundational-
-- side def sets according to 'Options' and (optionally) the producer's
-- @externals_summary@.
--
-- The foundational set is every @Postulate@-state def whose module is
-- @Agda.Builtin.*@ / @Agda.Primitive.*@.
--
-- The axiom set depends on 'optAxiomSource':
--
--   * 'AsPostulate'   — non-foundational @Postulate@ defs.
--   * 'AsRecordField' — record-field ('KProjection') defs whose
--     'defModule' passes the axiom-scope test (see 'inAxiomScope').
--   * 'AsBoth'        — union of the two.
partitionAxioms
  :: Options
  -> Maybe ExternalsSummary
  -> V.Vector Definition
  -> (IS.IntSet, IS.IntSet)  -- ^ (foundational, axioms)
partitionAxioms opts mes defs =
  V.ifoldl' step (IS.empty, IS.empty) defs
  where
    !inScope = inAxiomScope opts mes
    !src     = optAxiomSource opts

    step (!f, !a) i d =
      let !m       = defModule d
          !isFound = defState d == Postulate && isFoundationalModule m
          !isPost  = defState d == Postulate && not isFound
          !isProj  = defKind  d == KProjection
          !addPost = (src == AsPostulate || src == AsBoth) && isPost
          !addProj = (src == AsRecordField || src == AsBoth)
                     && isProj
                     && inScope m
          !f' = if isFound then IS.insert i f else f
          !a' = if addPost || addProj then IS.insert i a else a
      in (f', a')

-- | Predicate: is module @m@ in axiom scope?  Honours an explicit
-- prefix list when set; otherwise falls back to "project-only" via
-- externals_summary (when present) or the foundational heuristic.
inAxiomScope :: Options -> Maybe ExternalsSummary -> Text -> Bool
inAxiomScope opts mes m
  | not (null prefs) = any (`isModulePrefix` m) prefs
  | otherwise        = isProjectModule mes m
  where
    !prefs = optAxiomModulePrefixes opts

-- | Public, user-authored, /interesting/ defs. We always exclude:
-- * non-public defs (cohort identity is uninteresting),
-- * 'KOther' (synthetic edge-only nodes invented by 'buildIndex').
--
-- The module-scope test runs in two modes:
--
--   * 'optTheoremPrefixes' non-empty — module must be a prefix-match
--     of at least one entry.
--   * empty — use the default. If 'idxExternalsSummary' is 'Just',
--     scope to project-only modules (those NOT in 'esModules').
--     Otherwise exclude @Agda.Builtin.*@ / @Agda.Primitive.*@ only.
collectPublicTheorems
  :: Options
  -> Maybe ExternalsSummary
  -> V.Vector Definition
  -> [Int]
collectPublicTheorems opts mes defs =
  reverse $ V.ifoldl' step [] defs
  where
    !inScope = inTheoremScope opts mes

    step !acc i d
      | defAccess d /= Public  = acc
      | defKind   d == KOther  = acc
      | not (inScope (defModule d)) = acc
      | otherwise              = i : acc

-- | Predicate: is module @m@ in /theorem scope/? Mirrors
-- 'inAxiomScope' but falls back to the non-foundational heuristic when
-- no externals_summary is available.
inTheoremScope :: Options -> Maybe ExternalsSummary -> Text -> Bool
inTheoremScope opts mes m
  | not (null prefs) = any (`isModulePrefix` m) prefs
  | otherwise = case mes of
      Just _  -> isProjectModule mes m
      Nothing -> not (isFoundationalModule m)
  where
    !prefs = optTheoremPrefixes opts


-- | Project-only predicate. When the producer ran with
-- @--no-externals@, 'esModules' is the precise external set; otherwise
-- we fall back to the foundational heuristic.
isProjectModule :: Maybe ExternalsSummary -> Text -> Bool
isProjectModule Nothing    m = not (isFoundationalModule m)
isProjectModule (Just es)  m =
  not (any (`isModulePrefix` m) (esModules es))
    && not (isFoundationalModule m)

-- | Prefix-match a module name. We match either the exact name or
-- @prefix.@ as a strict ancestor — never just @T.isPrefixOf@ on the
-- raw text, which would let @"Foo.Bar"@ swallow @"Foo.BarBaz"@.
isModulePrefix :: Text -> Text -> Bool
isModulePrefix prefix m
  | prefix == m = True
  | otherwise   = (prefix `T.append` ".") `T.isPrefixOf` m

-- ---------------------------------------------------------------------
-- The hot loop (sparked via parListChunk rdeepseq in 'run')
-- ---------------------------------------------------------------------

-- | Per-theorem trust budget. 'descendants' gives the forward closure
-- over uses-edges — everything this theorem transitively /rests on/ —
-- which we intersect with the two postulate sets. ('ancestors' is the
-- other direction: the theorem's own dependents. Intersecting THOSE
-- with the axiom set answers no question anyone asked.) The 'IntSet'
-- representation makes the intersection a coordinated walk of two
-- strict tries — O(|s1| + |s2|).
computeTrust :: Index -> IS.IntSet -> IS.IntSet -> Int -> TheoremTrust
computeTrust ix axiomSet foundSet i =
  let !deps      = descendants ix (IS.singleton i)
      !axHere    = IS.intersection deps axiomSet
      !foundHere = IS.intersection deps foundSet
  in TheoremTrust
       { ttId         = i
       , ttAxioms     = axHere
       , ttFoundCount = IS.size foundHere
       }

-- ---------------------------------------------------------------------
-- Cohorts
-- ---------------------------------------------------------------------

-- | Group theorems whose paper-level axiom set is /exactly/ equal.
-- Cohorts of size < 'optCohortMinSize' are dropped (singletons are
-- almost always noise — every theorem with a unique axiom mix).
--
-- Returns each cohort as a triple (axiom-key, sorted-member-ids,
-- size), sorted by descending size then by axiom key for
-- determinism.
buildCohorts :: [TheoremTrust] -> Int -> [([Int], [Int], Int)]
buildCohorts thms minSize =
  let key TheoremTrust{..} = IS.toAscList ttAxioms
      -- Bucket: sorted-axiom-list -> list of theorem ids
      addOne :: Map.Map [Int] [Int] -> TheoremTrust -> Map.Map [Int] [Int]
      addOne !acc t = Map.insertWith (++) (key t) [ttId t] acc
      !byKey  = foldl' addOne Map.empty thms
      !rows0  = [ (k, sortBy compare ids, length ids)
                | (k, ids) <- Map.toList byKey
                , length ids >= minSize
                ]
      cmp (_, _, n1) (_, _, n2) = compare n2 n1
  in sortBy cmp rows0

-- ---------------------------------------------------------------------
-- Axiom leverage
-- ---------------------------------------------------------------------

-- | For each paper-level axiom, count how many public theorems
-- depend on it. Strict 'IM.insertWith (+)' so we don't accumulate
-- thunks per axiom.
buildLeverage :: [TheoremTrust] -> IM.IntMap Int
buildLeverage = foldl' goThm IM.empty
  where
    goThm !acc TheoremTrust{..} = IS.foldl' bump acc ttAxioms
    bump !acc a = IM.insertWith (+) a 1 acc

-- ---------------------------------------------------------------------
-- Filter diagnostics (stderr + human-output preamble)
-- ---------------------------------------------------------------------

-- | Echo the active scope/source overrides to stderr, but only when
-- they /actually/ change anything.
emitFilterDiagnostics :: Options -> Maybe ExternalsSummary -> IO ()
emitFilterDiagnostics opts mes = mapM_ (hPutStrLn stderr) (filterDiagLines opts mes)

-- | The same lines, as a pure list, suitable for embedding in the
-- human-output preamble (after the @# Ledger ...@ header).
filterDiagLines :: Options -> Maybe ExternalsSummary -> [String]
filterDiagLines opts mes =
  catMaybes [theoremLine, axiomLine]
  where
    thmPrefs = optTheoremPrefixes opts
    axPrefs  = optAxiomModulePrefixes opts
    src      = optAxiomSource opts

    theoremLine
      | not (null thmPrefs) = Just $
          "ledger: theorem set scoped by " ++ countWord (length thmPrefs)
            ++ " --theorem-prefix " ++ pluralEntry (length thmPrefs)
            ++ " (" ++ joinTexts thmPrefs ++ ")."
      | otherwise = case mes of
          Just _  -> Just
            "ledger: theorem set scoped to project-only modules (via externals_summary)."
          Nothing -> Nothing

    axiomLine = case (src, axPrefs) of
      (AsPostulate, []) -> Nothing
      (AsPostulate, _ ) -> Just $
        "ledger: axiom set: --axiom-source=postulate (--axiom-module-prefix ignored "
          ++ "without --axiom-source=record-field|both)."
      _ ->
        Just $
          "ledger: axiom set: --axiom-source=" ++ axiomSourceTag src
            ++ axiomPrefSuffix axPrefs mes
            ++ "."

    axiomSourceTag AsPostulate   = "postulate"
    axiomSourceTag AsRecordField = "record-field"
    axiomSourceTag AsBoth        = "both"

    axiomPrefSuffix [] (Just _) =
      " (record-field scope falls back to project-only modules via externals_summary)"
    axiomPrefSuffix [] Nothing =
      " (record-field scope falls back to non-foundational modules)"
    axiomPrefSuffix prefs _ =
      " with " ++ countWord (length prefs)
        ++ " --axiom-module-prefix " ++ pluralEntry (length prefs)
        ++ " (" ++ joinTexts prefs ++ ")"

    countWord n = show n
    pluralEntry 1 = "entry"
    pluralEntry _ = "entries"
    joinTexts = T.unpack . T.intercalate ", "

-- | Two-line preamble for the human report when filter overrides
-- fired, blank-line-separated from the KPIs. Returns @[]@ when no
-- override applies.
renderFilterHeader :: Options -> Maybe ExternalsSummary -> [String]
renderFilterHeader opts mes = case filterDiagLines opts mes of
  []    -> []
  ls    -> map ("(" ++) (map (++ ")") ls) ++ [""]

-- ---------------------------------------------------------------------
-- Human rendering
-- ---------------------------------------------------------------------

renderHeader :: String
renderHeader = "# Ledger — per-theorem trust budget"

renderKPIs :: Int -> Int -> Int -> String
renderKPIs nThms nAxioms nFound = unlines
  [ "Theorems considered          : " ++ show nThms
  , "Paper-level axioms in graph  : " ++ show nAxioms
  , "Foundational postulates      : " ++ show nFound
  ]

renderTheoremsTable :: Index -> Options -> [TheoremTrust] -> String
renderTheoremsTable ix opts rows0 =
  let !rows = take (optTopN opts) rows0
      header = ["Theorem", "axioms", "found", "axiom names"]
      body   = map (theoremRow ix) rows
  in if null rows
       then "(no theorems matched the filter)\n"
       else renderTable header body

theoremRow :: Index -> TheoremTrust -> [String]
theoremRow ix TheoremTrust{..} =
  let d         = defAt ix ttId
      axNames   = map (T.unpack . defName . defAt ix) (IS.toAscList ttAxioms)
      !axStr    = formatAxiomList axNames
  in [ T.unpack (defName d)
     , show (IS.size ttAxioms)
     , show ttFoundCount
     , axStr
     ]

-- | Truncate the axiom-name list to keep the table from blowing out
-- horizontally. Show first three names, ellipsis if there are more.
formatAxiomList :: [String] -> String
formatAxiomList xs =
  let !n = length xs
      kept = take 3 xs
      tail3 = if n > 3 then ", ..." else ""
  in case kept of
       []  -> "(none)"
       _   -> intercalate ", " kept ++ tail3

renderLeverageTable :: Index -> IM.IntMap Int -> String
renderLeverageTable ix lev
  | IM.null lev = "(no paper-level axioms in graph)\n"
  | otherwise =
      let pairs = IM.toList lev
          cmp (i1, n1) (i2, n2) = case compare n2 n1 of
            EQ -> compare (qnameOf ix i1) (qnameOf ix i2)
            o  -> o
          !sorted = sortBy cmp pairs
          header  = ["Axiom", "theorems using"]
          body    = [ [ T.unpack (defName (defAt ix i)), show n ]
                    | (i, n) <- sorted ]
      in renderTable header body

renderCohorts :: Index -> [([Int], [Int], Int)] -> String
renderCohorts _  []  = "(no cohorts above min size)\n"
renderCohorts ix cs  = unlines (map (renderOneCohort ix) cs)

renderOneCohort :: Index -> ([Int], [Int], Int) -> String
renderOneCohort ix (axIds, members, sz) =
  let axNames   = map (T.unpack . defName . defAt ix) axIds
      memNames  = map (T.unpack . defName . defAt ix) members
      memShown  = take 6 memNames
      ellipsis  = if length memNames > 6 then ", ..." else ""
      memStr    = case memShown of
                    [] -> ""
                    _  -> intercalate ", " memShown ++ ellipsis
  in "[axioms: " ++ intercalate ", " axNames ++ "]\n"
       ++ "  cohort size: " ++ show sz ++ "\n"
       ++ "  members: " ++ memStr

-- | Render the foundational tail from the producer's
-- @externals_summary@ diagnostic. Mirrors the look of
-- 'AgdaOptimization.Debt.renderFoundationalInventoryFromSummary' but
-- under the section title used by this analysis.
renderFoundationalTailFromSummary :: Maybe ExternalsSummary -> String
renderFoundationalTailFromSummary Nothing = ""
renderFoundationalTailFromSummary (Just (ExternalsSummary _mods pm))
  | null rows0 = ""
  | otherwise =
      let cmp (m1, p1) (m2, p2) =
            case compare (length p2) (length p1) of
              EQ -> compare m1 m2
              o  -> o
          !rows = sortBy cmp rows0
          totalPost = sum (map (length . snd) rows)
          totalMods = length rows
          rowCells (m, ps) =
            let !n      = length ps
                !take3  = take 3 ps
                ellipsis = if n > 3 then ["..."] else []
                !exs    = T.intercalate ", " (take3 ++ map T.pack ellipsis)
            in [T.unpack m, show n, T.unpack exs]
          header = ["Module", "Postulates", "Examples"]
          body   = map rowCells rows
      in "## Foundational postulates (trusted base)\n"
           ++ "   (from externals_summary)\n\n"
           ++ renderTable header body
           ++ "\nTotal: " ++ show totalPost
           ++ " postulate" ++ (if totalPost == 1 then "" else "s")
           ++ " across "  ++ show totalMods
           ++ " module"   ++ (if totalMods == 1 then "" else "s")
           ++ "."
  where
    rows0 = [ (m, ps) | (m, ps) <- Map.toList pm, not (null ps) ]

-- ---------------------------------------------------------------------
-- JSON rendering
-- ---------------------------------------------------------------------

ledgerJson
  :: Index
  -> Options
  -> [TheoremTrust]              -- ^ all theorems (unfiltered)
  -> [TheoremTrust]              -- ^ sorted/filtered for the table
  -> [([Int], [Int], Int)]       -- ^ cohorts (axiom-key, members, size)
  -> IM.IntMap Int               -- ^ axiom leverage
  -> Int                         -- ^ theorems considered
  -> Int                         -- ^ paper-level axiom count
  -> Int                         -- ^ foundational count
  -> A.Value
ledgerJson ix opts allThms shown cohorts leverage nThms nAxioms nFound =
  let -- 'shown' already respects --top-n / --min-axioms; the JSON
      -- audience usually wants the full set, so we emit 'allThms'
      -- in deterministic order (by id ascending) — the human table
      -- uses 'shown'.
      thmsForJson = sortBy (comparing ttId) allThms
      thmsArr = map (theoremJson ix) (take (optTopN opts) thmsForJson)
      cohortArr = map (cohortJson ix) cohorts
      levArr = leverageJson ix leverage
      tailFields = case (optIncludeFoundational opts,
                        idxExternalsSummary ix) of
        (True, Just es) ->
          let rows = foundationalTailRows es
          in if null rows then []
                          else [ "foundational_tail" .= rows ]
        _ -> []
      _ = shown -- intentionally unused: JSON consumers reconstruct
                -- the filtered/sorted view themselves from 'theorems'
  in A.object $
       [ "subcommand" .= ("ledger" :: Text)
       , "options"    .= ledgerOptionsJson opts
       , "stats"      .= A.object
           [ "theorems_considered"      .= nThms
           , "paper_axioms"             .= nAxioms
           , "foundational_postulates"  .= nFound
           ]
       , "theorems"        .= thmsArr
       , "cohorts"         .= cohortArr
       , "axiom_leverage"  .= levArr
       ]
       ++ tailFields

ledgerOptionsJson :: Options -> A.Value
ledgerOptionsJson Options{..} = A.object
  [ "top_n"                  .= optTopN
  , "include_foundational"   .= optIncludeFoundational
  , "min_axioms"             .= optMinAxioms
  , "cohort_min_size"        .= optCohortMinSize
  , "axiom_source"           .= axiomSourceJson optAxiomSource
  , "axiom_module_prefixes"  .= optAxiomModulePrefixes
  , "theorem_prefixes"       .= optTheoremPrefixes
  ]

axiomSourceJson :: AxiomSource -> Text
axiomSourceJson AsPostulate   = "postulate"
axiomSourceJson AsRecordField = "record-field"
axiomSourceJson AsBoth        = "both"

theoremJson :: Index -> TheoremTrust -> A.Value
theoremJson ix TheoremTrust{..} =
  let d       = defAt ix ttId
      axNames = map (defName . defAt ix) (IS.toAscList ttAxioms)
  in A.object
       [ "qname"              .= defName d
       , "module"             .= defModule d
       , "axioms_count"       .= IS.size ttAxioms
       , "foundational_count" .= ttFoundCount
       , "axioms"             .= axNames
       ]

cohortJson :: Index -> ([Int], [Int], Int) -> A.Value
cohortJson ix (axIds, members, sz) =
  let axNames  = map (defName . defAt ix) axIds
      memNames = map (defName . defAt ix) members
  in A.object
       [ "axioms"  .= axNames
       , "size"    .= sz
       , "members" .= memNames
       ]

leverageJson :: Index -> IM.IntMap Int -> [A.Value]
leverageJson ix lev =
  let pairs = IM.toList lev
      cmp (i1, n1) (i2, n2) = case compare n2 n1 of
        EQ -> compare (qnameOf ix i1) (qnameOf ix i2)
        o  -> o
      !sorted = sortBy cmp pairs
  in [ A.object [ "axiom"          .= defName (defAt ix i)
                , "theorems_using" .= n
                ]
     | (i, n) <- sorted
     ]

-- | Rows for the JSON @foundational_tail@ field. Same shape as the
-- human renderer: one entry per module with at least one postulate.
foundationalTailRows :: ExternalsSummary -> [A.Value]
foundationalTailRows (ExternalsSummary _mods pm) =
  let rows0 = [ (m, ps) | (m, ps) <- Map.toList pm, not (null ps) ]
      cmp (m1, p1) (m2, p2) =
        case compare (length p2) (length p1) of
          EQ -> compare m1 m2
          o  -> o
      !rows = sortBy cmp rows0
      mkRow (m, ps) =
        let !n   = length ps
            !exs = take 3 ps
        in A.object
             [ "module"   .= m
             , "count"    .= n
             , "examples" .= exs
             ]
  in map mkRow rows

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

-- | Fully-qualified name lookup by id. Crashes on invalid id (matches
-- 'defAt' contract).
qnameOf :: Index -> Int -> Text
qnameOf ix i = defName (defAt ix i)
