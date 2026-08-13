-- A module that batch `agda` REJECTS with [UnsolvedMetaVariables] but the
-- interaction mode loads with zero errors, zero warnings, and zero visible
-- goals: the missing `bad` field elaborates to a metavariable nothing can
-- solve, and `use` projects it out at type ⊥.
--
-- The bridge's verdict must be ✗ here (AgdaInteract.Tools.checkAcceptable):
-- the meta arrives in AllGoalsWarnings.invisibleGoals, which is the ONLY
-- place the wire reports it.
module Unsolved where

data ⊥ : Set where

data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ

record R : Set₁ where
  field A   : Set
        n   : ℕ
        bad : ⊥

t : R
t = record { go }
  where module go where
  A = ℕ
  n = zero
  -- `bad` deliberately missing

use : ⊥
use = R.bad t
