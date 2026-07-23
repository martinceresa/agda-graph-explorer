module Combine where

-- Phase-3a batch fixture: a goal solvable ONLY by combining two in-scope
-- hints (trans' eq1 eq2), which no single hint reaches. Self-contained
-- (Agda.Builtin only) so it regenerates on any agda. See regen.sh.

open import Agda.Builtin.Nat
open import Agda.Builtin.Equality

trans' : {A : Set} {a b c : A} → a ≡ b → b ≡ c → a ≡ c
trans' refl q = q

postulate
  a b c : Nat
  eq1 : a ≡ b
  eq2 : b ≡ c

goal : a ≡ c
goal = ?
