# TODO

Concrete forward-looking work on the graph consumers (`agda-graph`,
`agda-unused`, `agda-optimization`, `agda-goals`, `agda-explore`).

For runnable examples see [Examples.md](Examples.md). For deferred or
refused ideas see [Backlog.md](Backlog.md) and [Deferred.md](Deferred.md).
For shipped work see [Changelog.md](Changelog.md).

---

- [x] **`agda-explore`: producer-side `--with-signatures` for `type_of`.**
  Shipped 2026-06-04. `agda-deps --with-signatures` renders each def's
  type via `prettyTCM` and emits the optional per-def `"type"` field
  (parsed into `Definition.defSig`); `agda-explore`'s `type_of` prefers
  it over the source scrape (daemon default on, `--no-signatures` opts
  out).

- [x] **`agda-explore`: background file-watch.** Shipped 2026-06-09. An
  optional `fsnotify` watcher over the include roots flips a dirty flag and
  a debounce worker rebuilds *between* queries (`AgdaMcp.State.startWatcher`
  / `watchWorker`); a query only reads the flag instead of re-scanning the
  tree. The per-query source-scan poll path remains the portable fallback
  (no watcher / `--no-watch` / watcher init failure).

- [x] **`agda-explore`: `.agda-explore.yml` config.** Shipped 2026-06-09.
  `AgdaMcp.Config` mirrors the producer's discovery (`--config` >
  `$AGDA_EXPLORE_CONFIG` > dotfile > walk-up to `*.agda-lib`); keys are
  kebab-case mirrors of the CLI flags; merge order defaults → config → CLI.

- [x] **`agda-explore`: in-library `similar_*` parity.** Shipped 2026-06-09.
  The WL core moved to `AgdaGraph.WL` and the signature/body + subterm cores
  to `AgdaGraph.Similarity` (both in the `agda-graph` library). `silhouette`
  now consumes that shared core (output byte-identical) and `agda-explore`'s
  `similar_types` ranks by weighted Jaccard of the *same* WL signature
  fingerprints (a 100% hit ≡ a `silhouette` structural twin), while
  `similar_bodies` uses the occurrence-weighted subterm multiset matching
  `term-cluster`.

- [ ] **Round-6 P5 follow-up: structural canonicalisation.** The
  scaffold uses a textual canonicaliser (whitespace + alpha-rename)
  because `--interaction-json` only exposes rendered strings, not
  internal `Term`s. To reuse the producer's `TermCanon` machinery we need
  one of:
    1. A producer Backend-hook variant that reads the goal-type `Term` off
       `lookupMetaInstantiation` inside `TCM` and emits a JSON
       sidecar; `agda-goals` then merges the sidecar with the
       protocol-driver's hole locations. Trades the process-driver
       simplicity that motivated `agda-goals` being separate.
    2. A surface-AST parser via `Agda.Syntax.Parser` on the rendered
       string, then canonicalise on the surface AST. Plausible but
       its own non-trivial design (implicit args / instance
       resolution differ between surface and internal forms).
  Both paths documented in `AgdaGoals.Canon`'s module haddock.

- [ ] **Round-6 P5 follow-up: corpus scaling.** Still single-threaded,
  but as of 2026-06-12 `agda-goals` drives all files over **one
  persistent `agda` process** (`AgdaInteract.Session`, `runDriverBatch`)
  instead of respawning per file — so the `.agdai` cache is reused across
  the corpus. True parallelism (several Agda sessions via
  `Control.Concurrent.Async.mapConcurrently` with a bounded pool,
  mirroring `agda-unused`'s `getNumCapabilities` pattern) is still open;
  the determinism / byte-identical acceptance test must hold under
  `+RTS -NK`.

- [x] **Round-6 P5 follow-up: protocol-skew fixture.** Shipped
  2026-06-12 (with the write-side interaction bridge). Golden
  `--interaction-json` transcripts for `test/interaction/src/Holes.agda`
  + `Lit.lagda.md` live under `test/interaction/<agda-version>/*.jsonl`
  (covering load / goal-type-context / make-case / give / refine / infer
  / compute / error replies, not just `AllGoalsWarnings`); the offline
  `interaction-spec` test-suite replays them through the shared
  `AgdaGraph.Interaction.Protocol` parser, and CI runs it with no `agda`
  binary. Regenerate with `bash test/interaction/regen.sh` after an Agda
  bump; a wire-shape change then shows up as a test failure.

- [ ] **Round-6 S1: surface-AST simplifier with typecheck
  rollback.** The proposal's third piece. Mechanical local rewrites
  (`λ x → f x ⇒ f`, `subst P refl x ⇒ x`, `cong f refl ⇒ refl`,
  `sym (sym p) ⇒ p`, etc.); per-module typecheck after each batch
  with rollback on regression; `.agdai` checksum invariance for
  unmodified modules. Highest risk piece of the proposal — defer
  until P3's `term-cluster` output is being used in anger and
  surfaces concrete rewrite candidates worth automating. See
  [Backlog.md](Backlog.md).
