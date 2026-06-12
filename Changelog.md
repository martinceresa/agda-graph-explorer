# Changelog

## Unreleased

### Agent-usage-analysis recommendations (2026-06-12)

Implemented all nine recommendations mined from a downstream consumer
project's agent-session analysis (the *negative space* — why agents with
the MCP available fell back to grep). See the `agda-deps` repo for
producer-side items.

**`agda-explore` (daemon):**

- **serve-stale + async rebuild.** `ensureFresh` now returns the
  last-good snapshot *immediately* (tagged stale via a `# stale:` text
  footer) and schedules the `agda-deps` rebuild on a single background
  worker, instead of blocking every query — and the whole stdio loop —
  behind a multi-minute subprocess. Only the genuine first build (no
  snapshot to serve) is synchronous. `status` never blocks on a rebuild.
  A failed background rebuild keeps serving stale and retries on a
  bounded backoff.
- **fail-fast `type_of`.** An out-of-snapshot name is reported instantly
  ("not in the graph, reachable from entry …") against the current
  snapshot rather than paying the rebuild barrier.
- **multi-entry roots.** `.agda-explore.yml` accepts an `entries:` list
  (and `--entry` is repeatable); the daemon runs `agda-deps` once per
  entry and **unions the graphs in-process** (`AgdaGraph.Union`, dedup by
  qname, parallel-array-faithful), since the producer compiles only one
  entry's closure per run. Single-entry is byte-identical to before. The
  union is materialised back to the graph file so the shell-out `unused`
  tool sees the same graph.
- **universal unique-candidate auto-resolution.** When the "did you
  mean" set has exactly one candidate, every name-taking tool now
  resolves to it (with an explicit `(auto-resolved …)` note) instead of
  erroring. `--no-auto-resolve` opts out.
- **`find_lemma`** (new tool). Goal-directed lemma search in two modes:
  `anchor=<def>` reuses WL type-fingerprint ranking; `goal=<free text>`
  canonicalises the goal and ranks by conclusion token-overlap. The goal
  canonicaliser moved to the shared library as `AgdaGraph.GoalCanon`
  (one home for the vendored Murmur64).
- **query telemetry.** Each `tools/call` appends one line to
  `<out-dir>/query-log.jsonl` (tool, args, `dur_ms`, `ok`, `stale`); on
  by default in live mode, `--no-query-log` to disable.

**`agda-unused`:**

- **never silently return 0.** Relative `ROOT`s are absolutised so they
  match the graph's absolute `moduleFiles`; if files are scanned but none
  match the graph, it hard-errors (stderr + non-zero exit) instead of
  printing `# total: 0`.
- **inliner-gap confidence.** Dead findings with a trivial single-clause
  body (proxied via subterm-hash arrays) are tagged
  `confidence: low (possibly inlined)`; a trivial-bodied name still used
  textually in another file is suppressed entirely. The MCP `unused`
  caveat no longer tells agents to grep-verify *every* dead finding.
- **aggregation output.** `--group-by=dir|file|kind` and `--count-only`
  (CLI + the MCP `unused` tool), mirroring the `by_module` idiom. Output
  is a total order, so the determinism gate holds.

Determinism acceptance test (`+RTS -N1` vs `-NK` byte-identical on
`test/deps.json`, human and `--json`) verified for `agda-unused` and
`agda-optimization`, including the new `--group-by`/`--count-only` modes.

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
