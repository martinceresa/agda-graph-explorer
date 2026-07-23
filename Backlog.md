# Backlog

Deferred and refused ideas. Shipped: [Changelog.md](Changelog.md); recipes:
[Examples.md](Examples.md); forward-looking: [TODO.md](TODO.md); answered
requests: [Deferred.md](Deferred.md).

---

## Deferred — would be useful, no current push

- **Migrate the four hand-rolled CLIs onto the shared `FlagSpec`** (agda-unused
  / agda-goals / agda-explore / agda-auto → the declarative table
  `agda-optimization` uses). Reassessed and deferred during the 2026-07 UX pass
  (see [UX.md](UX.md) §1.4): the stated acceptance gate — `--help` output
  *byte-identical* to the pre-migration goldens — conflicts with `FlagSpec`'s
  flat generated help, because the single-command tools' usage carries
  structure a generator won't reproduce (multi-line USAGE / OPTIONS /
  ENVIRONMENT / EXIT CODES / prose). Reproducing that per tool through the
  renderer is high-churn and defeats the "single source" benefit. The
  drift risk the migration targeted is already largely covered: `--show-defaults`
  binds to each tool's defaults record (no drift), and committed `--help`
  goldens (`test/help/`, checked in CI) make any flag change a reviewable diff.
  The shared completion generator (`AgdaGraph.Completion`) is in place for reuse.
  Reopen if a *new* multi-flag surface wants the table, or if the help format is
  allowed to change (dropping the byte-identical gate).

- **`fiedler` pure-Haskell eigensolver** — replace the SciPy shell-out
  (`scripts/fiedler_helper.py`) with a Haskell Lanczos / power-iteration solver.
  The shell-out is deliberate (SciPy is faster); revisit for a Python-free build.
- **`pyre` — drive `agda --profile` end to end** — calibration ships; deferred:
  an adapter reducing `agda --profile=*` to `{qname: cost}` JSON, and a Bayesian
  fit with uncertainty bands.
- **Surface-AST simplifier with typecheck rollback** — mechanical rewrites
  (`λ x → f x ⇒ f`, `sym (sym p) ⇒ p`, …) with per-module typecheck + rollback;
  highest-risk (a bug can leave the corpus non-typechecking); defer until
  `term-cluster` surfaces candidates. See [TODO.md](TODO.md).
- **Fold `Query`'s six `resolve-or-notFound` prologues into `withResolved`** —
  deferred: restructures control flow in code with no test/oracle coverage.
- **`graph-diff` — two-snapshot graph delta** (was Requests.md §2.3) — a
  first-class "what did this change do to the graph": defs / edges added ·
  removed · changed, derived deltas (newly `unsafe`-reachable, new cycles,
  impact growth), `--fail-on` CI policy gates. Full design + phased roadmap:
  [Graph.Diff.Plan.md](notes/Graph.Diff.Plan.md). Reopen when the Arena CI gate
  ([TODO.md](TODO.md)) wants structural policy checks, or a review-workflow
  consumer materialises.

## Refused

- **`agda-simplify` umbrella executable** (fingerprint + goals + simplify behind
  one binary with a shared `Canon`) — the three canonicalise different types
  (internal `Term`, interaction goals, surface AST), so a shared module adds
  coupling without payoff.

## Deferred — producer-gated

- **Load the packed (~5×-smaller) graph form** — packed omits the per-def
  `kind`/`line`/`access`/`type`/subterm-hashes the analyses need, so a
  consumer-only load would silently cripple `type_of` / `similar_*` /
  `find_lemma` / `unused` / `locate`-line / `search --kind`. `AgdaGraph.Schema`
  refuses it with an actionable error (see `test/packed/README.md`). Real fix: a
  producer `packed-complete` mode keeping the compact encoding + the analytical
  fields, then a small base64-LE + CSR decoder.
