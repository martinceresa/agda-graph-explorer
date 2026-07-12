# Backlog

Deferred and refused ideas on the graph consumers. For shipped work see
[Changelog.md](Changelog.md); for runnable recipes see [Examples.md](Examples.md);
for concrete forward-looking items see [TODO.md](TODO.md); for answered
feature requests see [Deferred.md](Deferred.md).

---

## Deferred — would be useful, no current push

- **`fiedler` — pure-Haskell eigensolver.** `fiedler` is the only subcommand
  that shells out (`scripts/fiedler_helper.py` returns `λ₂` / the Fiedler vector
  via SciPy). A pure-Haskell Lanczos / power-iteration solver would drop the
  Python + SciPy dependency. The shell-out is deliberate (SciPy is faster and
  better-tested). Revisit for a Python-free deployment.

- **`pyre` — drive `agda --profile` end to end.** Calibration shipped
  (`--profile` / `--calibrate` / `--levers`). Deferred: (a) an adapter that runs
  `agda --profile=*` and reduces its text to the consumed `{qname: cost}` JSON;
  (b) a Bayesian fit with uncertainty bands, if the linear point-estimate proves
  too brittle.

- **Surface-AST simplifier with typecheck rollback.** Mechanical local rewrites
  (`λ x → f x ⇒ f`, `subst P refl x ⇒ x`, `sym (sym p) ⇒ p`, …); per-module
  typecheck with rollback on regression; `.agdai`-checksum invariance for
  unmodified modules. Highest-risk piece — the only one where a tool bug can
  leave the corpus non-typechecking. Defer until `term-cluster` surfaces
  concrete candidates. See [TODO.md](TODO.md).

- **Remaining behavior-preserving cleanups** (from the 2026-07-12 pass). Fold
  `Query`'s six repeated `resolve-or-notFound` prologues into a `withResolved`
  helper — deferred because it restructures control flow in code with no
  test/oracle coverage.

## Refused

- **`agda-simplify` umbrella executable.** Would fold `fingerprint` + `goals` +
  `simplify` behind one binary with a shared `Canon`. Refused: the three pieces
  canonicalise three different data types (internal `Term`, interaction goals,
  surface AST), so a shared module adds coupling without payoff; and the only
  place with `Agda.Syntax.Internal.Term` in scope is the producer Backend.

## Deferred — producer-gated

- **Load the packed (~5×-smaller) graph form.** The packed `defs` carry only
  `names`/`modules`/`states`/`x`/`y` and omit the per-definition `kind`, source
  `line`, `access`, type signature, and subterm hashes the analyses need (it is
  the HTML-viewer wire form). A consumer-only packed load would silently cripple
  `type_of` / `similar_*` / `find_lemma` / `unused` / `locate`-line /
  `search --kind`. `AgdaGraph.Schema` refuses packed with an actionable error;
  the gap is documented in `test/packed/README.md`. The real fix is a producer
  `packed-complete` mode that keeps the compact encoding *and* the analytical
  fields; the consumer change is then a small base64-LE + CSR decoder validated
  against the expanded form.
