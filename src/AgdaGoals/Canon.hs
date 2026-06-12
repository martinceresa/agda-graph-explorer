-- | Thin re-export of 'AgdaGraph.GoalCanon'.
--
-- The goal-type canonicaliser (and its vendored-Murmur64 'hashString'
-- — see the gotcha in @CLAUDE.md@) moved into the shared @agda-graph@
-- library so both @agda-goals@ (this executable, via
-- 'AgdaGoals.Bucket') and @agda-explore@'s @find_lemma@ tool import one
-- definition. This module keeps the historical @AgdaGoals.Canon@ name
-- resolving so 'AgdaGoals.Bucket' compiles unchanged.
module AgdaGoals.Canon
  ( -- * Canonical form
    CanonicalGoal(..)
  , canonicalizeGoal

    -- * Hash
  , hashCanonical
  ) where

import           AgdaGraph.GoalCanon ( CanonicalGoal(..), canonicalizeGoal
                                     , hashCanonical )
