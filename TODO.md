# TODO

Forward-looking work on the graph consumers. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md) and [Deferred.md](Deferred.md); for shipped work see
[Changelog.md](Changelog.md).

---

## Open

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
