# TODO

Forward-looking work on the graph consumers. For runnable examples see
[Examples.md](Examples.md); for deferred / refused ideas see
[Backlog.md](Backlog.md) and [Deferred.md](Deferred.md); for shipped work see
[Changelog.md](Changelog.md).

---

## Open

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
