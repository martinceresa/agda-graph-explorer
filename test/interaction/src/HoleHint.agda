module HoleHint where

-- Phase-D fixture: does Mimer read a hole's CONTENTS as a hint? The hole names
-- `bar`, an in-scope lemma that closes the goal — but plain Mimer won't try an
-- in-scope lemma (CLAUDE.md gotcha), so if the hole body were a native hint the
-- plain autoOne would return a GiveAction. On Agda 2.8 it does NOT (verified),
-- so agda-auto seeds hole hints explicitly. The tripwire: a future agda that
-- starts consuming hole contents would make auto-hole-content.jsonl carry a
-- GiveAction and fail the replay test. Self-contained (Agda.Builtin only).

open import Agda.Builtin.Nat
open import Agda.Builtin.Equality

bar : (n : Nat) → n + 0 ≡ n
bar zero    = refl
bar (suc n) rewrite bar n = refl

foo : (n : Nat) → n + 0 ≡ n
foo n = {! bar !}
