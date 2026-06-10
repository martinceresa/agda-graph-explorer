# agda-graph-explorer

Consumers of the dependency graph emitted by
[`agda-deps`](https://github.com/input-output-hk/agda-dependencies) — a
shared library plus four executables that read `agda-deps`' v2
`graph.json` and answer questions over it.

**Nothing here links Agda**, so the whole repo builds from Hackage in minutes.

| Tool | What it does |
|------|--------------|
| **`agda-graph`** (library) | Typed view of the expanded `graph.json` + an in-memory `Index`. The substrate the executables share. |
| **`agda-unused`** | Flags unused imports / definitions / blanket opens / public re-exports. |
| **`agda-optimization`** | ~20 subcommand-driven graph-level analyses (centrality, clustering, motif mining, axiom footprint, …). |
| **`agda-goals`** | Drives `agda --interaction-json` per file and buckets goal states by canonical hash. Needs `agda` on `$PATH`. |
| **`agda-explore`** | Interactive MCP server: a daemon that answers point queries over the graph for coding agents, regenerating it on the fly via `agda-deps`. |

The single coupling to `agda-deps` is the **v2 `graph.json` wire
schema** — `agda-deps` produces it, this repo consumes it. See
[The wire contract](#the-wire-contract).

## Prerequisites

- GHC 9.14.x + cabal 3.16 (older GHC ≥ 9.6 should work; CI pins 9.14.1).
- For `agda-optimization`'s `fiedler` subcommand only:
  `pip install scipy numpy`.
- For `agda-goals` and for `agda-explore`'s live graph regeneration:
  the `agda` and `agda-deps` binaries on `$PATH` (see
  [Cross-repo runtime link](#cross-repo-runtime-link)).

## Build

```sh
cabal build
```

This resolves entirely from Hackage — there is no Agda
`source-repository-package` pin (that lives in the `agda-deps` repo).

## Producing the input graph

Every tool consumes the **expanded** v2 JSON. Produce it with `agda-deps`:

```sh
agda-deps --format=json --json-mode=expanded -i src/ -o out/ src/Everything.agda
# → out/deps.json
```

Two committed fixtures let you try the tools without `agda-deps`:
`test/deps.json` and `.agda-explore/deps.json`.

## `agda-unused` — flag unused imports

```sh
agda-unused --json=out/deps.json ROOT…          # human-readable
agda-unused --json=out/deps.json --json-out .    # JSON array
```

Honours `--kinds`, `--rel-to`, `--exclude`. Config: `.agda-unused.yml`.

## `agda-optimization` — graph-level refactor candidates

```sh
agda-optimization <subcommand> out/deps.json [options…]
agda-optimization --help                 # list subcommands
agda-optimization <subcommand> --help    # subcommand flags
```

Subcommands: `motif`, `load-bearing`, `polyglot`, `fingerprint`,
`debt`, `basket`, `ledger`, `echo`, `gravity`, `pyre`, `chokepoint`,
`silhouette`, `entwine`, `fiedler`, `horizon`, `strata`,
`term-cluster`, `concept-bundle`. `--json` emits machine-readable
output. Config: `.agda-optimization.yml` (`global:` + one kebab-case
section per subcommand).

`fiedler` is the only subcommand that shells out — to
`scripts/fiedler_helper.py` (needs SciPy). Helper path:
`--helper=PATH` > `$AGDA_OPTIMIZATION_HELPER` > the bundled data-file.

**Determinism.** `agda-unused` and `agda-optimization` are multicore
(`-with-rtsopts=-N`); output is byte-identical between `+RTS -N1` and
`+RTS -NK`.

## `agda-goals` — bucket goal states

Drives `agda --interaction-json` per file (subprocess), canonicalises
each open goal type, and buckets by hash to surface recurring missing
lemmas. Needs `agda` on `$PATH`. Config: `.agda-goals.yml`.
(Experimental; not yet a polished end-user surface.)

## `agda-explore` — interactive MCP server for agents

A long-running stdio MCP daemon that loads the expanded `graph.json`
once and answers point queries — the questions an agent would otherwise
approximate with `grep`:

```
locate · callers · callees · impact · path · roots ·
type_of · similar_types · similar_bodies · search · unused
```

It regenerates the graph on the fly: when sources change it re-runs
`agda-deps` as a subprocess (reusing Agda's `.agdai` cache) and
hot-swaps the in-memory `Index`. A Claude Code plugin under
[`plugin/`](plugin/README.md) bundles the server with a skill and two
Agda agents.

```sh
agda-explore --version
agda-explore --project /path/to/agda/project    # stdio MCP server
```

## Cross-repo runtime link

- **`agda-explore` → `agda-deps`.** Resolution precedence:
  `--agda-deps-bin` > `$AGDA_DEPS_BIN` > `$PATH`. Put `agda-deps` on
  your `$PATH` (or pin it). Preloaded mode (point the daemon at an
  existing `graph.json`) needs no `agda-deps` at all.
- **`agda-goals` → `agda`.** Needs `agda` on `$PATH`.

## The wire contract

`agda-deps` is the producer and canonical source of truth for the v2
`graph.json` schema; `AgdaGraph.Schema` here is the consumer mirror.

- Payloads start with `"v": 2`; expanded form also has
  `"schemaVersion": 2`, `"mode": "expanded"`.
- `nodeKeyVersion` tracks the node-naming convention (orthogonal to the
  schema version). `agda-explore` rebuilds/warns on a mismatch against
  `AgdaMcp.State.currentNodeKeyVersion` — **keep that constant in
  lock-step with `agda-deps`' `AgdaDeps.Deps.nodeKeyVersion`** across
  the two repos.
- Expanded JSON carries optional `definitionEdgesProvenance`
  (`signature | body | where | with | unknown`) and, under the
  producer's `--with-signatures`, an optional per-definition `"type"`.

A machine-readable JSON Schema (draft 2020-12) for the expanded form
lives in the producer repo at `schema/graph-v2-expanded.schema.json`;
validate any `deps.json` (including the fixtures here) against it with
`pipx run check-jsonschema --schemafile <path>/graph-v2-expanded.schema.json test/deps.json`.
For the full schema prose (including the `packed` form and the `--lazy`
split-file layout used only by `agda-deps`' HTML views), see the
`agda-deps` repo.

## Relevant links

- Producer / Agda backend: <https://github.com/input-output-hk/agda-dependencies>

## AI Disclaimer

Substantial portions of this codebase were developed with AI assistance.
