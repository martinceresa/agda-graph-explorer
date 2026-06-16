# agda-graph-explorer

Consumers of the dependency graph emitted by
[`agda-deps`](https://github.com/input-output-hk/agda-dependencies) — a
shared library plus four executables that read `agda-deps`' v2
`graph.json` and answer questions over it.

**Nothing here links Agda**, so the whole repo builds from Hackage in minutes.

| Tool                       | What it does                                                                                                                              |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| **`agda-graph`** (library) | Typed view of the expanded `graph.json` + an in-memory `Index`. The substrate the executables share.                                      |
| **`agda-unused`**          | Flags unused imports / definitions / blanket opens / public re-exports.                                                                   |
| **`agda-optimization`**    | ~20 subcommand-driven graph-level analyses (centrality, clustering, motif mining, axiom footprint, …).                                    |
| **`agda-goals`**           | Drives `agda --interaction-json` over a pool of persistent processes and buckets goal states by canonical hash. Needs `agda` on `$PATH`. |
| **`agda-explore`**         | Interactive MCP server: a daemon that answers point queries over the graph for coding agents, regenerating it on the fly via `agda-deps`. |

The single coupling to `agda-deps` is the **v2 `graph.json` wire
schema** — `agda-deps` produces it, this repo consumes it. See
[The wire contract](#the-wire-contract).

For runnable recipes (one per subcommand, with empirical defaults
explained) see [Examples.md](Examples.md).
For forward-looking work see [TODO.md](TODO.md);
for deferred / refused ideas see [Backlog.md](Backlog.md) and [Deferred.md](Deferred.md);
for shipped work see [Changelog.md](Changelog.md).

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

Honours `--kinds`, `--rel-to`, `--exclude`. Config:
[`.agda-unused.yml`](#agda-unusedyml).

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
output. Config: [`.agda-optimization.yml`](#agda-optimizationyml)
(`global:` + one kebab-case section per subcommand).

`fiedler` is the only subcommand that shells out — to
`scripts/fiedler_helper.py` (needs SciPy). Helper path:
`--helper=PATH` > `$AGDA_OPTIMIZATION_HELPER` > the bundled data-file.

**Parallelism.** `agda-unused` and `agda-optimization` are multicore
(`-with-rtsopts=-N`); output is byte-identical between `+RTS -N1` and
`+RTS -NK`.

## `agda-goals` — bucket goal states

Drives `agda --interaction-json` over the root files via a **pool of
persistent** Agda processes (the same session driver `agda-explore`'s
interaction bridge uses; one process per RTS capability — run `+RTS -NK`
to cap the pool, e.g. to bound memory on a heavy corpus), canonicalises
each open goal type, and buckets by hash to surface recurring missing
lemmas. Output is reassembled in input order, so it is byte-identical
between `+RTS -N1` and `-NK`. Needs `agda` on `$PATH`. Config:
[`.agda-goals.yml`](#agda-goalsyml).
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

Config: [`.agda-explore.yml`](#agda-exploreyml).

**Write-side interaction bridge (opt-in).** With `--enable-interact`
(or `enable-interact: true` in the config) and `agda` on `$PATH`, the
daemon *also* exposes Agda-validated **authoring + editing** tools backed
by a live `agda --interaction-json` session — the write counterpart to the
read queries above, and the validated alternative to a blind `Write` +
`agda File`:

```
load · check · goal_type · goal_context · infer · normalize · lemmas ·
new_module · give_file · case_split · refine · give · give_many ·
construct · auto · stage · promote · discard
```

*Authoring.* `new_module` scaffolds a fresh module — a `module … where`
header matching the path, literate fences for a `.lagda.md` path, imports
**resolved off the dependency graph** from the bare names you list, and a
`name : T` / `name = ?` hole per stub — and type-checks it. `give_file`
validates whole-file `content` (or an `append` block) under the zero-axiom
contract and returns a diff — the validated counterpart to `Write`, for code
that must honour `--safe` / 0-postulate. After editing a file as text,
`check` type-checks it over the warm session and returns a ✓/✗ verdict with
**every** error and warning plus the remaining open goals — `agda File`, but
reusing the session and handing the goals back so you pivot straight to
filling them.

*Driving holes.* `load` opens a module and lists its goals as `g0, g1, …`
with source positions; the mutators (`case_split` / `refine` / `give` /
`auto`) are **Agda-validated** and by default return a **unified diff
without writing**. Pass **`write:true`** and the bridge applies the edit,
reloads, and returns the diff *plus the refreshed goals* in one round-trip
(otherwise an id only stays put while a hole's position is unchanged, so
re-`load` after applying a diff). `give_many` fills several independent holes
in one load (one atomic diff); `construct` runs a planned heterogeneous batch
(`give`/`refine`/`case_split`/`auto`) against one warm load; `lemmas` searches
the project for a definition whose conclusion matches a live goal's type, to
reuse instead of re-deriving. A term that doesn't typecheck comes back as the
localized Agda error with the file untouched, and any input using
`postulate`, a termination/coverage/unsafe-`OPTIONS` pragma, or another
escape hatch is refused up front (a hard zero-axiom contract, enforced over
whole-file content too). `.lagda.md` literate sources are handled (edits land
inside the code fence).

`stage` / `promote` / `discard` build a *new* definition in isolation:
`stage` opens an ephemeral scratch module under `.agda-explore/scratch/`
(seeded with a target's imports, so `load` re-checks only the scratch's
tiny closure instead of the target's whole module); construct the def
there with the usual tools, then `promote` splices it into the real
target — merging missing imports and re-validating the **whole target**
in Agda, returning a diff on success or the localized error with nothing
changed — or `discard` to abandon it. For most new definitions `give_file`
/ `new_module` are more direct.

**Live web inspector (opt-in).** With `--inspect` (or `inspect: true` in
the config) the daemon serves a self-contained localhost web page — a
live **activity feed** of every tool call (collapsed to one line, click
to expand its args + result) plus an **editing view** (the loaded module
with each proposed diff highlighted over the on-disk file) — over
Server-Sent Events at `http://127.0.0.1:7000`. It is a read-only *side
channel* for watching what an agent is doing: off by default,
localhost-only, no auth, and it never touches the JSON-RPC stdout.
`--inspect-port N` sets the start port (implies `--inspect`); on a clash
the daemon probes upward so several projects coexist, and the page header
names the project + bound port so you can tell tabs apart.

```sh
agda-explore --project /path/to/agda/project --inspect      # → http://127.0.0.1:7000
```

## Configuration (YAML)

Each tool reads an optional YAML config. **Every key is a kebab-case
mirror of a CLI flag** (`--json-out` ↔ `json-out`; the `no-*` keys
mirror the negative flags). Merge order is **defaults → config → CLI**
— the command line always wins. A bad value type (and, for
`agda-optimization`, an unknown key) fails fast with an error naming the
file / section / key, and exits 1. A stderr breadcrumb
(`<binary>: applied config from /abs/path/…`) fires when a config is
applied, suppressed by `--quiet` (where present), `agda-unused`'s
`--json-out`, and `agda-optimization`'s `--json`.

Discovery is identical for all four binaries — first match wins:

1. `--config=PATH`
2. `$AGDA_<TOOL>_CONFIG` — one of `AGDA_UNUSED_CONFIG`,
   `AGDA_OPTIMIZATION_CONFIG`, `AGDA_GOALS_CONFIG`, `AGDA_EXPLORE_CONFIG`
3. `./.agda-<tool>.yml` (or `.yaml`) in the current directory
4. walking up from the cwd to the first ancestor containing a
   `*.agda-lib`, and the dotfile there

An empty file (`{}`) is valid; every key is optional and an omission
leaves the default in place.

### `.agda-unused.yml`

| Key        | CLI flag           | Meaning                                                    |
|------------|--------------------|------------------------------------------------------------|
| `json`     | `--json`           | Path to the expanded `graph.json`.                         |
| `rel-to`   | `--rel-to`         | Base directory findings are reported relative to.          |
| `json-out` | `--json-out`       | Emit findings as a JSON array (bool).                      |
| `kinds`    | `--kinds`          | Which finding kinds to report (YAML list or comma-string). |
| `roots`    | positional `ROOTS` | Source roots to scan (YAML list).                          |
| `exclude`  | `--exclude`        | Globs whose matching findings are dropped.                 |

`json:` + `roots:` supply what were the required CLI inputs, so
`agda-unused` can run with no arguments.

```yaml
json: out/deps.json
rel-to: src/
json-out: true
kinds: [using, blanket, duplicate]   # or the string "using,blanket"
roots: [src/, lib/]
exclude: ["**/Init.agda"]
```

### `.agda-optimization.yml`

A top-level `global:` section plus one section per subcommand, named in
**kebab-case** (`load-bearing`, not `loadBearing`). All optional; missing
keys fall through to defaults. Within a subcommand section the keys are
that subcommand's `--help` flags without the `--` (e.g. `--min-support`
↔ `min-support`); run `agda-optimization <subcommand> --help` for the
authoritative list.

`global:` keys: `json` (bool) and `out` (output path).

```yaml
global:
  json: false
  out: out/opt-reports
motif:        { max-size: 3, min-support: 10, budget: 300, min-label-distinct: 2 }
basket:       { budget: 600, min-support: 0.05, forced-suppress: true, forced-fraction: 0.5 }
fingerprint:  { direction: incoming, wl-depth: 2, jaccard: 0.8, top-n: 50 }
term-cluster:
  min-cluster: 3
  span-modules: 3
  min-diversity: 0.7
  exclude-module-regex: '^(Data|Function|Relation|Algebra|Agda)\.'
  top-n: 50
```

### `.agda-goals.yml`

| Key             | CLI flag     | Meaning                                         |
|-----------------|--------------|-------------------------------------------------|
| `agda-bin`      | `--agda-bin` | Path to the `agda` binary to drive.             |
| `include-paths` | `-i`         | Include paths passed to `agda` (YAML list).     |
| `agda-args`     | —            | Extra raw args forwarded to `agda` (YAML list). |
| `format`        | `--format`   | `human` or `json`.                              |
| `quiet`         | `--quiet`    | Suppress the config breadcrumb (bool).          |
| `top-n`         | `--top-n`    | How many buckets to report.                     |
| `roots`         | positional   | Files / directories to drive (YAML list).       |

```yaml
agda-bin: agda
include-paths: [src/, .]
format: json
top-n: 20
roots: [src/]
```

### `.agda-explore.yml`

Mirrors the daemon's CLI flags. Path keys: `entry` (a single Agda entry
module), `entries` (a *list* of entry modules — see below), `include`
(include paths, list), `graph` (a prebuilt `graph.json` for preloaded
mode), `project`, `out-dir`, `agda-deps-bin`, `agda-unused-bin`.
Behaviour toggles (bools): `no-term-hashes`, `no-signatures`,
`normalise-signatures`, `show-implicit`, `no-auto-rebuild`, `no-watch`,
`enable-interact` (expose the write-side interaction bridge), `inspect`
(serve the localhost web inspector); plus `min-term-depth` (int),
`inspect-port` (the inspector's start port, default 7000; setting it
implies `inspect`), `agda-bin` (the `agda` binary for interaction
sessions, else `$AGDA_BIN` / `$PATH`), and `agda-arg` (a list of extra
flags for `agda --interaction-json`, e.g. `--safe`).

**Multiple entry modules.** `--entry` is repeatable on the CLI and the
config accepts an `entries:` list alongside the back-compat scalar
`entry:` (the two are unioned, deduplicated). When more than one entry
is configured the daemon builds **one graph over the union of all the
listed entries' import closures** (it runs `agda-deps` once per entry
and unions the results in-process), so `locate` / `callers` / `type_of`
/ `search` etc. resolve names anywhere across the combined closures. A
single entry is unchanged (one `agda-deps` run). CLI `--entry` *appends*
to any config `entry:` / `entries:`, mirroring how `-i` appends to
config includes.

```yaml
project: .
entry: src/Everything.agda          # back-compat single entry
entries:                            # …and/or a list (unioned with `entry`)
  - src/Main.agda
  - src/Extras/All.agda
include: [src/]
agda-deps-bin: /usr/local/bin/agda-deps   # else found on $PATH
no-watch: false
min-term-depth: 0
inspect: true                       # localhost web inspector
inspect-port: 7010                  # …on this port (else probes up from 7000)
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
Everthing that works is thanks to AI, whatever does not, it is my fault.
