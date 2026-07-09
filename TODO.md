# TODO

Forward-looking work on the graph consumers. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md) and [Deferred.md](Deferred.md); for shipped work see
[Changelog.md](Changelog.md). A consolidated, prioritized fix plan for the
open items below (designs, files, verification gates) is in
[ToFix.md](ToFix.md).

---
## Ideas
- [x] Reduce MCP tools: group the most used tools so agents know what to call.
  (2026-07-09: category tags `[orient]`/`[find]`/`[trace]`/`[reuse]`/`[audit]`
  on the read tools + `[prove]` and a when-stuck routing note on `check`.
  Full catalogue *reduction* still open, gated on the uptake-when-stuck
  measurement — see the VerinaAgda re-run below.)

## Open

- [ ] **Adopt the arena CI regression gate** (arena R8; deliverable in
  `MCPBenchArena/ci/` — workflow + `ci_gate.py` asserting G1–G4:
  find_lemma 10/10, misleading-* ties, live lemmas/auto). Friction: our CI
  is deliberately Agda-free; the gate needs agda 2.9 + agda-deps +
  registered agda-stdlib 2.4 + the arena repo pinned + in-CI stdlib graph
  builds. Budget as a new Agda-in-CI job, not an extra step. Staging plan in
  [ToFix.md](ToFix.md) §6 (offline G1+G2 first via cached graphs, live
  G3+G4 second).

- [ ] Check VerinaAgda benchmark and try to close the gap. Now unblocked:
  the I1/I2 retrieval + hint fixes landed and the ergonomics tags shipped —
  re-run the A/B with the sig graph + availability hint and record *per-rung*
  uptake-when-stuck (the powered-P1 gap). See [ToFix.md](ToFix.md) §7.
- [ ] Stdlib federation follow-ups (base landed 2026-07-05 — see Changelog:
  `--overlay-graph` / `overlay-graphs:` + `scripts/build-stdlib-graph.sh`).
  Remaining: auto-build + auto-register a stdlib overlay on first run (warm
  compilation), and a producer flag keeping cross-boundary external edges as
  dangling refs (would let `callers`/`impact` cross into the overlay — belongs
  in the `agda-deps` repo). Consumer-side design in [ToFix.md](ToFix.md) §8.
- [ ] **Per-answer closure-coverage beyond the cone tools** (arena R2, final
  slice): `search`/`callers`/`callees`/`impact`/`roots` now carry the count;
  extend to `brief`/`path` if measurement shows it helps.

- [ ] **Transitive soundness taint** (R12 follow-on): `search unsafe=…` now
  flags a def's *direct* escape; layer a reachability query (via the dep
  graph) so `roots`/`impact` can report a theorem tainted by a
  `non-terminating`/`trustme` dependency. Also pending: file-level option
  escapes (`--no-positivity-check`, `--type-in-type`) once agda-deps Phase 2
  emits them as a separate top-level field.

- [ ] **Round-6 P5 follow-up: structural goal canonicalisation.** `agda-goals`
  canonicalises goal types textually (whitespace + alpha-rename) because
  `--interaction-json` only exposes rendered strings, not internal `Term`s. To
  reuse the producer's `TermCanon` we need one of:
    1. A producer Backend-hook variant that reads the goal-type `Term` off
       `lookupMetaInstantiation` in `TCM` and emits a JSON sidecar, merged with
       the driver's hole locations. Trades away the process-driver simplicity
       that motivated `agda-goals` being separate.
    2. A surface-AST parser via `Agda.Syntax.Parser` on the rendered string,
       canonicalising on the surface AST. Non-trivial — implicit args /
       instance resolution differ between surface and internal forms.
  Both paths are documented in `AgdaGoals.Canon`'s haddock.

- [ ] **Round-6 S1: surface-AST simplifier with typecheck rollback.**
  Mechanical local rewrites with per-module typecheck + rollback and
  `.agdai`-checksum invariance. Highest-risk piece. Defer until `term-cluster`
  surfaces concrete rewrite candidates. See [Backlog.md](Backlog.md).

## Shipped — see Changelog

- [x] Producer-follow-ups R12 + R14 (2026-07-09) — now that `agda-deps` emits
  the wire fields: `Schema.Definition.defUnsafe` + a `search unsafe=` audit
  filter and an `[unsafe: …]` tag in `locate`/lists (R12); and
  `Schema.ReExport.rxRenames` + alias resolution — `locate`/`type_of` resolve
  `Host.combine` to its `renaming` origin and `search` surfaces the alias
  (R14). Schema-decode + backward-compat regression tests in `test/Spec.hs`.
- [x] Arena-feedback round 2 (2026-07-09) — the ToFix.md batch: I6 partial-graph
  flagging + R1 source-staleness footer (incl. preloaded mode), R9 graph
  identity hashes in `status`, I5 dead mutual-recursion cycles, R2 coverage
  counts on `callers`/`callees`/`impact`/`roots`, R3 `search mode=text`
  (ripgrep), R7 tool-catalogue tags + when-stuck nudge, `format:json` for
  `unused`. Arena gate G1–G4 re-verified green.
- [x] Arena-feedback quick wins (2026-07-09) — `similar_types` false-100 cap
  (I4), recursive dead code flagged by `unused` (I5 self-recursion half),
  `search` per-answer closure-coverage count, advisor blurbs on
  `type_of`/`locate`/`search`. Arena CI gate G1–G4 re-verified green.
- [x] `agda-explore`: goal→lemma retrieval overhaul + hint-guided `auto`
  (2026-07-08) — `find_lemma`/`lemmas` rank by name + algebraic shape +
  operator-weighted coverage (qualifier-stripped, graph-vocab keep):
  2/10→10/10 on the stdlib micro-bench. `auto`/`auto_all` seed Mimer with the
  top `find_lemma` lemmas on a no-solution (fixes I1/I2).
- [x] `agda-explore`: orientation bundles + federation + JSON + coverage + CLI
  (2026-07-05) — `brief`/`goal_brief` one-call orientation, `--overlay-graph`
  stdlib federation (`[external: …]` tags, project-wins), `format: json` on
  `search`/`callers`/`callees`, closure-coverage warning (`coverage-ignore:`),
  and the one-shot `agda-explore query <tool> key=value…` CLI.
- [x] `agda-explore`: drive agents toward the write bridge (2026-07-05) —
  `check` next-step footer + speculative Mimer hints, new `auto_all` tool,
  plugin loop-closing hooks (validate-on-edit / route-first-grep),
  `--control-port` endpoint for the edit hook, tool-usage histogram in
  `status`.
- [x] Adopt producer `nodeKeyVersion` 3: `module-local` provenance enum
  (legacy `where` kept), `currentNodeKeyVersion` 2→3, helper detection
  re-keyed off the `@<line>` disambiguator (the `._.` marker is gone in v3).
- [x] `agda-explore`: `type_of` from producer-side `--with-signatures`.
- [x] `agda-explore`: background `fsnotify` file-watch with poll fallback.
- [x] `agda-explore`: `.agda-explore.yml` config.
- [x] `agda-explore`: in-library `similar_*` parity (shared `AgdaGraph.WL` /
  `AgdaGraph.Similarity` cores, byte-identical to `silhouette`).
- [x] `agda-goals`: corpus scaling over a persistent session pool
  (byte-identical across `-N1` / `-NK`).
- [x] `agda-goals`: protocol-skew golden fixtures + offline `interaction-spec`
  suite (regenerate with `bash test/interaction/regen.sh`).
