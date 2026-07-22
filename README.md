# agda-graph-explorer

Consumers of the dependency graph emitted by
[`agda-deps`](https://github.com/input-output-hk/agda-dependencies) — a
shared library plus five executables that read `agda-deps`' v2
`graph.json` and answer questions over it.

**Nothing here links Agda**, so the whole repo builds from Hackage in minutes.

| Tool                       | What it does                                                                                                                              |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| **`agda-graph`** (library) | Typed view of the expanded `graph.json` + an in-memory `Index`. The substrate the executables share.                                      |
| **`agda-unused`**          | Flags unused imports / definitions / blanket opens / public re-exports.                                                                   |
| **`agda-optimization`**    | 19 subcommands: 18 graph-level analyses (centrality, clustering, motif mining, axiom footprint, …) + `hint-bench`, an offline lemma-ranker eval.        |
| **`agda-goals`**           | Drives `agda --interaction-json` over a pool of persistent processes and buckets goal states by canonical hash. Needs `agda` on `$PATH`. |
| **`agda-explore`**         | Interactive MCP server: a daemon that answers point queries over the graph for coding agents, regenerating it on the fly via `agda-deps`. |
| **`agda-auto`**            | Batch hole-filler: runs `agda-explore`'s Mimer + graph-hint ladder over every open hole in a file (or a project), prints a diff or applies it, and annotates holes it can't close. Needs `agda` on `$PATH`. |

The single coupling to `agda-deps` is the **v2 `graph.json` wire
schema** — `agda-deps` produces it, this repo consumes it. See
[The wire contract](#the-wire-contract).

Runnable recipes (one per subcommand): [Examples.md](Examples.md).
Forward-looking work: [TODO.md](TODO.md); deferred / refused ideas:
[Backlog.md](Backlog.md), [Deferred.md](Deferred.md); shipped work:
[Changelog.md](Changelog.md).

## Prerequisites

- GHC 9.14.x + cabal 3.16 (older GHC ≥ 9.6 should work; CI pins 9.14.1).
- `agda-optimization`'s `fiedler` subcommand only: `pip install scipy numpy`.
- `agda-goals`, `agda-auto`, and `agda-explore --enable-interact`: `agda` on
  `$PATH`. `agda-explore`'s live regeneration also needs `agda-deps` on `$PATH`
  (see [Cross-repo runtime link](#cross-repo-runtime-link)).

## Build

```sh
cabal build
```

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

Honours `--kinds`, `--rel-to`, `--exclude`, `--group-by`, `--count-only`.
Config: [`.agda-unused.yml`](#agda-unusedyml).

## `agda-optimization` — graph-level refactor candidates

```sh
agda-optimization <subcommand> out/deps.json [options…]
agda-optimization --help                 # list subcommands
agda-optimization <subcommand> --help    # subcommand flags
```

19 subcommands: `motif`, `load-bearing`, `polyglot`, `fingerprint`,
`debt`, `basket`, `ledger`, `echo`, `gravity`, `pyre`, `chokepoint`,
`silhouette`, `entwine`, `fiedler`, `horizon`, `strata`,
`term-cluster`, `concept-bundle` (18 graph analyses) plus `hint-bench`
(an offline leave-one-out eval of the lemma ranker; not a graph analysis).
`--json` emits machine-readable output. Config:
[`.agda-optimization.yml`](#agda-optimizationyml) (`global:` + one
kebab-case section per subcommand).

`fiedler` is the only subcommand that shells out — to
`scripts/fiedler_helper.py` (needs SciPy). Helper path:
`--helper=PATH` > `$AGDA_OPTIMIZATION_HELPER` > the bundled data-file.

**Parallelism.** `agda-unused` and `agda-optimization` are multicore
(`-with-rtsopts=-N`); output is byte-identical between `+RTS -N1` and `-NK`.

## `agda-goals` — bucket goal states

Drives `agda --interaction-json` over the root files via a **pool of
persistent** Agda processes (one per RTS capability; `+RTS -NK` caps the
pool), canonicalises each open goal type, and buckets by hash to surface
recurring missing lemmas. Output is reassembled in input order, so it is
byte-identical between `+RTS -N1` and `-NK`. Needs `agda` on `$PATH`.
Config: [`.agda-goals.yml`](#agda-goalsyml). (Experimental.)

## `agda-explore` — interactive MCP server for agents

A long-running stdio MCP daemon that loads the expanded `graph.json`
once and answers point queries — the questions an agent would otherwise
approximate with `grep`. Read-side catalogue (15 tools):

```
brief · locate · callers · callees · impact · path · roots · type_of ·
similar_types · similar_bodies · find_lemma · search · unused ·
rebuild · status
```

When sources change it re-runs `agda-deps` as a subprocess (reusing
Agda's `.agdai` cache) and hot-swaps the in-memory `Index`.
`--require-well-typed` keeps serving the last well-typed graph while a
type error stands; `--strict-producer` unlocks `agda-deps`' faster
`--incremental` cache. A Claude Code plugin under
[`plugin/`](plugin/README.md) bundles the server with a skill, two Agda
agents, and two loop-closing hooks (validate Agda edits through the warm
bridge; route the first structural grep to the graph tools).

```sh
agda-explore --version
agda-explore --project /path/to/agda/project    # stdio MCP server
```

Config: [`.agda-explore.yml`](#agda-exploreyml).

**Write-side interaction bridge (opt-in).** With `--enable-interact` and
`agda` on `$PATH`, the daemon also exposes Agda-validated authoring +
editing tools backed by a live `agda --interaction-json` session — the
validated alternative to a blind `Write` + `agda File`. 11 tools:

```
load · goal_brief · inspect · auto · construct · scratch · check ·
give_file · new_module · lemmas · repair
```

Three are batchers:
`inspect` reads an open goal (`op` = type / context / infer / normalize),
`construct` drives holes with a sequence of `{op, goal, …}` steps
(`give` / `refine` / `case_split` / `auto`; a lone `{op:auto, goal:"*"}`
runs Mimer over every open goal, with an optional `annotate:true` to leave a
marker in each hole it can't close), and `scratch` (`op` = open / promote /
discard) manages an isolated scratch module.

Every mutator (`construct` / `auto` / `scratch` / `give_file` / `new_module`
/ `repair`) is Agda-validated and by default returns a unified diff (or, for
the whole-file authors, the proposed content) **without writing**; pass
`write:true` to apply, reload, and return the refreshed goals in one
round-trip. A hard zero-axiom contract refuses any
`postulate`, termination/coverage/unsafe-`OPTIONS` pragma, or escape
hatch up front. `.lagda.md` literate sources are handled. `auto` (and
`construct`'s `auto` steps) run Mimer, seeded with the top `find_lemma`
lemmas so one-lemma goals close; `check` probes remaining goals with Mimer
inline (`--no-auto-hints` to disable). `repair` drives an almost-correct
file to typecheck — adding missing imports and fixing misspelled
references, spec-preserving and zero-axiom. Full detail:
[`plugin/`](plugin/README.md).

```sh
agda-explore --project /path/to/agda/project --enable-interact
```

**Live web inspector (opt-in).** With `--inspect` the daemon serves a
self-contained localhost page over Server-Sent Events at
`http://127.0.0.1:7000`: a live activity feed of every tool call plus an
editing view of the loaded module with each proposed diff highlighted.
Read-only side channel, off by default, localhost-only, never touches
JSON-RPC stdout. `--inspect-port N` sets the start port (implies
`--inspect`); on a clash the daemon probes upward.

```sh
agda-explore --project /path/to/agda/project --inspect      # → http://127.0.0.1:7000
```

**Loop-closing hooks + control endpoint (opt-in).** The plugin ships two
Claude Code hooks: after any text edit to an Agda file, validate it
through the warm bridge (or nudge to); on the first structural `grep`,
route to the graph tools instead. To let the edit hook run the *real*
warm `check` from outside the MCP transport, start the daemon with
`--control-port N` (needs `--enable-interact`) — it serves
`GET /check?file=…` on localhost and writes the bound port to
`<out-dir>/control-port` for discovery. `status` also reports a per-run
tool-usage histogram, so which tools agents actually reach for is visible
without parsing transcripts. Full detail: [`plugin/`](plugin/README.md).

## `agda-auto` — batch hole-filling

Fills every open hole in a file — or a whole project — from the terminal,
running the same Mimer + graph-hint ladder `agda-explore`'s `auto` uses. Prints
a unified diff by default; `--write` applies it (Agda-validated, under the
zero-axiom contract). Holes it can't close get a strippable, idempotent marker
comment recording the goal type and the lemmas to try. Needs `agda` on `$PATH`
(or `--agda-bin`); a graph (`--graph`, else a discovered `./deps.json` /
`./.agda-explore/deps.json`) supplies lemma hints — without one it runs plain
Mimer.

```sh
agda-auto File.agda                      # diff + per-hole report
agda-auto --write File.agda              # apply solutions, annotate the rest
agda-auto --graph out/deps.json src/     # sweep a project (dependency order)
agda-auto --json File.agda | jq          # structured report
```

Exit codes: `0` = no hole left open, `1` = holes remain, `2` = operational
error. A directory (or more than one file) is **project mode** — swept serially
in dependency order (imports first, so a filled import is visible to its
dependents under `--write`; a holey module can't be imported until it is
filled) with an aggregate footer. Other flags: `--timeout N` / `--hints K`
(per-goal Mimer budget / graph-hint count), `--no-annotate`, `--repair` (add
missing imports before probing), `--fixpoint` (with `--write`, re-sweep until a
pass fills nothing new), `--ledger FILE` (one JSON line per goal), `--wall-budget N`.
Config: [`.agda-auto.yml`](#agda-autoyml).

## Configuration (YAML)

Each tool reads an optional YAML config. **Every key is a kebab-case
mirror of a CLI flag** (`--json-out` ↔ `json-out`; `no-*` keys mirror
the negative flags). Merge order is **defaults → config → CLI** — the
command line always wins. A bad value type (and, for `agda-optimization`,
an unknown key) fails fast with an error naming the file / section / key,
exit 1. A stderr breadcrumb (`<binary>: applied config from …`) fires
when a config applies, suppressed by `--quiet`, `agda-unused`'s
`--json-out`, and `agda-optimization`'s `--json`.

Discovery is identical for all five binaries — first match wins:

1. `--config=PATH`
2. `$AGDA_<TOOL>_CONFIG` — `AGDA_UNUSED_CONFIG`,
   `AGDA_OPTIMIZATION_CONFIG`, `AGDA_GOALS_CONFIG`, `AGDA_EXPLORE_CONFIG`,
   `AGDA_AUTO_CONFIG`
3. `./.agda-<tool>.yml` (or `.yaml`) in the current directory
4. walking up to the first ancestor containing a `*.agda-lib`, and the
   dotfile there

An empty file (`{}`) is valid; every key is optional.

Every binary can print a documented, ready-to-edit config populated with
its current defaults via `--show-defaults`; redirect it to bootstrap a
file:

```
agda-unused --show-defaults > .agda-unused.yml
```

The four single-command tools emit every key at its default (scalars
active, optional path/list keys as commented examples); `agda-optimization`
emits a skeleton with a `global:` section plus one section per subcommand,
each key documented with its default. Saved verbatim the dump is a no-op
overlay, so you only edit what you want to change.

### `.agda-unused.yml`

| Key        | CLI flag           | Meaning                                                    |
|------------|--------------------|------------------------------------------------------------|
| `json`     | `--json`           | Path to the expanded `graph.json`.                         |
| `rel-to`   | `--rel-to`         | Base directory findings are reported relative to.          |
| `json-out` | `--json-out`       | Emit findings as a JSON array (bool).                      |
| `kinds`    | `--kinds`          | Which finding kinds to report (YAML list or comma-string). |
| `roots`    | positional `ROOTS` | Source roots to scan (YAML list).                          |
| `exclude`  | `--exclude`        | Globs whose matching findings are dropped.                 |
| `group-by`   | `--group-by`     | Group findings by `dir` / `file` / `kind`.                 |
| `count-only` | `--count-only`   | Report per-group counts only, not each finding (bool).     |

`json:` + `roots:` supply the required CLI inputs, so `agda-unused` can
run with no arguments.

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
**kebab-case** (`load-bearing`, not `loadBearing`). Within a section the
keys are that subcommand's `--help` flags without the `--` (e.g.
`--min-support` ↔ `min-support`). `global:` keys: `json` (bool) and `out`
(output path).

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

Mirrors the daemon's CLI flags.

- **Paths:** `entry` (single entry module), `entries` (list of entry
  modules), `include` (include paths, list), `graph` (prebuilt `graph.json`
  for preloaded mode), `project`, `out-dir`, `agda-deps-bin`,
  `agda-unused-bin`, `agda-bin` (else `$AGDA_BIN` / `$PATH`).
- **Toggles (bool):** `no-term-hashes`, `no-signatures`,
  `normalise-signatures`, `show-implicit`, `no-auto-rebuild`, `no-watch`,
  `no-incremental` (drop `agda-deps`' `--incremental` cache),
  `require-well-typed` (only promote a fully type-checking rebuild; holes
  still refresh), `strict-producer` (drop `--keep-going` for `agda-deps`'
  `--incremental` cache; needs Agda ≥ 2.9), `no-query-log` (disable the
  per-`tools/call` telemetry appended to `<out-dir>/query-log.jsonl`),
  `no-auto-resolve` (don't resolve a name to its sole near-match candidate),
  `rank-idf` (IDF-weight the lemma ranker; off by default),
  `premise-select` (blend k-NN premise selection into `find_lemma` / `auto`
  ranking; off by default; needs edge provenance + signatures),
  `enable-interact` (write-side bridge), `no-auto-hints` (disable the Mimer
  probe `check` runs over remaining goals), `no-hint-batch` / `no-auto-ladder`
  (auto-search A/B tuning toggles), `inspect` (web inspector).
- **Values:** `min-term-depth` (int); `auto-hints-limit` (goals the
  check-time Mimer probe tries, default 3); `auto-hints-timeout` (Mimer
  budget per goal, seconds, default 1); `auto-hints-lemmas` (top in-scope
  graph hints seeded into that probe, default 2; `0` = plain Mimer);
  `control-port` (localhost `/check` endpoint for the edit hook; needs
  `enable-interact`; `0` = off); `inspect-port` (start port, default 7000;
  implies `inspect`); `agda-arg` (extra flags for `agda --interaction-json`,
  e.g. `--safe`); `interaction-heap-mb` (per-session `agda` heap cap in MB;
  `0` = unset); `max-interaction-sessions` (interaction session-pool cap,
  default 2); `interaction-idle-timeout` (seconds before an idle session is
  reaped; `0` = never).

**Multiple entry modules.** `--entry` is repeatable on the CLI and the
config accepts an `entries:` list alongside the back-compat scalar
`entry:` (the two are unioned, deduplicated). With more than one entry
the daemon builds **one graph over the union of all entries' import
closures** (runs `agda-deps` once per entry, unions in-process), so
`locate` / `callers` / `type_of` / `search` resolve names across the
combined closures. CLI `--entry` *appends* to config `entry:` / `entries:`,
mirroring how `-i` appends to config includes.

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
overlay-graphs:                     # federate prebuilt overlay graph(s)
  - ~/.cache/agda-explore/stdlib-2.9.0/deps.json
coverage-ignore: ["**/scratch/**"]  # source outside every closure to ignore
```

**Orientation bundle.** `brief name=X` answers the opening sequence in one
call — location + type + direct callers/callees + closest body-twins — instead
of four round trips (`goal_brief goal=gN` is the hole-side analogue under
`--enable-interact`).

**Structured output.** `search` / `callers` / `callees` accept
`format: json` for a `{tool, query, total, shown, items}` envelope; the default
stays prose.

**Stdlib federation.** `--overlay-graph FILE` (repeatable) / `overlay-graphs:`
federate a prebuilt expanded graph — typically agda-stdlib, built once via
`scripts/build-stdlib-graph.sh` — into every snapshot, so `search` / `type_of`
/ `find_lemma` answer "does the library already have this?". Overlay results
carry an `[external: <label>]` tag (they need an `open import`; edge queries
don't cross into them); project definitions win any name collision, and a
stale / unparseable overlay is warned-and-skipped, never fatal.

**Closure-coverage warning.** Source files under the include roots but outside
every entry's import closure are invisible to queries; the daemon flags them
in `status` and on an empty `search` / `locate` (so an absent name reads as
"outside the closure", not "does not exist"). Silence intentional ones with
`coverage-ignore:` globs.

**One-shot CLI.** `agda-explore query <tool> key=value… [--json] [--graph FILE]`
runs a read tool once (no daemon) and prints the result — for scripting, CI,
and non-MCP harnesses. Exit 0 on any answer (including "no results"), nonzero
only on an operational error.

```
agda-explore query brief name=Consensus.roundLeader --graph out/deps.json
agda-explore query search query=toWitness --graph out/deps.json --json | jq '.items[].name'
```

### `.agda-auto.yml`

Mirrors the CLI flags (kebab-case): `write`, `annotate`, `timeout`, `hints`,
`graph`, `overlay-graphs` (list), `json`, `include-paths` (list), `agda-bin`,
`agda-args` (list), `premise-select`, `rank-idf`, `no-hint-batch`,
`no-auto-ladder`, `project`, `wall-budget`, `repair`, `fixpoint`, `ledger`.

```yaml
timeout: 5
hints: 6
graph: out/deps.json
annotate: true
```

## Cross-repo runtime link

- **`agda-explore` → `agda-deps`.** Resolution precedence:
  `--agda-deps-bin` > `$AGDA_DEPS_BIN` > `$PATH`. Put `agda-deps` on
  `$PATH` (or pin it). Preloaded mode (an existing `graph.json`) needs no
  `agda-deps`.
- **`agda-goals` / `agda-auto` → `agda`.** Need `agda` on `$PATH` (or, for
  `agda-auto`, `--agda-bin`); neither runs `agda-deps` (they read a graph, if
  any, that already exists).

## The wire contract

`agda-deps` is the producer and canonical source of truth for the v2
`graph.json` schema; `AgdaGraph.Schema` here is the consumer mirror.

- Payloads start with `"v": 2`; expanded form also has
  `"schemaVersion": 2`, `"mode": "expanded"`.
- `nodeKeyVersion` tracks the node-naming convention (orthogonal to the
  schema version). `agda-explore` rebuilds/warns on a mismatch against
  `AgdaMcp.State.currentNodeKeyVersion` — **keep that constant in
  lock-step with `agda-deps`' `AgdaDeps.Deps.nodeKeyVersion`** across the
  two repos.
- Expanded JSON carries optional `definitionEdgesProvenance`
  (`signature | body | module-local | with | unknown`; `module-local` was
  `where` before `nodeKeyVersion` 3, still decoded for old caches) and,
  under the producer's `--with-signatures`, an optional per-definition
  `"type"`.
- Optional `moduleOptionEscapes` (`{ module → [flag] }`) carries the
  file-level `{-# OPTIONS #-}` soundness escapes (`--type-in-type`,
  `--no-positivity-check`, `--rewriting`, …); the consumer folds each into
  its enclosed defs' unsafe taint, feeding the `search` / `roots` `unsafe=`
  audit.

A machine-readable JSON Schema (draft 2020-12) for the expanded form
lives in the producer repo at `schema/graph-v2-expanded.schema.json`;
validate any `deps.json` against it with
`pipx run check-jsonschema --schemafile <path>/graph-v2-expanded.schema.json test/deps.json`.
For the full schema prose (the `packed` form and `--lazy` split-file
layout used only by `agda-deps`' HTML views), see the `agda-deps` repo.

## Relevant links

- Producer / Agda backend: <https://github.com/input-output-hk/agda-dependencies>

## AI Disclaimer

Substantial portions of this codebase were developed with AI assistance.
Everything that works is thanks to AI; whatever does not is my fault.
