# Configuration (YAML)

Each of the five binaries reads an optional YAML config. **Every key is a
kebab-case mirror of a CLI flag** (`--json-out` ↔ `json-out`; `no-*` keys
mirror the negative flags). Merge order is **defaults → config → CLI** — the
command line always wins. A bad value type (and, for `agda-optimization`, an
unknown key) fails fast with an error naming the file / section / key, exit 1.
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

## `.agda-unused.yml`

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

## `.agda-optimization.yml`

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

## `.agda-goals.yml`

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

## `.agda-explore.yml`

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

## `.agda-auto.yml`

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
