# TODO

Forward-looking work on the graph consumers. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md) and [Deferred.md](Deferred.md); for shipped work see
[Changelog.md](Changelog.md). A consolidated, prioritized fix plan for the
open items below (designs, files, verification gates) is in
[ToFix.md](ToFix.md).

---
## Ideas
- [ ] Reduce MCP tools: group the most used tools so agents know what to call.

## Open

- [ ] **Per-answer staleness signal** (arena R1; relates I6). Enrich
  `staleFooter` (Tools.hs) with graph-mtime vs source-mtime, and extend
  beyond live mode — preloaded snapshots are hardcoded never-stale
  (`ensureFresh`), so a `--graph` behind the working tree answers with full
  confidence.
- [ ] **`search mode=text` ripgrep fallback** (arena R3). When the query
  looks textual (pragmas, comments, regex), shell out to `rg` so the MCP is
  a superset of grep instead of a different-shaped subset. Model on
  `runUnused`'s shell-out (`findBin` + `readCreateProcessWithExitCode`).
- [ ] **Adopt the arena CI regression gate** (arena R8; deliverable in
  `MCPBenchArena/ci/` — workflow + `ci_gate.py` asserting G1–G4:
  find_lemma 10/10, misleading-* ties, live lemmas/auto). Friction: our CI
  is deliberately Agda-free; the gate needs agda 2.9 + agda-deps +
  registered agda-stdlib 2.4 + the arena repo pinned + in-CI stdlib graph
  builds. Budget as a new Agda-in-CI job, not an extra step.
- [ ] **Canonical graph identity hash in `status`** (arena R9). Their recipe
  (`arenalib.graph_config_hash`): sha256[:12] of sorted-JSON {producer
  flags, seed sha, build-date-stripped `producer`, `nodeKeyVersion`,
  `schemaVersion`}. A def-set-covering variant would also make I6's silent
  def drops visible.
- [ ] **Per-answer closure-coverage count beyond `search`** (arena R2
  follow-up; `search` got the compact footer + `unsearched_files` JSON field
  2026-07-09).
- [ ] **Dead mutual-recursion cycles** (I5 open half). SCC pass over the
  intra-module qname edges in `AgdaUnused.Analysis` flagging cycles with no
  external entry (`Data.Graph.stronglyConnComp`; the Index-side `Condense`
  isn't reusable there).

- [ ] Check VerinaAgda benchmark and try to close the gap.
- [ ] Stdlib federation follow-ups (base landed 2026-07-05 — see Changelog:
  `--overlay-graph` / `overlay-graphs:` + `scripts/build-stdlib-graph.sh`).
  Remaining: auto-build + auto-register a stdlib overlay on first run (warm
  compilation), and a producer flag keeping cross-boundary external edges as
  dangling refs (would let `callers`/`impact` cross into the overlay — belongs
  in the `agda-deps` repo).
- [ ] `format: json` for `unused` (deferred): it shells out to `agda-unused`,
  so JSON means threading a stdout-JSON flag through the subprocess, not the
  in-process row split the other list tools got. Low priority.

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
