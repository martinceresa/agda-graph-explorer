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
  floor.** — *SHIPPED*: both refinements are implemented in
  `AgdaOptimization.TermCluster` — `--sort=log-score`
  (`log(1+size) × meanDepth × (1+diversity)`, behind the flag so `score`
  stays the default) and `--min-mean-depth=N` (a cluster-level depth
  floor) — both with `--help` text, JSON + human output, and the
  determinism contract preserved. The original rationale follows.
  Round-6 P3 surfaced the proposal's target cluster at
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
  `agda --interaction-json`.** — *SHIPPED* as the **`agda-goals`**
  executable: drives `agda --interaction-json` over the root files (now a
  parallel session pool, `+RTS -NK`), captures each `AllGoalsWarnings`
  reply, and buckets goal states by canonical hash
  (`AgdaGoals.Canon` over the vendored Murmur64). The session driver was
  later unified with the write-side bridge (`AgdaInteract.Session`). See
  [Changelog.md](Changelog.md). One follow-up stays open — the
  textual-canonicaliser → structural `TermCanon` upgrade
  (in [TODO.md](TODO.md)); corpus-scaling shipped 2026-06-13. The original
  proposal follows.
  Second piece of the proof-simplification
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
  implementation note below anticipated. `auto` (Mimer), `give_many`
  (batch fill), and a scratch/`promote` staging mode shipped on top
  (2026-06-13; Changelog). One piece stays deferred for the *bridge*: a
  one-Agda-process-per-module *pool* (the bridge caps + reloads rather
  than pooling concurrent sessions — `agda-goals` got the pool, but the
  single-threaded request/response daemon doesn't need one). The original
  proposal, kept for the rationale, follows. `agda-explore` gave
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

- **Scratch / staging buffer + `promote` — a first-class write-bridge
  mode (proposed 2026-06-13).** Direct extension of the shipped
  write-side interaction bridge above. Today, adding a *new* definition
  through the bridge means editing the real target module to drop in a
  signature + `?` hole, then `load` / `give` / `refine` against it — so
  the real file sits half-written for the whole construction, and every
  `load` re-type-checks that module's *full* import closure. A staging
  buffer inverts this: the agent constructs and validates a definition
  in an *ephemeral scratch module*, isolated from real source, and only
  materialises it into a real file with an explicit `promote` once it
  type-checks. Files become **late-bound** — the real module is touched
  exactly once, with a finished, Agda-validated definition.

  This is the achievable form of a "graph-first, file-last" editing
  model (explored in a session note 2026-06-13). The fully-general
  version — edit the dependency graph as if it were the source,
  serialise to a file only when needed, Unison-style — does **not** fit
  Agda: the graph `agda-explore` serves is a *derived, lossy
  read-projection* (the producer emits it *after* elaboration; it does
  not round-trip to surface syntax — layout, comments, `where`-structure
  are gone), and Agda only type-checks *files* — there is no "validate a
  free-floating node" primitive. So the smallest unit Agda can validate
  is a definition-in-a-module, and a scratch module is exactly that: the
  sandbox where construction happens, with the graph used to *plan*
  (which imports, where it belongs, does it already exist) rather than
  to *edit*.

  **Wins**
    - **No broken intermediate state in real modules.** The construction
      churn (hole → case_split → refine → give, often with dead ends)
      happens in the scratch buffer; the real file only ever sees the
      finished definition via `promote`. Abandoning a dead end is a
      `discard`, not a multi-step revert of real source.
    - **Cheap iteration on heavy modules.** A scratch module's import
      closure is tiny, so each `load` / `give` re-check is fast. Today
      the same loop re-type-checks the target's *full* closure every
      step — and recheck is the expensive part on this corpus (the
      bridge's own cost open-question flags Lemma5-class `with`-hotspots).
      The expensive real-module recheck then happens *once*, at `promote`.
    - **Defers placement / scope commitment.** The agent can build and
      validate before deciding which module the definition lives in and
      where in the file — the decision a free-floating "node" was meant
      to defer — made safe by re-validating in the real target at promote
      time.
    - **Matches how an agent works.** Agents reason over text but the
      task is a validated structured artifact; the natural division is
      graph-first *planning* (`find_lemma` to avoid duplication,
      `callees` / `roots` for required imports / axioms, `impact` for
      consequences) + scratch construction + a single `promote` commit.
      It turns the ad-hoc "make a scratch `.agda`, fill it, hand-splice
      it" dance an agent does today into a supported workflow.
    - **Same safety contract, extended.** `promote` returns a unified
      diff and never writes (like every other mutator), re-validates in
      the real target so scope / instance differences are caught, and
      preserves the zero-postulate / no-pragma escape-hatch invariant
      across the move.

  **Proposed surface** (on the `agda-explore` server, beside the existing
  bridge tools)
    - `stage [target=<module>]` → open an ephemeral scratch module (under
      `.agda-explore/scratch/`, gitignored, *outside* the source roots so
      it never enters the graph), optionally seeded with `<target>`'s
      `open import …` preamble so scratch scope approximates the
      destination. Returns a scratch handle.
    - existing `load` / `goal_type` / `goal_context` / `give` / `refine` /
      `case_split` / `infer` / `normalize` operate on the scratch handle
      unchanged (they already take a `file`).
    - `promote <scratch> <target> [--after <anchor> | --before <anchor>]`
      → splice the validated definition(s) into `<target>` at the chosen
      anchor, insert any missing imports (dedup + ordered), map into the
      `.lagda.md` code fence when literate, then `load` the *real* target
      to re-validate and return the unified diff. On a re-validation
      failure (scope / instance / ordering facts the scratch didn't
      capture) report the localized error and leave both files untouched.
    - `discard <scratch>` → drop the buffer.

  **Open questions**
    - Fidelity of scratch scope vs. target: module parameters,
      `private`-scoped opens, and generalizable variables can't always be
      reproduced in a flat scratch module, so some definitions are only
      validatable in-place — detect this and fall back to the existing
      in-file hole workflow rather than promising a clean promote.
    - Scratch lifetime / cleanup: session-scoped temp vs. gitignored
      on disk, and reclaiming abandoned buffers.
    - Multi-definition staging + dependency ordering at promote (a helper
      lemma plus the def that uses it, spliced in the right order, perhaps
      into different modules).
    - Interplay with the per-module session pool (the bridge's other open
      question): scratch sessions are cheap and many; `promote` triggers
      the one heavy real recheck — so promote is the natural batching
      point.

  **Pick up when** the shipped write bridge is under real
  proof-construction load — this is a direct ergonomic multiplier on it,
  most valuable exactly where the bridge is weakest today (heavy-module
  recheck cost) and for autonomous agents (placement deferral + isolated
  churn). Natural follow-on to the bridge; shares its session driver.

- **Cold-start fallback — degrade instead of going dark when the *first*
  build emits no graph (found 2026-06-12).** — *consumer side SHIPPED
  2026-06-13* (commit `a30a575`; see [Changelog.md](Changelog.md)):
  `AgdaMcp.State.ssColdError` caches the first-build-failure diagnostic,
  `status` and every tool surface it (instead of echoing the raw
  `agda-deps exit`), and the background worker keeps retrying so the
  daemon self-heals when the module is fixed — no reconnect. That is
  suggestion #2 below. **Still open:** suggestion #1 — the producer's
  partial-graph fix (always write at least a defs-light graph), after
  which the consumer just needs to treat a *file-exists-but-zero-defs*
  graph as a valid snapshot (`loadLoaded` already decodes one); and the
  multi-entry composition note (#3). Companion to the
  producer-side item in `AgdaDependencies/Backlog.md` ("`--keep-going`
  emits *no* graph on a real broken corpus"). When `agda-deps` emits no
  `deps.json` (e.g. an entry whose closure transitively imports one
  non-type-checking module — a WIP proof, a scratch `TestTrace`), the
  daemon's behaviour splits on whether a snapshot already exists:

    - *Rebuild failure with a prior snapshot* — **already handled well.**
      `rebuildLocked.doBuild` keeps serving the stale snapshot and
      re-dirties for a backoff retry (`AgdaMcp.State`:729–737), so a
      broken edit mid-session never blanks the tools. Good. Leave it.
    - *First build failure (no snapshot yet)* — **the gap.** `doBuild`'s
      `Nothing` branch returns `Left err` (`State.hs`:738); `firstBuild`
      (:692–695) propagates it, `ssLoaded` stays `Nothing`, and *every*
      graph-backed tool then fails with the raw
      `agda-deps produced no graph for … (exit 120)` from `runOne`
      (:561). Serve-stale only protects you *after* one good build, so a
      corpus that is broken from the very first load goes fully dark.
      This was the observed behaviour on the Jolteon-FastBFT corpus: the
      auto-discovered `Main.lagda.md` entry never builds (its closure
      hits `TestTrace.agda:185`), so the daemon had nothing to serve and
      `search` / `locate` / `impact` / … all returned the producer error.

  **Suggested handling (consumer side):**
    1. **Once the producer guarantees a file** (its fix #1: always write
       at least the precomputed module-level graph + `failedModules[]`),
       the consumer change is tiny — `loadLoaded` succeeds on a
       defs-light graph and normal serve-stale takes over. Make sure a
       *file-exists-but-zero-defs* graph is treated as a valid snapshot,
       not as failure.
    2. **Until then, surface an actionable cold-start diagnostic** rather
       than echoing `exit 120` from every tool: have `status` (and a
       one-line tool footer) report "first build failed — module X does
       not type-check; fix it or set `entries:` to a clean module", and
       keep the background worker retrying (the dirty/backoff machinery
       in `watchWorker` already exists) so the daemon **self-heals** when
       the user fixes the module — no reconnect needed.
    3. **Note the multi-entry interaction.** `entries:` (shipped
       2026-06-12, unioned via `AgdaGraph.Union`) is already the manual
       escape hatch — a clean entry can be listed so a broken default
       entry doesn't zero the daemon. Cold-start degradation should
       compose with it: one entry failing to build should not discard the
       graphs the other entries produced.

  **Pick up when:** alongside or just after the producer's partial-graph
  fix — the two together are what make `agda-explore` usable on an
  actively-edited (hence usually-somewhere-broken) proof corpus, its
  primary use case.

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

- **Still deferred — load the packed (~5×-smaller) graph form — but it is
  PRODUCER-GATED (confirmed 2026-06-13).** Investigated: the packed form's
  `defs` carries only `names`/`modules`/`states`/`x`/`y`; it **omits the
  per-definition `kind`, source `line`, `access`, type signature, and
  subterm hashes** the analyses need (it is the HTML-viewer wire form). So
  a consumer-only packed load would silently cripple `type_of` /
  `similar_*` / `find_lemma` / `unused` / `locate`-line / `search --kind` —
  unacceptable. `AgdaGraph.Schema` now refuses packed with an *actionable*
  error (naming the missing fields + the fix) instead of an opaque hard
  fail, and the layout + gap are documented in `test/packed/README.md`
  with a committed example pair (`test/packed/Nat.{packed,expanded}.json`).
  **The real fix is producer-side:** an `agda-deps` `packed-complete` mode
  that keeps the compact CSR+base64 encoding *and* the analytical fields;
  the consumer change is then a small fast decoder (base64-LE + CSR via
  `base64-bytestring` + a `Storable` cast — not a hand-rolled bit loop, to
  stay fast on a 174 MB graph) validated against the expanded form. Specced
  as the producer item "Packed-complete" in `AgdaDependencies/TODO.md`.
