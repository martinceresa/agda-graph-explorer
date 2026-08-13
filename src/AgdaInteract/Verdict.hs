{-# LANGUAGE OverloadedStrings #-}
-- | The ✓\/✗ verdict on a loaded module: what Agda's reply burst says about
-- completeness, and the one rule that decides whether it counts as done.
--
-- Split out of "AgdaInteract.Tools" (the 'AgdaInteract.Batch' \/
-- 'AgdaInteract.AutoReport' pattern) so it is State-free and the offline test
-- suite can pin the policy without an @agda@ binary — 'checkAcceptable' is
-- read by @check@ __and__ by every write-side gate, so its truth table is the
-- load-bearing thing to test.
--
-- The gap this module closes: Agda's interaction mode is built for editors,
-- where a file with open holes must stay loadable, so it does __not__ promote
-- @[UnsolvedMetaVariables]@ \/ @[UnsolvedConstraints]@ to errors the way batch
-- @agda@ does at the end of a module. A silently-inserted meta (missing record
-- field, un-inferable implicit, failed instance search) is therefore neither
-- an error nor a @?@-goal: it arrives in 'agwInvisibleGoals' with the errors
-- and warnings lists empty. Reading only errors + visible goals reports a
-- clean ✓ over un-produced evidence.
module AgdaInteract.Verdict
  ( -- * The settled diagnostics of a load
    CheckOutcome(..)
  , interpretCheck
  , coHasUnsolved
    -- * The verdict rule
  , Unacceptable(..)
  , checkAcceptable
  , refusalClause
    -- * Rendering
  , checkVerdict
  , renderDiagnostics
  , unsolvedSummary
  , unsolvedClause
  , renderInvisible
  , renderConstraint
  , goalPosNote
  ) where

import           Data.Maybe ( fromMaybe, isNothing )
import           Data.Text  ( Text )
import qualified Data.Text  as T

import           AgdaGraph.Interaction.Protocol
                   ( Reply(..), DisplayInfo(..), Goal(..), GoalRange(..), RangePos(..)
                   , ConstraintEntry(..), InstanceCandidate(..) )
import           AgdaInteract.Session ( SendOutcome(..) )

showT :: Show a => a -> Text
showT = T.pack . show

-- | The full diagnostics of a load — every error, every warning, the open
-- goals, and the __unsolved state__ — for the @check@ tool. Where
-- @interpretLoad@ keeps only the first error or else the goals, this keeps
-- them all so @check@ can report a complete picture in one call.
data CheckOutcome = CheckOutcome
  { coErrors      :: ![Text]
  , coWarnings    :: ![Text]
  , coGoals       :: ![Goal]
  , coInvisible   :: ![Goal]
    -- ^ Unsolved metas that are not interaction points — a missing record
    -- field, a stuck instance argument. Reported by Agda with no error and
    -- no warning; see the module header.
  , coConstraints :: ![ConstraintEntry]
    -- ^ Unsolved constraints, present only when the burst carried a
    -- @Constraints@ reply (@AgdaInteract.Tools.withConstraints@).
  }

interpretCheck :: SendOutcome -> CheckOutcome
interpretCheck out = case out of
  SendTimeout _  -> failed "agda timed out during load (session reset)."
  SendDied _ err -> failed ("agda session ended during load: " <> err)
  SendOk rs      ->
    let agws = [ (vg, ig, es, ws)
               | ReplyDisplayInfo (AllGoalsWarnings vg ig es ws) <- rs ]
        hard = [ m | ReplyDisplayInfo (ErrorReply m) <- rs ]
    in CheckOutcome
         { coErrors      = hard ++ concat [ es | (_, _, es, _) <- agws ]
         , coWarnings    = concat [ ws | (_, _, _, ws) <- agws ]
         , coGoals       = concat [ vg | (vg, _, _, _) <- agws ]
         , coInvisible   = concat [ ig | (_, ig, _, _) <- agws ]
         , coConstraints = concat [ cs | ReplyDisplayInfo (ConstraintsReply cs) <- rs ]
         }
  where
    failed e = CheckOutcome [e] [] [] [] []

-- | Does the elaboration carry un-produced evidence (either flavour)?
coHasUnsolved :: CheckOutcome -> Bool
coHasUnsolved co = not (null (coInvisible co)) || not (null (coConstraints co))

-- | Why a load is not acceptable — 'Nothing' from 'checkAcceptable' means it
-- is.
data Unacceptable
  = UnaccErrors
    -- ^ Agda reported type errors.
  | UnaccUnsolved
    -- ^ No hole left to fill, yet unsolved metas \/ constraints remain.
  deriving (Eq, Show)

-- | __The__ verdict rule, in one pure place: the @check@ ✓\/✗ and every
-- write-side gate read it, so they cannot disagree.
--
-- Unacceptable iff Agda reported errors, __or__ there is no visible goal left
-- and the elaboration still has unsolved metas \/ constraints. That second
-- clause is the one batch @agda@ enforces by promoting
-- @[UnsolvedMetaVariables]@ \/ @[UnsolvedConstraints]@ to errors at the end of
-- a module, and which the interaction mode does not: an unsolved meta is
-- un-produced evidence — an unnamed axiom — so accepting one would void the
-- zero-axiom contract as surely as accepting a @postulate@ (and no grep for
-- @postulate@ would ever find it).
--
-- It keys on the visible goals being empty because an invisible meta is
-- __routine and benign__ while holes remain: an implicit argument blocked on a
-- hole's eventual content is one, and it is wire-indistinguishable from a
-- malignant one (@test\/interaction\/src\/HoleBlocked.agda@ vs
-- @Unsolved.agda@). Gating unconditionally would refuse every legitimate
-- incremental edit; gating here fires exactly when the last hole closes, which
-- is also the moment the file would be handed to batch @agda@.
--
-- Residual, deliberate: a file with an honest hole /and/ an unrelated silent
-- meta reads acceptable, because the wire cannot say which meta is blocked on
-- which hole. It is caught the moment the last hole is filled.
checkAcceptable :: CheckOutcome -> Maybe Unacceptable
checkAcceptable co
  | not (null (coErrors co))            = Just UnaccErrors
  | null (coGoals co), coHasUnsolved co = Just UnaccUnsolved
  | otherwise                           = Nothing

-- | The clause a write-side gate uses to say /why/ it refused. The details
-- come from 'renderDiagnostics'.
refusalClause :: CheckOutcome -> Unacceptable -> Text
refusalClause _  UnaccErrors   = "does not type-check"
refusalClause co UnaccUnsolved =
  "elaborates with " <> unsolvedSummary co
    <> " and no open goal to fill — un-produced evidence is an unnamed axiom"

-- | "1 unsolved meta(s)" \/ "… and 2 unsolved constraint(s)".
unsolvedSummary :: CheckOutcome -> Text
unsolvedSummary co = T.intercalate " and " (metaPart ++ consPart)
  where
    k = length (coInvisible co)
    m = length (coConstraints co)
    metaPart = [ showT k <> " unsolved meta(s)"       | k > 0 ]
    consPart = [ showT m <> " unsolved constraint(s)" | m > 0 ]

-- | The one-line ✓\/✗ verdict. The ✗ side is 'checkAcceptable', so a file with
-- no goals left and an unsolved meta reads ✗ even with zero errors.
--
-- The unsolved counts render only when nonzero, which keeps this line
-- byte-identical to the pre-unsolved-reporting one for every clean file (and
-- keeps the plugin hook's @grep ✗@ contract intact).
checkVerdict :: FilePath -> CheckOutcome -> Text
checkVerdict file co =
  (if isNothing (checkAcceptable co) then "✓ type-checks" else "✗ does not type-check")
    <> " — " <> T.pack file
    <> " (" <> (let n = length (coGoals co)
                in if n == 0 then "no open goals" else showT n <> " open goal(s)")
    <> unsolvedClause co
    <> ", " <> showT (length (coErrors co)) <> " error(s), "
    <> showT (length (coWarnings co)) <> " warning(s))."

-- | The ", K unsolved meta(s), M unsolved constraint(s)" insert. Empty when
-- both are zero. While goals remain the counts are qualified rather than
-- damning — an implicit blocked on a hole is one of these.
unsolvedClause :: CheckOutcome -> Text
unsolvedClause co
  | not (coHasUnsolved co) = ""
  | otherwise              = ", " <> unsolvedSummary co <> blocked
  where
    blocked = if null (coGoals co) then "" else " (may be blocked on the open goals)"

renderDiagnostics :: CheckOutcome -> Text
renderDiagnostics co = errBlock <> warnBlock <> metaBlock <> consBlock
  where
    errBlock  = if null (coErrors co) then ""
                else "\n\nErrors:\n"   <> T.unlines [ "  • " <> e | e <- coErrors co ]
    warnBlock = if null (coWarnings co) then ""
                else "\n\nWarnings:\n" <> T.unlines [ "  • " <> w | w <- coWarnings co ]
    -- Unsolved metas carry no interaction point, so they are report-only:
    -- named + located, never addressable as a goal id. The header follows the
    -- rule — damning with no hole left, merely informative while holes remain.
    metaBlock = if null (coInvisible co) then ""
                else "\n\nUnsolved metas (" <> metaGloss <> "):\n"
                       <> T.unlines [ "  • " <> renderInvisible g | g <- coInvisible co ]
    metaGloss
      | null (coGoals co) = "no hole to fill — Agda inserted these"
      | otherwise         = "Agda inserted these; may be blocked on the open goals"
    consBlock = if null (coConstraints co) then ""
                else "\n\nUnsolved constraints:\n"
                       <> T.unlines [ "  • " <> renderConstraint c | c <- coConstraints co ]

-- | @_bad_12 : ⊥   (15:5)@ — the meta's internal name is the only handle it
-- has.
renderInvisible :: Goal -> Text
renderInvisible g =
  fromMaybe "_" (goalName g) <> " : " <> goalType g <> goalPosNote g

-- | @FindInstanceOF _r_10 : Eq Bool   (19:8)@ plus the candidate list, which
-- is what makes a stuck instance search actionable.
renderConstraint :: ConstraintEntry -> Text
renderConstraint c
  | T.null (cnKind c) = cnRaw c
  | otherwise         =
      cnKind c
        <> maybe "" (" " <>) (cnMeta c)
        <> maybe "" (" : " <>) (cnType c)
        <> maybe "" (\(GoalRange s _) -> "   (" <> showT (rpLine s) <> ":" <> showT (rpCol s) <> ")")
                 (cnRange c)
        <> (if null (cnCandidates c) then ""
            else "\n      candidates: "
                   <> T.intercalate ", " [ icValue k <> " : " <> icType k | k <- cnCandidates c ])

goalPosNote :: Goal -> Text
goalPosNote g = case goalRange g of
  Just (GoalRange s _) -> "   (" <> showT (rpLine s) <> ":" <> showT (rpCol s) <> ")"
  Nothing              -> ""
