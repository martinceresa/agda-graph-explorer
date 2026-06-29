-- | Thin re-export of 'AgdaGraph.GoalCanon'.
--
-- The goal-type canonicaliser (and its vendored-Murmur64 'hashString'
-- — see the gotcha in @CLAUDE.md@) lives in the shared @agda-graph@
-- library so both @agda-goals@ (via 'AgdaGoals.Bucket') and
-- @agda-explore@'s @find_lemma@ tool import one definition.
module AgdaGoals.Canon
  ( -- * Canonical form
    CanonicalGoal(..)
  , canonicalizeGoal

    -- * Hash
  , hashCanonical
  ) where

import           AgdaGraph.GoalCanon ( CanonicalGoal(..), canonicalizeGoal
                                     , hashCanonical )
