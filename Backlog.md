# Backlog

Deferred and refused ideas. Shipped: [Changelog.md](Changelog.md); recipes:
[Examples.md](Examples.md); forward-looking: [TODO.md](TODO.md); answered
requests: [Deferred.md](Deferred.md).

---

## Deferred — would be useful, no current push

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
