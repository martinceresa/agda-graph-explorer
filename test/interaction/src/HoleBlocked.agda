-- The reason the ✗ rule cannot simply be "any invisible meta is fatal": an
-- ORDINARY `?` hole produces one too. Here `const'`'s implicit `B` cannot be
-- inferred until the hole is filled, so the load reports one visible goal AND
-- one invisible meta (`_B_N : Set`) — wire-indistinguishable from the
-- malignant meta in Unsolved.agda.
--
-- Gating unconditionally would refuse every legitimate work-in-progress file,
-- so AgdaInteract.Tools.checkAcceptable keys on the visible goals being empty.
-- This file must stay ✓ (with the count reported, not silent).
module HoleBlocked where

data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ

const' : {A B : Set} → A → B → A
const' x _ = x

test : ℕ
test = const' zero ?
