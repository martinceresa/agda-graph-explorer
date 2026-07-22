# agda-graph-explorer

Consumers of the dependency graph emitted by
[`agda-deps`](https://github.com/input-output-hk/agda-dependencies) — a shared
library plus five executables that read `agda-deps`' v2 `graph.json` and answer
questions over it. **Nothing here links Agda**, so the whole repo builds from
Hackage in minutes.

| Tool                       | What it does                                                                                                                              |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| **`agda-graph`** (library) | Typed view of the expanded `graph.json` + an in-memory `Index`. The substrate the executables share.                                      |
| **`agda-unused`**          | Flags unused imports / definitions / blanket opens / public re-exports.                                                                   |
| **`agda-optimization`**    | 19 subcommands: 18 graph-level analyses (centrality, clustering, motif mining, axiom footprint, …) + `hint-bench`, an offline lemma-ranker eval. |
| **`agda-goals`**           | Drives `agda --interaction-json` over a pool of persistent processes and buckets goal states by canonical hash. Needs `agda` on `$PATH`. |
| **`agda-explore`**         | Interactive MCP server: a daemon that answers point queries over the graph for coding agents, regenerating it on the fly via `agda-deps`. |
| **`agda-auto`**            | Batch hole-filler: runs `agda-explore`'s Mimer + graph-hint ladder over every open hole in a file (or a project), prints a diff or applies it, and annotates holes it can't close. Needs `agda` on `$PATH`. |

Runnable recipes: [Examples.md](Examples.md). YAML config:
[Configuration.md](Configuration.md). Wire schema:
[The wire contract](#the-wire-contract). Roadmap / deferred / shipped work:
[TODO.md](TODO.md), [Backlog.md](Backlog.md), [Deferred.md](Deferred.md),
[Changelog.md](Changelog.md).

## Prerequisites

- GHC 9.14.x + cabal 3.16 (older GHC ≥ 9.6 should work; CI pins 9.14.1).
- `agda-optimization`'s `fiedler` subcommand only: `pip install scipy numpy`.
- `agda-goals`, `agda-auto`, `agda-explore --enable-interact`: `agda` on `$PATH`.
- `agda-explore`'s live regeneration: `agda-deps` on `$PATH` (see
  [Cross-repo runtime link](#cross-repo-runtime-link)).

## Build

```sh
cabal build
```

## Producing the input graph

Every tool consumes the **expanded** v2 JSON, produced by `agda-deps`:

```sh
agda-deps --format=json --json-mode=expanded -i src/ -o out/ src/Everything.agda
# → out/deps.json
```

Two committed fixtures let you try the tools without `agda-deps`:
`test/deps.json` and `.agda-explore/deps.json`.

## Running the tools

Essential invocations below; flag-by-flag recipes are in
[Examples.md](Examples.md), YAML config in [Configuration.md](Configuration.md).

### `agda-unused` — flag unused imports / defs / opens

```sh
cabal run agda-unused -- --json=out/deps.json ROOT…           # human-readable
cabal run agda-unused -- --json=out/deps.json --json-out .    # JSON array
```

### `agda-optimization` — graph-level refactor candidates

```sh
cabal run agda-optimization -- --help                        # list subcommands
cabal run agda-optimization -- <subcommand> out/deps.json [options…]
cabal run agda-optimization -- <subcommand> --help           # subcommand flags
```

19 subcommands — 18 graph analyses (`motif`, `load-bearing`, `polyglot`,
`fingerprint`, `debt`, `basket`, `ledger`, `echo`, `gravity`, `pyre`,
`chokepoint`, `silhouette`, `entwine`, `fiedler`, `horizon`, `strata`,
`term-cluster`, `concept-bundle`) plus `hint-bench` (an offline leave-one-out
lemma-ranker eval). `--json` emits machine-readable output. `fiedler` is the
only one that shells out — to `scripts/fiedler_helper.py` (needs SciPy).

`agda-unused` and `agda-optimization` are multicore (`-with-rtsopts=-N`);
output is byte-identical between `+RTS -N1` and `-NK`.

### `agda-goals` — bucket open goal states (needs `agda`)

```sh
cabal run agda-goals -- -i src/ src/                          # human report
cabal run agda-goals -- -i src/ --format=json src/            # JSON
```

Drives `agda --interaction-json` over a pool of persistent processes and buckets
open goal types by canonical hash to surface recurring missing lemmas.
(Experimental.)

### `agda-explore` — interactive MCP server for agents (needs `agda-deps`)

```sh
cabal run agda-explore -- --version
cabal run agda-explore -- --project /path/to/agda/project              # stdio MCP daemon
cabal run agda-explore -- --graph out/deps.json                        # preloaded (no agda-deps)
cabal run agda-explore -- query brief name=X --graph out/deps.json     # one-shot read query
cabal run agda-explore -- --project . --enable-interact                # + write-side bridge (needs agda)
cabal run agda-explore -- --project . --inspect                        # + localhost web inspector
```

A long-running stdio MCP daemon that loads the expanded `graph.json` and answers
point queries — the questions an agent would otherwise approximate with `grep` —
regenerating the graph on the fly via `agda-deps`. `--enable-interact` adds an
Agda-validated write-side bridge (authoring + hole-filling, zero-axiom, diff-only
unless `write:true`); `--inspect` serves a read-only localhost activity page. A
Claude Code plugin under [`plugin/`](plugin/README.md) bundles the server with a
skill, two Agda agents, and two loop-closing hooks. Tool catalogues and full
detail: [Examples.md](Examples.md), [`plugin/`](plugin/README.md).

### `agda-auto` — batch hole-filling (needs `agda`)

```sh
cabal run agda-auto -- File.agda                              # diff + per-hole report
cabal run agda-auto -- --write File.agda                      # apply solutions, annotate the rest
cabal run agda-auto -- --graph out/deps.json src/             # sweep a project (dependency order)
```

Fills every open hole in a file — or a whole project — via the same Mimer +
graph-hint ladder `agda-explore`'s `auto` uses; a diff by default, `--write`
applies it (Agda-validated, zero-axiom). Exit codes: `0` = none open, `1` = holes
remain, `2` = operational error.

## Configuration (YAML)

Each binary reads an optional YAML config; every key is a kebab-case mirror of a
CLI flag, merged **defaults → config → CLI** (the command line always wins).
Discovery, first match wins: `--config=PATH` > `$AGDA_<TOOL>_CONFIG` >
`./.agda-<tool>.yml` > nearest ancestor with a `*.agda-lib`. Bootstrap a
ready-to-edit file with `<binary> --show-defaults`. Full per-tool key reference:
[Configuration.md](Configuration.md).

## Cross-repo runtime link

- **`agda-explore` → `agda-deps`.** Resolution: `--agda-deps-bin` >
  `$AGDA_DEPS_BIN` > `$PATH`. Preloaded mode (an existing `graph.json`) needs no
  `agda-deps`.
- **`agda-goals` / `agda-auto` → `agda`.** Need `agda` on `$PATH` (or, for
  `agda-auto`, `--agda-bin`); neither runs `agda-deps`.

## The wire contract

`agda-deps` is the producer and canonical source of truth for the v2
`graph.json` schema; `AgdaGraph.Schema` here is the consumer mirror.

- Payloads start with `"v": 2`; expanded form also has `"schemaVersion": 2`,
  `"mode": "expanded"`.
- `nodeKeyVersion` tracks the node-naming convention. `agda-explore`
  rebuilds/warns on a mismatch against `AgdaMcp.State.currentNodeKeyVersion` —
  kept in lock-step with `agda-deps`' `AgdaDeps.Deps.nodeKeyVersion` across the
  two repos.
- Expanded JSON carries optional `definitionEdgesProvenance`, a per-definition
  `"type"` (under the producer's `--with-signatures`), and `moduleOptionEscapes`
  (file-level `{-# OPTIONS #-}` soundness escapes).

A machine-readable JSON Schema (draft 2020-12) for the expanded form lives in the
producer repo at `schema/graph-v2-expanded.schema.json`. For the full schema
prose (the `packed` form and `--lazy` layout used only by `agda-deps`' HTML
views), see the `agda-deps` repo.

## Relevant links

- Producer / Agda backend: <https://github.com/input-output-hk/agda-dependencies>

## AI Disclaimer

Substantial portions of this codebase were developed with AI assistance.
Everything that works is thanks to AI; whatever does not is my fault.
