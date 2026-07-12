# Backlog

Deferred and refused ideas on the graph consumers. For shipped work see
[Changelog.md](Changelog.md); for runnable recipes see [Examples.md](Examples.md);
for concrete forward-looking items see [TODO.md](TODO.md); for answered
feature requests see [Deferred.md](Deferred.md).

---

## Deferred — would be useful, no current push

- **`fiedler` — pure-Haskell eigensolver.** `fiedler` is the only
  subcommand that shells out — `scripts/fiedler_helper.py` returns `λ₂` /
  the Fiedler vector via SciPy. A pure-Haskell Lanczos / power-iteration
  solver would drop the Python + SciPy runtime dependency. The shell-out is
  deliberate (SciPy is faster and better-tested, and the
  `pip install scipy numpy` diagnostic keeps the failure clean). Revisit for
  a deployment without Python.

- **`pyre` — drive `agda --profile` end to end.** Calibration shipped
  (`--profile` / `--calibrate` / `--levers`; Changelog). Still deferred:
  (a) an adapter that runs `agda --profile=*` and reduces its text to the
  consumed `{qname: cost}` JSON — `pyre` stays shell-out-free and consumes a
  pre-made profile; (b) a Bayesian fit with uncertainty bands, if the linear
  point-estimate proves too brittle on a real profile.

- **Round-6 S1 — surface-AST simplifier with typecheck rollback.**
  Mechanical local rewrites (`λ x → f x ⇒ f`, `subst P refl x ⇒ x`,
  `cong f refl ⇒ refl`, `sym (sym p) ⇒ p`, …); per-module typecheck after
  each batch with rollback on regression; `.agdai`-checksum invariance for
  unmodified modules. Highest-risk piece — the only one where a tool bug can
  leave the corpus non-typechecking. Defer until `term-cluster` surfaces
  concrete rewrite candidates worth automating. Cross-module rename (inline
  single-callee, singleton `let`) is round 2 only. See [TODO.md](TODO.md).

- **Remaining behavior-preserving cleanups** (from the 2026-07-12 simplification
  pass, [Changelog.md](Changelog.md)). Two low-priority items left undone: fold
  `Query`'s six repeated `resolve-or-notFound` prologues into a `withResolved`
  helper — deferred because it restructures control flow in code with no
  test/oracle coverage — and trim three history-narrating comments (the
  `BuildInfo` war-story, the `LemmaRank` R20 changelog note, and the misplaced
  lazy-cache doc in `State`).

## Refused

- **`agda-simplify` umbrella executable** (round 6). The proposal folded
  `fingerprint` + `goals` + `simplify` behind one binary with a shared
  `Canon`. Refused: the three pieces canonicalise three different data types
  (internal `Term`, interaction goals, surface AST), so sharing a module
  adds coupling without payoff; and the only place with
  `Agda.Syntax.Internal.Term` in scope is the producer Backend, where P3's
  canonicaliser already lives.

## Shipped — see Changelog for detail

- **`term-cluster` — `--sort=log-score` + `--min-mean-depth`.** Both
  ranking refinements landed (behind flags so `score` stays the default).
- **`agda-goals` — goal-state clustering** via `agda --interaction-json`,
  now over a parallel session pool. One follow-up open: the textual → structural
  `TermCanon` upgrade ([TODO.md](TODO.md)).
- **Write-side interaction bridge** (`agda-explore --enable-interact`):
  hole-driving + file-authoring tools over a live `agda --interaction-json`
  session, sharing `AgdaInteract.Session` with `agda-goals`; plus `auto`
  (Mimer), `give_many`, and `stage`/`promote`/`discard`. One piece deferred:
  a per-module session pool — the single-threaded request/response daemon
  caps + reloads instead, so it doesn't need one (`agda-goals` got the pool).
- **Cold-start fallback** — `ssColdError` caches the first-build-failure
  diagnostic; `status` and every tool surface it (not the raw producer exit)
  while the background worker retries, so the daemon self-heals. Still open
  (producer-gated): once `agda-deps` guarantees at least a defs-light graph
  on a broken corpus, treat a *file-exists-but-zero-defs* graph as a valid
  snapshot; and one entry failing to build must not discard the other
  entries' graphs.
- **Agent-usage analysis (2026-06-12)** — all nine recommendations
  implemented: serve-stale + async rebuild, fail-fast `type_of`, multi-entry
  `entries:` union, unique-candidate auto-resolution, `find_lemma`, query
  telemetry; `agda-unused` never-silently-zero + inliner-gap tagging +
  aggregation output.
- **Write-bridge adoption push (2026-07-05)** — the follow-up round after
  transcript analysis (VerinaAgda + Jolteon) showed the write bridge went
  unused: `check` next-step footer + speculative Mimer hints, `auto_all`
  (Mimer over every goal in one call), plugin loop-closing hooks
  (validate-on-edit + route-first-grep), the `--control-port` endpoint the
  edit hook calls, and a tool-usage histogram in `status` for passive
  adoption measurement. Still open (the higher-cost items from the same
  analysis): stdlib graph federation ([TODO.md](TODO.md)) and orientation
  bundles (`brief` / `goal_brief`).

## Deferred — producer-gated

- **Load the packed (~5×-smaller) graph form.** The packed `defs` carry only
  `names`/`modules`/`states`/`x`/`y` and **omit** the per-definition `kind`,
  source `line`, `access`, type signature, and subterm hashes the analyses
  need (it is the HTML-viewer wire form). A consumer-only packed load would
  silently cripple `type_of` / `similar_*` / `find_lemma` / `unused` /
  `locate`-line / `search --kind`. `AgdaGraph.Schema` refuses packed with an
  actionable error (the missing fields + the fix); the gap is documented in
  `test/packed/README.md` with a committed example pair. The real fix is a
  producer `packed-complete` mode that keeps the compact encoding *and* the
  analytical fields; the consumer change is then a small base64-LE + CSR
  decoder validated against the expanded form.
