{-# LANGUAGE OverloadedStrings #-}
-- | Pure report rendering + exit-code policy for @agda-auto@, over the
-- 'AutoAllOutcome' that @autoAllCore@ produces. State-free (it lives in the
-- offline test suite): 'outcomeExit' and 'outcomeJson' are pinned there.
--
-- Two surfaces:
--
--   * 'renderHumanReport' — a per-hole table (id, line:col, status, note) with
--     a one-line summary header. The caller ("AgdaAuto.Run") appends the diff /
--     apply body from @applyOrDiff@ below it.
--   * 'outcomeJson' — a structured object. __Public format__; the field names
--     below are a contract (a golden pin in test/Spec.hs guards them). @wrote@
--     and @diff@ come from the caller (the apply step is IO).
--
-- Exit code ('outcomeExit'): @0@ = no hole remains open (all filled, or none
-- existed); @1@ = at least one hole unsolved / skipped, or the run was cut
-- short by an abort; operational errors (@2@) are the caller's, not here.
module AgdaAuto.Report
  ( outcomeExit
  , renderHumanReport
  , outcomeJson
    -- * Project-mode aggregation
  , Summary(..)
  , summarize
  , worstExit
  , summaryLine
  , summaryJson
    -- * Attempt ledger
  , ledgerLines
  ) where

import           Data.Aeson          ( Value, object, (.=) )
import           Data.Maybe          ( isJust )
import           Data.Text           ( Text )
import qualified Data.Text           as T
import           System.Exit         ( ExitCode(..) )

import           AgdaGraph.Interaction.Protocol ( GoalRange(..), RangePos(..) )
import           AgdaInteract.AutoReport
                   ( AutoAllOutcome(..), GoalOutcome(..), GoalReport(..), HintProv(..)
                   , codeList, aoHasUnsolved, unsolvedBlock, unsolvedCount )
import qualified AgdaRepair.Strategy as RS

showT :: Show a => a -> Text
showT = T.pack . show

isSolved, isUnsolved, isSkipped :: GoalReport -> Bool
isSolved   g = case grOutcome g of GSolved{}   -> True; _ -> False
isUnsolved g = case grOutcome g of GUnsolved{} -> True; _ -> False
isSkipped  g = case grOutcome g of GSkipped    -> True; _ -> False

-- | @0@ when nothing is left open, else @1@. See the module header.
--
-- "No goals" is success only when the module actually type-checks: with no
-- hole left, an unsolved meta is un-produced evidence, so the file needs a
-- human edit that @agda-auto@ cannot make (Mimer has no interaction point to
-- act on). @--fixpoint@ therefore cannot converge past it — by design, since
-- re-sweeping would change nothing.
outcomeExit :: AutoAllOutcome -> ExitCode
outcomeExit o
  | aoNoGoals o          = if aoHasUnsolved o then ExitFailure 1 else ExitSuccess
  | isJust (aoAbort o)   = ExitFailure 1
  | all isSolved goals   = ExitSuccess
  | otherwise            = ExitFailure 1
  where goals = aoGoals o

-- | The per-hole table + summary header. No diff body — the caller appends it.
renderHumanReport :: AutoAllOutcome -> Text
renderHumanReport o
  | aoNoGoals o, aoHasUnsolved o =
      T.pack (aoFile o) <> ": no open goals, but does NOT type-check — "
        <> unsolvedCount o <> "." <> unsolvedBlock o
  | aoNoGoals o = T.pack (aoFile o) <> ": no open goals."
  | otherwise   = T.intercalate "\n" (header : map goalLine (aoGoals o))
  where
    goals     = aoGoals o
    nSolved   = length (filter isSolved goals)
    nUnsolved = length (filter isUnsolved goals)
    nSkipped  = length (filter isSkipped goals)
    header =
      T.pack (aoFile o) <> ": " <> showT (aoGoalCount o) <> " hole(s) — "
        <> showT nSolved <> " filled, " <> showT nUnsolved <> " unsolved"
        <> (if nSkipped > 0 then ", " <> showT nSkipped <> " skipped" else "")
        <> maybe "" (\m -> "\n  (stopped early: " <> m <> ")") (aoAbort o)
    goalLine g = "  " <> grId g <> " " <> posOf g <> "  " <> statusOf g
    posOf g = case grRange g of
      Just r  -> showT (rpLine (grStart r)) <> ":" <> showT (rpCol (grStart r))
      Nothing -> "?"
    statusOf g = case grOutcome g of
      GSolved _ prov -> "filled" <> provNote (grHoleHints g) prov
      GUnsolved _    -> "UNSOLVED" <> hintsNote g
      GSkipped       -> "skipped (no interaction hole here)"
    -- A hint that came from the hole itself is tagged so the user learns
    -- their nudge worked.
    provNote _  Plain         = ""
    provNote hs (ViaHint h)   = " — via lemma `" <> h <> "`" <> fromHole hs [h]
    provNote hs (ViaBatch bs) =
      " — via " <> codeList bs <> fromHole hs bs
    fromHole hs used = if any (`elem` hs) used then " (from hole)" else ""
    hintsNote g =
      let np = length (grProbeHints g)
          no = length (grOosHints g)
      in (if np > 0 then " — " <> showT np <> " hint(s) tried" else "")
           <> (if no > 0
                 then (if np > 0 then ", " else " — ") <> showT no <> " out of scope"
                 else "")

-- ---------------------------------------------------------------------
-- Project-mode aggregation
-- ---------------------------------------------------------------------

-- | Totals across a project sweep.
data Summary = Summary
  { sumFiles     :: !Int
  , sumGoals     :: !Int
  , sumFilled    :: !Int
  , sumAnnotated :: !Int
  , sumUnsolved  :: !Int
  } deriving (Eq, Show)

-- | Fold per-file @(goals, filled, annotated, unsolved)@ counts into a
-- 'Summary'. @files@ is the number of tuples (input order irrelevant to the
-- totals, but the caller keeps files in order for the per-file sections).
summarize :: [(Int, Int, Int, Int)] -> Summary
summarize = foldl' step (Summary 0 0 0 0 0)
  where
    step (Summary nf ng nfi na nu) (g, fi, a, u) =
      Summary (nf + 1) (ng + g) (nfi + fi) (na + a) (nu + u)

-- | The worst (numerically largest) failure code, 'ExitSuccess' if none failed.
worstExit :: [ExitCode] -> ExitCode
worstExit cs = case [ n | ExitFailure n <- cs ] of
  [] -> ExitSuccess
  ns -> ExitFailure (maximum ns)

-- | One-line human totals footer.
summaryLine :: Summary -> Text
summaryLine s =
  "files " <> showT (sumFiles s) <> ", holes " <> showT (sumGoals s)
    <> ", filled " <> showT (sumFilled s) <> ", annotated " <> showT (sumAnnotated s)
    <> ", unsolved " <> showT (sumUnsolved s)

summaryJson :: Summary -> Value
summaryJson s = object
  [ "files"     .= sumFiles s
  , "goals"     .= sumGoals s
  , "filled"    .= sumFilled s
  , "annotated" .= sumAnnotated s
  , "unsolved"  .= sumUnsolved s
  ]

-- | Structured report. @wrote@: did the caller apply the edit (write mode, and
-- it reloaded clean). @diff@: the unified diff / apply body (@""@ when there
-- was nothing to apply).
outcomeJson :: Bool -> Text -> AutoAllOutcome -> Value
outcomeJson wrote diff o = object
  [ "file"     .= aoFile o
  , "goals"    .= aoGoalCount o
  , "solved"   .= length (filter isSolved   goals)
  , "unsolved" .= length (filter isUnsolved goals)
  , "skipped"  .= length (filter isSkipped  goals)
  , "wrote"    .= wrote
  , "aborted"  .= aoAbort o
  , "diff"     .= diff
  , "holes"    .= map holeJson goals
    -- Additive, and empty for every file that type-checks: the un-produced
    -- evidence a "0 holes" report would otherwise read as success. Rendered
    -- lines (name, type, position), because these have no goal id to key on.
  , "unsolvedMetas"       .= aoMetas o
  , "unsolvedConstraints" .= aoCons o
  ]
  where
    goals = aoGoals o
    holeJson g = object
      ([ "id"     .= grId g
       , "status" .= statusText g
       ] ++ posFields g ++ detail g)
    statusText g
      | isSolved g   = "solved" :: Text
      | isUnsolved g = "unsolved"
      | otherwise    = "skipped"
    posFields g = case grRange g of
      Just r  -> [ "line" .= rpLine (grStart r), "col" .= rpCol (grStart r) ]
      Nothing -> []
    detail g = case grOutcome g of
      GSolved term prov -> [ "term" .= term, "via" .= viaText prov ]
      GUnsolved _       ->
        [ "hints"   .= map fst (grProbeHints g)
        , "imports" .= [ RS.importLineFor d | (_, d) <- grOosHints g ]
        ]
      GSkipped          -> []

-- | How a solving probe is named in JSON: @plain@ / @lemma:NAME@ / @batch:a,b@.
viaText :: HintProv -> Text
viaText Plain         = "plain"
viaText (ViaHint h)   = "lemma:" <> h
viaText (ViaBatch hs) = "batch:" <> T.intercalate "," hs

-- | One JSON object per goal for the attempt ledger (@--ledger@): a
-- durable per-goal record — file, id, type, outcome, and (per outcome) the
-- solving term / the hints that were available. One line per goal per run
-- (in @--fixpoint@ mode, per pass), so a learner can replay the log.
ledgerLines :: FilePath -> AutoAllOutcome -> [Value]
ledgerLines file o = map goalLine (aoGoals o)
  where
    goalLine g = object $
      [ "file" .= file, "goal" .= grId g, "type" .= grType g, "status" .= status g ]
      ++ extra g
    status g
      | isSolved g   = "solved" :: Text
      | isUnsolved g = "unsolved"
      | otherwise    = "skipped"
    extra g = case grOutcome g of
      GSolved term prov -> [ "term" .= term, "via" .= viaText prov
                           , "fromHole" .= any (`elem` grHoleHints g) (usedOf prov) ]
      GUnsolved _       -> [ "hints"     .= map fst (grProbeHints g)
                           , "holeHints" .= grHoleHints g ]
      GSkipped          -> []
    usedOf Plain         = []
    usedOf (ViaHint h)   = [h]
    usedOf (ViaBatch hs) = hs
