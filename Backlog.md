# Backlog

Deferred ideas, refused requests, exploratory work on the graph
consumers that isn't ready to be picked up. For shipped work see
[Changelog.md](Changelog.md); for runnable recipes see
[Examples.md](Examples.md); for concrete forward-looking items see
[TODO.md](TODO.md); for answered feature requests see
[Deferred.md](Deferred.md).

---

## Deferred — would be useful, no current push

- **`pyre` — calibration via `agda --profile`** — *shipped
  2026-06-01* (`--profile` / `--calibrate` / `--levers`; Changelog).
  The fit is plain ridge linear-regression over the four graph
  features, and coefficient caching reuses the existing `pyre:` YAML
  section rather than a bespoke store. Two pieces stay deferred:
  (a) *driving* `agda --profile=*` and reducing its textual output
  to the consumed `{qname: cost}` JSON — `pyre` deliberately
  consumes a pre-made profile so it stays pure / shell-out-free, and
  the adapter is left to the caller; (b) a Bayesian fit with
  uncertainty bands, if the linear point-estimate proves too brittle
  on a real profile from the reference corpus.

- **`fiedler` — pure-Haskell eigensolver.** The round-4
  `fiedler` subcommand is the only one in the project that shells
  out to anything external — `scripts/fiedler_helper.py` reads the
  graph over stdin and returns `λ₂` / the Fiedler vector via
  SciPy's sparse eigensolver. A pure-Haskell Lanczos / power-
  iteration implementation would remove the runtime dependency on
  Python + SciPy. The shell-out is a deliberate first cut —
  SciPy is faster, better-tested, and the
  `scipy not found: pip install scipy numpy` diagnostic-on-missing
  path keeps the failure mode clean. Worth revisiting when someone
  hits a deployment where Python isn't available.

- **`term-cluster` — `log(size)` ranking + per-cluster mean-depth
  floor.** Round-6 P3 surfaced the proposal's target cluster at
  rank 572 / 1104 on the reference corpus pre-Wave-2A snapshot — ~500
  bigger genuinely cross-cutting patterns rank ahead. To reach
  the "top 10" retroactive acceptance gate two refinements are
  worth trying:
  - **`--sort=log-score`** — replace size in the composite with
    `log(1+size)`, so a cluster's score is
    `log(1+size) × meanDepth × (1 + diversity)`. Dampens the
    size-by-orders-of-magnitude dominance that lets the 5,069-
    occurrence top-ranked cluster outscore the 15-occurrence
    proposal target even when the latter is the deeper / more
    diverse one. Behind a new flag so the current `score`
    formula stays the documented default.
  - **`--min-mean-depth=F`** — depth floor at the cluster level,
    independent of the producer-side `--min-term-depth=N`. The
    producer's filter applies to /individual subterms/; a
    cluster floor lets the user say "I only want clusters whose
    /average/ occurrence is deep" without globally dropping all
    shallow subterms. Useful when the same canonicalised shape
    appears at both shallow and deep nesting and the shallow
    instances are what's currently inflating the cluster.
  Spec'd in [TODO.md](TODO.md); deferred until someone is using
  `term-cluster` in anger on a corpus where the current ranking
  surfaces low-value clusters.

- **Round-6 P5 — goal-state clustering via
  `agda --interaction-json`.** Second piece of the proof-simplification
  proposal this round was scoped against.
  Drive `agda --interaction-json` per module, capture every
  `Cmd_goal_type_context` reply at every `?`-hole, canonicalise
  goal types via the producer's `TermCanon` machinery, bucket
  by hash. The biggest bucket /is/ the missing intermediate
  combinator — its centroid is the lemma's type signature.

  Architecturally distinct from P3 — a process driver, not a
  Backend hook — so this needs a separate executable
  (`agda-goals` working name). Three collection modes from the
  proposal:
    1. `interaction-json` (preferred): drive `agda --interaction-json`
       per module.
    2. `verbosity`: re-typecheck with `-vtc.constr:50 -vtc.meta:30`
       and parse the log.
    3. `temporary-holes`: syntactically inject `? : _` into
       binders, re-typecheck, revert.
  Risk register from the proposal: `--interaction-json`'s
  protocol stability isn't officially versioned; snapshot a
  fixture set + CI on the snapshot.

  Estimated 2-3 days. Revisit once P3's output is producing
  concrete combinator-extraction wins on a real corpus.

- **Round-6 S1 — surface-AST simplifier with typecheck
  rollback.** Third piece of the proposal. Mechanical
  source-level rewrites:
    1. Eta-contract lambdas (`λ x → f x ⇒ f`).
    2. Identity `subst P refl x ⇒ x`.
    3. Identity `cong f refl ⇒ refl`; `cong id eq ⇒ eq`.
    4. (Deferred) Trivial wrappers: inline single-callee `f = g`.
    5. Double `sym`, `trans refl _` collapses.
    6. Redundant `with p | refl`.
    7. Eta-record copy.
    8. (Deferred) Singleton `let x = e in x`.

  Workflow per the proposal: Phase A emits a unified diff; Phase
  B applies per-module, runs `agda <module>`, rolls back on
  regression. Final gate: full project typecheck clean +
  `.agdai`-checksum invariance for unmodified modules +
  idempotency check + clean `agda-unused` run after rules 4/8.

  Highest-risk piece — the only one where a tool bug can leave
  the corpus in a non-typechecking state. Defer until (a) P3's
  `term-cluster` has surfaced concrete CSE candidates worth
  applying, (b) someone has bandwidth for the 3-day safety-
  harness shake-out. Rules 4 and 8 are flagged for round 2 only —
  cross-module rename is its own can of worms.

- **Round-6 `agda-simplify` umbrella executable** (refused for
  round 6, may be revisited). The proposal sketched a single
  binary holding `fingerprint` + `goals` + `simplify` plus a
  shared `Canon` module. We chose against this because (a) the
  proposal's premise that `agda-unused` vendors a `.agdai`
  loader was incorrect — `agda-unused` consumes JSON, not
  interfaces; (b) the only place with `Agda.Syntax.Internal.Term`
  in scope is the `agda-deps` producer Backend itself, so P3's
  canonicalizer naturally lived inside the producer; (c) the three
  pieces' "canonicalizers" actually operate on three different
  data types (internal Term, interaction goals, surface AST) and
  forcing them to share a module added coupling without payoff.
  The original umbrella design came from the proof-simplification
  proposal; the rationale for splitting it is recorded above.
