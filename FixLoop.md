# FixLoop — a graph-backed Agda repair loop for `agda-explore`

`repair` is a write-side interaction-bridge tool that takes an almost-correct
Agda file (typically LLM-authored), interprets the compiler's diagnostics, and
drives it to a typechecking, **spec-preserving**, zero-axiom program — or
refuses when the residual error is semantic. It adds missing imports (resolved
off the dependency graph, operators and constructors included) and fixes
misspelled references; it does not prove open goals.

## How it works

Given a broken file (or proposed `content`), the loop:

1. compiles the current text under a throwaway module (`loadRenamedTemp`);
2. classifies the errors (`AgdaRepair.Diagnostic.classify`);
3. proposes candidate edits for the first actionable diagnostic
   (`AgdaRepair.Strategy.candidatesFor`, graph-backed);
4. applies each candidate, guards it (`checkFileInput`), and **re-compiles** to
   validate; accepts the first that compiles clean or resolves the targeted name
   without raising the error count, and reuses that outcome for the next round;
5. iterates to a clean typecheck, a refusal, or `max_iter`.

It returns a `RepairReport` plus a unified diff; `write:true` applies + reloads.

## The graph as scope oracle

Every scope question is a lookup over the graph's real defs, not a text search
— this is what a bare compiler-error fixer can't do:

- **which module exports `X`** — `AgdaRepair.Strategy` indexes `ldRealDefs` by
  underscore-stripped base name (so a bare `×` finds `_×_`), reads `defModule`
  (`defOrigin` marks an overlay def needing an `open import`). Because the graph
  is elaborated scope, it resolves re-export cases a source scan cannot (e.g.
  `ℤ`, re-exported as `Int`).
- **constructors** are namespaced under their datatype (`…​.Nat.suc`), so the
  importable module is the parent — both are offered, recompile picks.
- **typos** — edit distance (≤ 2) over the file's in-scope names and the graph's
  base names; a graph name that isn't in scope is paired with its import.

Import repair therefore needs a graph covering the file's dependencies (e.g. an
`--overlay-graph` for stdlib).

## Error taxonomy → strategy

The classifier keys on Agda's bracketed tags and is lenient (unknown → refuse).

| Diagnostic | Strategy |
|---|---|
| `NotInScope` | add an import (import-only; a typo that no import fixes is reported with a spelling suggestion, never renamed — R25) |
| `NoParseForApplication` (missing operator, e.g. `_×_`) | add the operator's import |
| `NoParseForLHS` (missing constructor in a pattern) | add the constructor's import |
| `IncompletePatternMatching` / `CoverageIssue` | report — run `construct` (a `case_split` step) |
| open goal (no error) | report — run `construct` (`{op:auto, goal:"*"}`) / `lemmas` |
| `UnequalTerms` / `TerminationIssue` / unknown | **refuse**, file untouched |

## Invariants

1. **Spec preservation.** Repair is __import-only__: the sole edit inserts an
   `open import` line (renames were removed — R25 — because a rename can rewrite
   a theorem's meaning to silence a scope error, e.g. `ℕ` → `_#_`). So a repair
   structurally cannot touch existing code, and `firstWorking` still asserts the
   `AgdaRepair.Edit.signatures` set is unchanged as a backstop.
2. **Zero axioms.** Every candidate passes `AgdaInteract.Guard.checkFileInput`
   (no `postulate` / `primTrustMe` / termination-coverage pragmas).
3. **Monotone termination.** A candidate is accepted only if it resolves the
   targeted name without raising the error count. Imports only grow scope, so
   each accepted round adds a new distinct import line and the loop can't
   oscillate.
4. **Diff by default.** No write unless `write:true` (then `applyOrDiff` applies
   + reloads). `content` is always a dry run.

Open goals and incomplete patterns are **detected and routed**, not auto-filled:
filling a goal is proving, and auto-writing a Mimer term would risk the semantic
drift the invariants exist to prevent. `repair` is a sound repair engine, not a
solver.

## Results

Measured by fault injection into known-good VerinaAgda solutions (labelled
ground truth), Agda 2.9, stdlib overlay:

| injected fault | repaired | semantic drift | spec edits |
|---|---|---|---|
| typo (misspelled reference) | reported with a spelling suggestion, not auto-fixed (import-only since R25) | 0 | 0 |
| drop-import (missing import) | 34/39 (87%) | 0 | 0 |
| real semantic failures | correctly refused | — | 0 |

(Pre-R25 the loop renamed typos to a near-match — 20/22 (91%) with 0 drift —
but a rename is a spec edit in disguise, so R25 replaced it with a
non-mutating suggestion. Re-measure the drop-import row after the R24 alias
work lands.)

Cost is a few `agda` recompiles per fix (no model tokens). The strategic point:
a strong LLM+`check` agent already clears mechanical errors itself, so `repair`
is mainly a cheap deterministic pre-pass and an uplift for weaker/single-shot
agents.

## Surfaces

- MCP tool `repair` (args `file` | `content`, `write`, `max_iter`), gated on
  `--enable-interact`.
- One-shot CLI: `agda-explore query repair file=… --graph deps.json
  --enable-interact -i .` (`write=true` to apply).
- Control route `GET /repair?file=…` (diff-only), which the plugin's
  `post-agda-edit.sh` hook calls after a failing `check` to surface a suggested
  fix (never applied).

## Modules

- `AgdaRepair.Diagnostic` — pure classifier over the rendered error text.
- `AgdaRepair.Strategy` — pure, graph-backed candidate generation.
- `AgdaRepair.Edit` — pure, import-only text edits + the signature invariant.
- driver (`runRepair` / `repairLoop` / `firstWorking` / `accepts`) in
  `AgdaInteract.Tools`, so it reuses the bridge's session/validation helpers.

## Limitations

- Separate `open import M using (x)` lines per name rather than one merged
  `using (…)` list (valid, slightly verbose).
- Some coverage-class errors arrive JSON-wrapped (`interpretCheck` quirk shared
  with `check`); classification still works.
