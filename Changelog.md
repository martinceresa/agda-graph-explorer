# Changelog

## Unreleased

### Split out of `agda-deps` (2026-06-10)

`agda-graph-explorer` was factored out of the `agda-deps` repository.
It carries everything that *consumes* the dependency graph, leaving
`agda-deps` as a focused Agda compiler backend (the *producer*):

- the **`agda-graph`** library (typed `graph.json` view + `Index`);
- **`agda-unused`**, **`agda-optimization`**, **`agda-goals`**,
  **`agda-explore`**;
- the **`plugin/`** bundling the `agda-explore` MCP server.

This repo links **no Agda** — `cabal.project` has no
`source-repository-package` pin. `agda-goals`' single Agda dependency
(`Agda.Utils.Hash.hashString`) was vendored as
`AgdaGoals.Canon.hashString = asWord64 . hash64` (`murmur-hash`),
byte-identical to Agda's definition, so goal-bucket hashes are
unchanged.

The pre-split history (all rounds of analysis development, the wire
schema, the gotchas) lives in the `agda-deps` repository's
`Changelog.md`.
