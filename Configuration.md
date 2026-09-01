# Configuration (YAML)

Each of the five binaries reads an optional YAML config. **Every key is a
kebab-case mirror of a CLI flag** (`--json-out` ↔ `json-out`). Most `no-*`
flags keep the negative spelling as their key (`--no-watch` ↔ `no-watch`), but
where a flag pair toggles one setting the key is the **positive** name —
`agda-optimization`'s `--no-include-postulates` reads `include-postulates`, so
write `include-postulates: false`. `--show-defaults` prints exactly the keys
that load, so copy from there when in doubt.

Merge order is **defaults → config → CLI** — the command line always wins. A
bad value type, or an unknown key/section, fails fast with an error naming the
file / section / key, exit 1: a key no reader looks up would otherwise silently
do nothing, which is the one mistake a config file cannot show you. The
diagnostic suggests the intended key where it can
(`unknown key: min-suport (did you mean min-support?)`).
A stderr breadcrumb (`<binary>: applied config from …`) fires when a config
applies, suppressed by `--quiet`, `agda-unused`'s `--json-out`, and
`agda-optimization`'s `--json`.

Full flag reference and run recipes: [README.md](README.md), [Examples.md](Examples.md).

## Discovery

Identical for all five binaries — first match wins:

1. `--config=PATH`
2. `$AGDA_<TOOL>_CONFIG` — `AGDA_UNUSED_CONFIG`, `AGDA_OPTIMIZATION_CONFIG`,
   `AGDA_GOALS_CONFIG`, `AGDA_EXPLORE_CONFIG`, `AGDA_AUTO_CONFIG`
3. `./.agda-<tool>.yml` (or `.yaml`) in the current directory
4. walking up to the first ancestor containing a `*.agda-lib`, and the
   dotfile there

An empty file (`{}`) is valid; every key is optional.

## Bootstrapping

Every binary prints a documented, ready-to-edit config populated with its
current defaults via `--show-defaults`; redirect it to bootstrap a file:

```sh
agda-unused --show-defaults > .agda-unused.yml
```

The four single-command tools emit every key at its default (scalars active,
optional path/list keys as commented examples); `agda-optimization` emits a
skeleton with a `global:` section plus one section per subcommand, each key
documented with its default. Saved verbatim the dump is a no-op overlay, so you
only edit what you want to change.

## Zero-config bootstrap (all tools at once)

`scripts/zero-config.py` does the whole set in one shot: it runs each binary's
own `--show-defaults`, points all of them at **one shared graph**
(`.agda-deps/deps.json` by default), and writes the six files — the five tool
configs plus a producer-side `.agda-deps.yml` holding the build recipe.

```sh
python3 scripts/zero-config.py --project /path/to/agda-project
```

Detection: include dirs come from the project's `*.agda-lib`, and the entry
module from the root modules nobody imports (`--include` / `--entry` override,
both repeatable). Then every tool runs bare:

```sh
agda-deps --config .agda-deps.yml src/Everything.agda   # build the shared graph
agda-optimization motif                                 # graph from `global: graph:`
agda-unused                                             # graph + roots from the config
```

Two deliberate asymmetries: `agda-explore` is wired **live** (`entries:` +
`include:` + `out-dir:`, not `graph:`) because its graph path is
`<out-dir>/deps.json` — so the daemon regenerates that same shared file and the
other tools read what it published; pinning `graph:` would switch it to
preloaded mode (no rebuilds, no watcher). `agda-goals` reads no graph at all, so
it just gets `roots:` + `include-paths:`.

The script **never builds the graph** (it spawns no Agda work) — it verifies
one: that it exists and decodes as v2 expanded, that it carries the
capabilities the configs assume (signatures / edge provenance / subterm
hashes, delegated to `agda-explore doctor`), and that every config resolves to
the same file — then prints the exact `agda-deps` command to build it. Existing
configs are kept unless `--force`, and a kept config that reads a *different*
graph is reported as a failure. Exit codes: `0` clean, `1` a check failed
(disagreement, or an undecodable graph — a not-yet-built graph is only a
warning), `2` usage/environment error. `--json` emits a machine-readable
envelope; `--dry-run` writes nothing.

## `.agda-unused.yml`

| Key        | CLI flag           | Meaning                                                    |
|------------|--------------------|------------------------------------------------------------|
| `graph`    | `--graph`          | Path to the expanded `graph.json` (canonical).             |
| `json`     | `--json`           | Alias of `graph` (kept for compatibility).                 |
| `rel-to`   | `--rel-to`         | Base directory findings are reported relative to.          |
| `format`   | `--format`         | Output format: `human` or `json` (canonical).              |
| `json-out` | `--json-out`       | Alias of `format: json` (bool; kept for compatibility).    |
| `kinds`    | `--kinds`          | Which finding kinds to report (YAML list or comma-string): `using`, `duplicate`, `blanket`, `dead`, `field`, `internal-only`, `public`, `arg-removable`, `arg-erasable`, plus the aliases `defined`, `args` and `all`. |
| `roots`    | positional `ROOTS` | Source roots to scan (YAML list).                          |
| `exclude`  | `--exclude`        | Globs whose matching findings are dropped.                 |
| `group-by`   | `--group-by`     | Group findings by `dir` / `file` / `kind`.                 |
| `count-only` | `--count-only`   | Report per-group counts only, not each finding (bool).     |

`graph:` + `roots:` supply the required CLI inputs, so `agda-unused` can
run with no arguments. When both a canonical key and its alias are present,
the canonical key wins.

```yaml
graph: out/deps.json
rel-to: src/
format: json
kinds: [using, blanket, duplicate]   # or the string "using,blanket"
roots: [src/, lib/]
exclude: ["**/Init.agda"]
```

## `.agda-optimization.yml`

A top-level `global:` section plus one section per subcommand, named in
**kebab-case** (`load-bearing`, not `loadBearing`). Within a section the
keys are that subcommand's `--help` flags without the `--` (e.g.
`--min-support` ↔ `min-support`).

`global:` keys:

| Key      | CLI flag                       | Meaning                                                        |
|----------|--------------------------------|----------------------------------------------------------------|
| `graph`  | `--graph` / positional         | Input expanded `graph.json`.                                   |
| `format` | `--format`                     | `human` or `json` (`json: bool` is a legacy alias).            |
| `out`    | `--out`                        | Write the report to this path instead of stdout.               |
| `explain`| `--explain` / `--no-explain`   | Append the `## How to read this` legend to a human report (default `true`). |

With `graph:` set, every subcommand runs with no path — `agda-optimization
motif`. Precedence for the input graph is `--graph FILE` > a positional
`<graph.json>` > this key.

```yaml
global:
  graph: .agda-deps/deps.json
  format: human
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

## `.agda-goals.yml`

| Key             | CLI flag     | Meaning                                         |
|-----------------|--------------|-------------------------------------------------|
| `agda-bin`      | `--agda-bin` | Path to the `agda` binary to drive.             |
| `include-paths` | `-i`         | Include paths passed to `agda` (YAML list).     |
| `agda-args`     | `--agda-arg` | Extra raw args forwarded to `agda` (YAML list). |
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

## `.agda-explore.yml`

Mirrors the daemon's CLI flags.

- **Paths:** `entry` (single entry module), `entries` (list of entry
  modules), `include` (include paths, list), `graph` (prebuilt `graph.json`
  for preloaded mode), `project`, `out-dir`, `agda-deps-bin`,
  `agda-unused-bin`, `agda-bin` (else `$AGDA_BIN` / `$PATH`).
- **Toggles (bool):** `no-term-hashes`, `no-signatures`,
  `normalise-signatures`, `show-implicit`, `no-auto-rebuild`, `no-watch`,
  `no-incremental` (full rebuilds only: re-run `agda-deps` for every entry
  and retain no per-entry graph, instead of re-running just the entries a
  change touched),
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
  `control-port` (localhost `/check` + `/repair` + `/unused` endpoint for the
  edit hook; needs `enable-interact`; `0` = off);
  `inspect-port` (start port, default 7000;
  implies `inspect`); `agda-arg` (extra flags for `agda --interaction-json`,
  e.g. `--safe`); `interaction-heap-mb` (per-session `agda` heap cap in MB;
  `0` = unset); `max-interaction-sessions` (interaction session-pool cap,
  default 2); `interaction-idle-timeout` (seconds before an idle session is
  reaped; `0` = never); `tool-tier` (`core` | `full`, default `full` — which
  tools `tools/list` advertises; every tool stays reachable via the one-shot
  `query` CLI either way).
- **Lists:** `overlay-graphs` (prebuilt expanded graphs federated into every
  snapshot, e.g. an agda-stdlib graph — their defs render `[external: …]`,
  project defs win a key collision); `coverage-ignore` (globs for source
  files intentionally outside every entry's closure, excluded from the
  closure-coverage warning).

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

## `.agda-auto.yml`

Mirrors the CLI flags (kebab-case): `write`, `annotate`, `timeout`, `hints`,
`graph`, `overlay-graphs` (list), `format` (`human`|`json`; `json: bool` is a
legacy alias), `include-paths` (list), `agda-bin`, `agda-args` (list),
`premise-select`, `rank-idf`, `no-hint-batch`, `no-auto-ladder`, `project`,
`wall-budget`, `repair`, `fixpoint`, `ledger`.

```yaml
timeout: 5
hints: 6
graph: out/deps.json
annotate: true
```
