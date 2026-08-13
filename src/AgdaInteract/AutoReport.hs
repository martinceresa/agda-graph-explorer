{-# LANGUAGE OverloadedStrings #-}
-- | Pure data + rendering for the @auto_all@ ladder (and @agda-auto@).
--
-- Split out of "AgdaInteract.Tools" — which pulls in "AgdaMcp.State" — so the
-- offline test suite can pin the human rendering agda-free (the same reason
-- "AgdaInteract.Batch" exists). 'AutoAllOutcome' is the structured result
-- @autoAllCore@ produces; 'renderAutoAll' turns it back into the exact prose
-- the MCP @auto_all@ tool has always emitted (byte-identity is a pinned test),
-- and @agda-auto@ consumes the record directly for its report + exit code.
--
-- The rendering-relevant aggregates ('aoSolved' \/ 'aoUnsolved' \/ 'aoAllCands'
-- \/ 'aoOosNames' \/ …) are stored explicitly rather than re-derived from
-- 'aoGoals': the two-pass ladder emits solved ids in @pass1 ++ pass2@ order,
-- not input order, so a derivation would not be byte-identical. 'aoGoals' is
-- the input-order structured view for the report \/ JSON \/ annotation;
-- 'renderAutoAll' never reads it.
module AgdaInteract.AutoReport
  ( HintProv(..)
  , GoalOutcome(..)
  , GoalReport(..)
  , AutoAllOutcome(..)
  , noGoalsOutcome
  , aoHasUnsolved
  , unsolvedBlock
  , unsolvedCount
  , renderAutoAll
  , oosNote
  , annotationEdits
  , codeList
  ) where

import           Data.Maybe          ( mapMaybe )
import           Data.Text           ( Text )
import qualified Data.Text           as T
import qualified Data.Map.Strict     as M

import           AgdaGraph.Interaction.Protocol ( GoalRange(..), RangePos(..) )
import           AgdaGraph.Schema    ( Definition )
import           AgdaInteract.Annotate ( Annotation(..), annotateHole )
import qualified AgdaRepair.Strategy as RS

-- | How a Mimer probe closed a goal (rides back so a closing lemma can be
-- named).
data HintProv
  = Plain            -- ^ the unhinted probe.
  | ViaHint !Text    -- ^ a single lemma hint (the per-hint fallback).
  | ViaBatch ![Text] -- ^ the in-scope hint batch in one call (may combine ≥2 lemmas).
  deriving (Eq, Show)

-- | Per-goal outcome. The structured view the report / JSON / annotation
-- consume.
data GoalOutcome
  = GSolved !Text !HintProv     -- ^ Mimer's term + how it was found.
  | GUnsolved !(Maybe Text)     -- ^ nothing found; optional plain-probe Agda error.
  | GSkipped                    -- ^ no interaction id / range, or not inside a code block.
  deriving (Eq, Show)

-- | One goal's record. 'grRange' carries the hole's full range — line\/column
-- (for the report) and the 1-based character offsets (for splicing) —
-- when known. The hint fields mirror exactly what this goal contributed to the
-- run's hint aggregates, so they reproduce the OOS reporting.
data GoalReport = GoalReport
  { grId         :: !Text                     -- ^ rendered stable id (@g0@, …).
  , grType       :: !Text                     -- ^ the goal type text.
  , grRange      :: !(Maybe GoalRange)        -- ^ hole range (line\/col + char offsets), when known.
  , grOutcome    :: !GoalOutcome
  , grProbeHints :: ![(Text, Definition)]     -- ^ graph-ranked in-scope hints fetched (empty if none).
  , grOosHints   :: ![(Text, Definition)]     -- ^ pre-classified out-of-scope hints (reported, never probed).
  , grBounced    :: ![Text]                   -- ^ hint names Agda rejected as OOS during this goal's probing.
  , grHoleHints  :: ![Text]                   -- ^ hint names read from the hole itself, probed first.
  } deriving (Show)

-- | Everything the @auto_all@ ladder produced for one file. See the module
-- header for why the aggregates are explicit rather than derived from
-- 'aoGoals'.
data AutoAllOutcome = AutoAllOutcome
  { aoFile      :: !FilePath              -- ^ the module probed.
  , aoOrig      :: !Text                  -- ^ its source text at probe time.
  , aoNew       :: !(Maybe Text)          -- ^ the spliced result to apply/diff (solved gives + any annotation markers); 'Nothing' ⇒ nothing to apply.
  , aoNoGoals   :: !Bool                  -- ^ the "loaded, no open goals" early case.
  , aoGoalCount :: !Int                   -- ^ number of open goals found.
  , aoSecs      :: !Int                   -- ^ per-goal budget used (for the message).
  , aoSolved    :: ![Text]                -- ^ solved goal ids, in solve order (pass1 ++ pass2).
  , aoUnsolved  :: ![Text]                -- ^ unsolved goal ids, for the survivors line.
  , aoAbort     :: !(Maybe Text)          -- ^ a wall-budget / session-death message, if the run was cut short.
  , aoAllCands  :: ![(Text, Definition)]  -- ^ every hint candidate (for the OOS import-line lookup).
  , aoOosNames  :: ![Text]                -- ^ out-of-scope hint names to report (already nub'd).
  , aoGoals     :: ![GoalReport]          -- ^ per-goal structured view, input order (report/JSON/annotation).
  , aoMetas     :: ![Text]                -- ^ rendered silent unsolved metas; see 'noGoalsOutcome'.
  , aoCons      :: ![Text]                -- ^ rendered unsolved constraints; likewise.
  } deriving (Show)

-- | The "loaded, no open goals" outcome (rendered by 'renderAutoAll' as the
-- standalone note; 'aoNew' is 'Nothing', so the tool applies nothing).
--
-- @metas@ \/ @cons@ are the file's unsolved metas and constraints, rendered by
-- the caller. Populated __only here__, because only here are they decisive:
-- with no hole left, an unsolved meta is un-produced evidence and the file
-- is not done (batch @agda@ would reject it), so this "no goals" is not a
-- clean bill of health. While holes remain the same metas are routinely
-- benign — an implicit blocked on a hole is one — and filling the hole
-- solves them, so counting them there would fail honest work-in-progress.
noGoalsOutcome :: FilePath -> [Text] -> [Text] -> AutoAllOutcome
noGoalsOutcome file metas cons = AutoAllOutcome
  { aoFile = file, aoOrig = "", aoNew = Nothing, aoNoGoals = True
  , aoGoalCount = 0, aoSecs = 0, aoSolved = [], aoUnsolved = []
  , aoAbort = Nothing, aoAllCands = [], aoOosNames = [], aoGoals = []
  , aoMetas = metas, aoCons = cons }

-- | Does the file carry un-produced evidence (either flavour)?
aoHasUnsolved :: AutoAllOutcome -> Bool
aoHasUnsolved o = not (null (aoMetas o)) || not (null (aoCons o))

-- | The report block naming every unsolved meta \/ constraint. Empty when
-- there are none, so a clean run's output is unchanged.
unsolvedBlock :: AutoAllOutcome -> Text
unsolvedBlock o
  | not (aoHasUnsolved o) = ""
  | otherwise = "\n" <> section "Unsolved metas (no hole to fill — Agda inserted these)" (aoMetas o)
                     <> section "Unsolved constraints" (aoCons o)
                     <> "These are un-produced evidence, not holes: Mimer cannot fill them \
                        \(they have no interaction point). Fix the source — a missing record \
                        \field, an ambiguous instance, an un-inferable implicit."
  where
    section _ []     = ""
    section h xs     = "\n" <> h <> ":\n" <> T.unlines [ "  • " <> x | x <- xs ]

-- | "1 unsolved meta(s)" / "… and 2 unsolved constraint(s)".
unsolvedCount :: AutoAllOutcome -> Text
unsolvedCount o = T.intercalate " and " (part "meta" (aoMetas o) ++ part "constraint" (aoCons o))
  where
    part label xs = [ showT (length xs) <> " unsolved " <> label <> "(s)" | not (null xs) ]

showT :: Show a => a -> Text
showT = T.pack . show

-- | Identifiers as a comma-separated backtick-quoted list, e.g. @`a`, `b`@.
codeList :: [Text] -> Text
codeList hs = T.intercalate ", " [ "`" <> h <> "`" | h <- hs ]

-- | Footer flagging graph-ranked hints Mimer could not try because they are
-- out of the file's import scope; names each defining module's ready-to-paste
-- import line (from the def the hint was ranked off, so it is exact). Blank
-- when nothing was out of scope. Honest phrasing: untried candidates, not
-- verified closers.
oosNote :: Text -> [(Text, Definition)] -> [Text] -> Text
oosNote _    _     []  = ""
oosNote tool cands oos =
  "\nNote — " <> showT (length oos) <> " graph-ranked hint(s) are \
  \not in the file's import scope, so Mimer could not try them:\n"
    <> T.unlines [ "  - `" <> h <> "`" <> importHint h | h <- oos ]
    <> "Add the import(s) and re-run `" <> tool <> "`, or run `repair file=…` to add them for you."
  where
    importHint h = case lookup h cands of
      Just d  -> " — add `" <> RS.importLineFor d <> "`"
      Nothing -> ""

-- | Marker edits for a run's unsolved holes (empty when @annotate@ is off).
-- Only 'GUnsolved' goals with a range get a marker — those were probed, so they
-- are genuine holes inside a code block; solved / skipped goals are left alone.
-- The marker replaces the hole's own range, so these are disjoint from the
-- solved-goal gives. Shared by @agda-auto@ and, under @annotate:true@, the
-- MCP @auto_all@ path. @secs@ is the per-goal budget, for the @tried:@ line.
annotationEdits :: Bool -> Int -> Text -> [GoalReport] -> [(Int, Int, Text)]
annotationEdits annotate secs orig goals
  | not annotate = []
  | otherwise    = mapMaybe editFor goals
  where
    editFor g = case (grOutcome g, grRange g) of
      (GUnsolved _, Just r) ->
        let s   = rpPos (grStart r)
            e   = rpPos (grEnd r)
            old = T.take (e - s) (T.drop (s - 1) orig)  -- 1-based half-open [s,e)
        in Just (s, e, annotateHole old (annOf g))
      _ -> Nothing
    annOf g = Annotation
      { annGoalType = grType g
      , annTried    = "plain " <> showT secs <> "s + " <> showT (length (grProbeHints g)) <> " hints"
      , annTry      = map fst (grProbeHints g)
      , annImports  = [ RS.importLineFor d | (_, d) <- grOosHints g ]
      }

-- | Render an 'AutoAllOutcome' as the human message the @auto_all@ tool emits.
-- For a run that produced edits, this is the /headline/ (ending in a blank
-- line); the tool then appends the unified diff (or the apply-and-reload
-- report) from @applyOrDiff@. For no-edits / no-goals it is the whole message.
-- Byte-identical output is pinned in test/Spec.hs.
renderAutoAll :: AutoAllOutcome -> Text
renderAutoAll o
  | aoNoGoals o, aoHasUnsolved o =
      "Loaded " <> T.pack (aoFile o) <> " — no open goals, but the module does \
      \not type-check: " <> unsolvedCount o <> " remain and nothing for Mimer to try.\n"
        <> unsolvedBlock o
  | aoNoGoals o =
      "Loaded " <> T.pack (aoFile o) <> " — no open goals; nothing for Mimer to try."
  | null (aoSolved o) =
      "Mimer solved none of the " <> showT (aoGoalCount o) <> " open goal(s) in "
        <> T.pack (aoFile o) <> " (per-goal budget " <> showT (aoSecs o) <> "s)."
        <> survivors
  | otherwise =
      "Mimer solved " <> showT (length (aoSolved o)) <> " of " <> showT (aoGoalCount o)
        <> " open goal(s): " <> T.intercalate ", " (aoSolved o) <> "." <> survivors <> "\n\n"
  where
    hintMap    = M.toList (M.fromListWith (\_ old -> old) (aoAllCands o))
    oosBlock   = oosNote "auto_all" hintMap (aoOosNames o)
    abortBlock = maybe "" ("\n" <>) (aoAbort o)
    survivors
      | null (aoUnsolved o) = oosBlock <> abortBlock
      | otherwise =
          "\nMimer found nothing for: " <> T.intercalate ", " (aoUnsolved o)
            <> " — try a `construct` refine step, `lemmas goal=…`, or `construct` an explicit give."
            <> oosBlock <> abortBlock
