-- Goal-fill convergence fixture: every hole is closable by a single
-- `give`, with a known term. Solved bottom-up so each edit never shifts an
-- earlier hole's offset (keeping its stable goal id). Driven by
-- test/interaction/convergence.py.
module Nat where

open import Agda.Builtin.Nat

one : Nat
one = {!!}            -- give: 1

two : Nat
two = {!!}            -- give: 2

inc : Nat → Nat
inc n = {!!}          -- give: suc n
