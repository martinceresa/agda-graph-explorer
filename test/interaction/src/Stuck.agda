-- A stuck INSTANCE search: two equally applicable `Eq Bool` instances, so
-- the instance argument of `eq` never resolves. This is the error class the
-- upstream note flagged as the practically important one (record/telescope
-- refactors produce it).
--
-- Unlike Unsolved.agda, the interaction load DOES report an
-- [UnsolvedConstraints] error here — plus the meta in invisibleGoals, plus a
-- structured `Cmd_constraints` entry carrying the candidate list, which is
-- what makes the report actionable.
module Stuck where

data Bool : Set where
  true false : Bool

record Eq (A : Set) : Set where
  field eq : A → A → Bool

open Eq {{...}}

instance
  eqBool1 : Eq Bool
  eqBool1 = record { eq = λ _ _ → true }

  eqBool2 : Eq Bool
  eqBool2 = record { eq = λ _ _ → false }

test : Bool
test = eq true false
