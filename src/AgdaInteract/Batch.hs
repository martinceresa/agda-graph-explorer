{-# LANGUAGE OverloadedStrings #-}
-- | Pure dispatch vocabulary for the write-side batcher tools — @construct@'s
-- 'Step' shape plus its wildcard / all-@give@ discriminators, and the @op@
-- validators for the @inspect@ and @scratch@ batchers. Extracted from
-- 'AgdaInteract.Tools' so the offline test-suite covers the routing logic
-- without the server-state stack (and stays agda-free).
module AgdaInteract.Batch
  ( -- * construct steps
    Step(..)
  , stepLabel, stepGoal, stepOp
  , isGiveStep, allGiveSteps
  , wildcardCheck
    -- * inspect / scratch op enums + validators
  , inspectOps, scratchOps
  , checkInspectArgs
  , checkScratchOp
  ) where

import           Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import           Data.Maybe (catMaybes, isNothing, listToMaybe)
import           Data.Text  (Text)

-- ---------------------------------------------------------------------
-- construct steps
-- ---------------------------------------------------------------------

-- | One @construct@ step: @op@, target @goal@ (a stable id, or @"*"@ = every
-- open goal, @auto@ only), and the single op-specific argument — @term@ (give)
-- / @expr@ (refine) / @var@ (case_split), collapsed to one optional field.
data Step = Step !Text !Text !(Maybe Text)

instance FromJSON Step where
  parseJSON = withObject "step" $ \o -> do
    op <- o .:  "op"
    g  <- o .:  "goal"
    mt <- o .:? "term"
    me <- o .:? "expr"
    mv <- o .:? "var"
    pure (Step op g (listToMaybe (catMaybes [mt, me, mv])))

stepLabel :: Step -> Text
stepLabel (Step op g _) = op <> " " <> g

stepGoal :: Step -> Text
stepGoal (Step _ g _) = g

stepOp :: Step -> Text
stepOp (Step op _ _) = op

-- | A pure @give@ step (op=give), the fast-path discriminator.
isGiveStep :: Step -> Bool
isGiveStep = (== "give") . stepOp

-- | Every step is a @give@ ⇒ eligible for the single-load atomic fast path.
allGiveSteps :: [Step] -> Bool
allGiveSteps = all isGiveStep

-- | Validate the wildcard @goal:"*"@ usage. A @*@ goal means "apply to every
-- open goal" and is only meaningful for @auto@; reject it for
-- give/refine/case_split, and require it to stand alone (it already targets
-- every goal, so combining it with other steps is ill-defined). @Right True@
-- = the single wildcard-auto shorthand, @Right False@ = no wildcard present,
-- @Left@ = a misuse to report.
wildcardCheck :: [Step] -> Either Text Bool
wildcardCheck steps = case filter ((== "*") . stepGoal) steps of
  []  -> Right False
  ws  -> case filter ((/= "auto") . stepOp) ws of
    (s:_) -> Left ("construct: `goal:\"*\"` (every open goal) is valid for op=auto only; \
                   \step `" <> stepLabel s <> "` uses it otherwise.")
    []    | length steps == 1 -> Right True
          | otherwise ->
              Left "construct: a `goal:\"*\"` auto step targets every open goal, so it \
                   \must be the only step."

-- ---------------------------------------------------------------------
-- inspect / scratch op enums + validators
-- ---------------------------------------------------------------------

-- | The @op@ enum for the @inspect@ read-only live-goal batcher — one source
-- for the schema enum and the runner's dispatch/validation.
inspectOps :: [Text]
inspectOps = ["type", "context", "infer", "normalize"]

-- | The @op@ enum for the @scratch@ staging-lifecycle batcher.
scratchOps :: [Text]
scratchOps = ["open", "promote", "discard"]

-- | Pure pre-flight for @inspect@: recognise the @op@ and enforce that
-- @infer@\/@normalize@ carry an @expr@ (the type\/context ops don't). Returns
-- the validated op; a bad op or a missing @expr@ fails here without touching
-- agda.
checkInspectArgs :: Maybe Text -> Maybe Text -> Either Text Text
checkInspectArgs mop mexpr = case mop of
  Nothing -> Left "inspect requires an `op` (type|context|infer|normalize)."
  Just op
    | op `notElem` inspectOps ->
        Left ("inspect: unknown op `" <> op <> "` (use type|context|infer|normalize).")
    | op `elem` ["infer", "normalize"], isNothing mexpr ->
        Left ("inspect op=" <> op <> " requires an `expr`.")
    | otherwise -> Right op

-- | Pure @op@ check for @scratch@. The per-op required fields
-- (@scratch@\/@target@) are enforced by the runners it dispatches to, so their
-- diagnostics stay verbatim.
checkScratchOp :: Maybe Text -> Either Text Text
checkScratchOp mop = case mop of
  Nothing -> Left "scratch requires an `op` (open|promote|discard)."
  Just op
    | op `elem` scratchOps -> Right op
    | otherwise            ->
        Left ("scratch: unknown op `" <> op <> "` (use open|promote|discard).")
