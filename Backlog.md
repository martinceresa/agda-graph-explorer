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

- **Write-side interaction bridge — semantic Agda editing as MCP
  tools (`agda-interact`, working name).** — *SHIPPED 2026-06-12*, built
  directly into the `agda-explore` server under `--enable-interact`
  (tools `load` / `goal_type` / `goal_context` / `infer` / `normalize` /
  `case_split` / `refine` / `give` / `auto`); see
  [Changelog.md](Changelog.md). The session driver
  (`AgdaInteract.Session`) is shared with `agda-goals`, exactly as the
  implementation note below anticipated. Two pieces stay deferred:
  `auto` (Mimer) — Agda 2.9.0's IOTCM reader rejects `Cmd_autoOne`, so
  the tool degrades until the right invocation is pinned; and a
  one-Agda-process-per-module *pool* (the current cap closes idle
  sessions rather than pooling). The original proposal, kept for the
  rationale, follows. `agda-explore` gave
  agents a rich *read* surface (`locate`, `type_of`, `callers`,
  `impact`, `find_lemma`, …); there was no *write* counterpart. AI
  agents editing this corpus fall back to blind exact-string
  replacement plus a full `agda Main` reload to find out whether the
  edit typechecks. That fights Agda's hole-driven design on three
  fronts: (a) the agent reconstructs by hand the goal / case-split /
  refine workflow agda2-mode exists to provide; (b) exact-string
  matching over heavy Unicode + layout-sensitive source is brittle —
  the downstream consumer's session notes record edits that broke on
  generalizable-variable name collisions (`tc` from `Block` shadowing
  a local binding) and operator-overload resolution, exactly the
  scope / type facts a semantic layer settles at edit time; (c) the
  feedback loop is a from-scratch recheck on a corpus whose recheck
  is the expensive part (Lemma5 `with`-abstraction hotspots). It is
  the natural write-side symmetry to the existing read-side tools.

  **Proposed MCP surface** (added to the `agda-explore` server so the
  agent keeps a single endpoint; see the implementation note on where
  the code actually lives):
    - `load <module>` → open goals with ids, source ranges, types.
    - `goal_type <goal>` → normalized goal type (the `type_of` analog
      for an interaction hole rather than a top-level name).
    - `goal_context <goal>` → in-scope binders and their types.
    - `case_split <goal> <var>` → the clauses Agda generates, as a
      diff against the current clause.
    - `refine <goal> <expr>` / `give <goal> <expr>` → Agda elaborates
      the term and returns either the residual subgoals (with ids) or
      a *localized* type error, without touching the rest of the file.
    - `normalize <goal> <expr>`, `infer <goal> <expr>` → the
      `Cmd_compute` / `Cmd_infer` helpers.
    - `auto <goal>` → Mimer / auto result, when available.
  Each mutating op returns a unified diff plus the post-edit goal set,
  so the agent can chain edits without re-reading the file.

  **Requirements**
    - Operations go through `agda --interaction-json`, so every
      `give` / `refine` / `case_split` is *Agda-validated*: a non-
      typechecking term fails locally and the file is never left in a
      broken state. (Contrast S1's source rewriter, which can.)
    - `.lagda.md` support is mandatory — map interaction ranges
      through the literate code-block offsets in both directions.
    - Stable goal identity across incremental reloads within a
      session: Agda renumbers holes on reload, so the bridge must
      keep a session → stable-id map.
    - The bridge must never close a goal by injecting `postulate`,
      `{-# TERMINATING #-}`, or similar — zero-postulate / fixed-axiom
      invariants are a hard contract for the consumer corpus.
    - Snapshot a protocol fixture set + CI on it — `--interaction-json`
      is not officially version-stable (same risk register as P5).

  **Implementation note / synergy with P5.** The stateful process
  driver — spawn `agda --interaction-json`, frame the protocol, track
  per-session goal state — is *the same driver* P5 (`agda-goals`,
  goal-state clustering) needs: P5 *reads* goal types for clustering,
  this *writes* through the same channel. Build the driver once
  (`Agda.Interaction.Session`, working name) and let both the
  clustering executable and these MCP tools sit on top. This also
  resolves the architectural mismatch flagged for the `agda-simplify`
  umbrella: `agda-explore` today loads a *pre-built, static* graph and
  is request/response, whereas an interaction session is a *long-lived
  stateful subprocess*. Expose the tools through the `agda-explore`
  server for endpoint convenience, but keep the session manager in its
  own module so the graph daemon's serve-stale request/response model
  is not contaminated by per-module Agda processes.

  **Open questions**
    - Concurrency: one Agda subprocess per module-session vs. a pool,
      and the interplay with the graph daemon's memory footprint on a
      large corpus.
    - Whether `goal_type` / `goal_context` should reuse `type_of`'s
      normalization and pretty-printing settings for output
      consistency with the read-side tools.
    - Cost: this does not beat the per-check elaboration price, it
      only amortizes it by avoiding full reloads — quantify on a
      Lemma5-class module before committing.

  **Pick up when** there is active *proof-construction* (not
  polish / reporting) load on a consumer corpus — the payoff scales
  with how many holes get filled and shrinks to near-zero on a
  finished proof maintained by string edits to surrounding prose.
  Natural to land alongside or just after P5, since they share the
  driver.

---

## From the consumer-project agent-usage analysis (2026-06-12) — SHIPPED

Source: a downstream consumer project's `docs/MCP/UsageAnalysis.md` — a
mining pass over all 60 Claude-agent session transcripts in that project.
Key context: of 154 MCP calls only ~20 were organic; agents otherwise
fell back to grep/Bash (307 CLI calls). The items below came from that
*negative space* — why agents with the MCP available chose not to use
it. Producer-side items live in `AgdaDependencies/Backlog.md`.

**All nine recommendations were implemented 2026-06-12 — see
[Changelog.md](Changelog.md) for the shipped detail.** Summary:

- `agda-explore`: serve-stale + async background rebuild (the highest-
  value item; `status` never blocks). The packed-graph-form load is the
  one piece left deferred — see below.
- `agda-explore`: fail-fast `type_of` on out-of-snapshot symbols.
- `agda-explore`: multi-entry roots — `entries:` list, unioned
  in-process (the producer compiles one entry's closure per run, so
  the daemon unions per-entry graphs via `AgdaGraph.Union`).
- `agda-explore`: universal unique-candidate auto-resolution across
  every name-taking tool.
- `agda-explore`: `find_lemma` — two modes (anchor=WL fingerprints,
  free-text goal=conclusion token-overlap).
- `agda-explore`: query telemetry (`query-log.jsonl`).
- `agda-unused`: never silently return 0 (absolutise roots; hard-error
  on a scanned-but-unmatched scope).
- `agda-unused`: close the inliner gap (low-confidence tagging of
  trivial-bodied dead findings + source-level suppression).
- `agda-unused`: aggregation output (`--group-by=dir|file|kind`,
  `--count-only`) on the CLI and the MCP tool.

- **Still deferred — `agda-explore`: load the packed (~5×-smaller)
  graph form.** The serve-stale work removed the latency cliff; loading
  the packed form instead of the expanded one is an orthogonal,
  larger schema-decoder change (`AgdaGraph.Schema` currently hard-fails
  any `mode /= "expanded"`). Worth revisiting if graph size itself
  becomes the bottleneck on a large corpus.
