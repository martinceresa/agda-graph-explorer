-- Richer fixture for the agent-driven pass: closing every hole needs a
-- case-split, a refine, and plain gives. Intended proofs in comments.
module Proof where

open import Agda.Builtin.Nat
open import Agda.Builtin.Bool

-- case_split on b, then give: not true = false ; not false = true
neg : Bool → Bool
neg b = {!!}

-- refine `suc`, then give 2 into the residual hole  →  suc 2  (= 3)
three : Nat
three = {!!}

-- plain give: x + x
double : Nat → Nat
double x = {!!}
