-- Single-hole fixture for the `auto` (Mimer) end-to-end check: a goal
-- Mimer can always solve (any Nat fills it — the in-scope `x`, `zero`, …),
-- so the test asserts "auto fills it and the result typechecks" without
-- pinning Mimer's exact choice.
module AutoOne where

open import Agda.Builtin.Nat

f : Nat → Nat
f x = {!!}
