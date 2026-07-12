# TODO

Forward-looking work on the graph consumers. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md) and [Deferred.md](Deferred.md); for shipped work see
[Changelog.md](Changelog.md).

---

## Ideas

- [ ] Shrink the interact schema footprint — check the most-used tools, shrink
      or remove unused ones.

## Open

- [ ] **Arena CI regression gate** (G1–G4: find_lemma 10/10, misleading-* ties,
  live lemmas/auto). Friction: our CI is deliberately Agda-free; the gate needs
  agda 2.9 + agda-deps + registered agda-stdlib 2.4 + an in-CI stdlib graph.
  Budget as a new Agda-in-CI job (offline G1+G2 via cached graphs first, live
  G3+G4 second).

- [ ] **VerinaAgda benchmark** — re-run the A/B with the sig graph + availability
  hint (I1/I2 retrieval + hint fixes and the ergonomics tags landed) and record
  per-rung uptake-when-stuck.

- [ ] **Stdlib federation follow-ups** (base landed 2026-07-05: `--overlay-graph`
  + `scripts/build-stdlib-graph.sh`). Remaining: auto-build + auto-register a
  stdlib overlay on first run; and a producer flag keeping cross-boundary
  external edges as dangling refs (would let `callers`/`impact` cross into the
  overlay — belongs in `agda-deps`).

- [ ] **File-level option escapes** (second half): surface
  `--no-positivity-check` / `--type-in-type` / `--no-termination-check` once
  `agda-deps` Phase 2 emits `moduleOptionEscapes`. The per-def `unsafe` half and
  its transitive taint already ship.

- [ ] **Structural goal canonicalisation.** `agda-goals` canonicalises goal
  types textually (`--interaction-json` exposes only rendered strings). Reusing
  the producer's `TermCanon` needs one of: (1) a Backend-hook variant reading the
  goal-type `Term` off `lookupMetaInstantiation` and emitting a JSON sidecar
  (trades away process-driver simplicity); (2) a surface-AST parser via
  `Agda.Syntax.Parser` (implicit-arg / instance-resolution mismatch makes it
  non-trivial). Both are in `AgdaGoals.Canon`'s haddock.

- [ ] **Surface-AST simplifier with typecheck rollback.** Mechanical local
  rewrites with per-module typecheck + rollback and `.agdai`-checksum
  invariance. Highest-risk piece. Defer until `term-cluster` surfaces concrete
  rewrite candidates. See [Backlog.md](Backlog.md).
