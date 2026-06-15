# PyRun — a project-independent tool-exercise framework

A small, dependency-free (stdlib-only) Python harness that exhaustively
exercises **every executable / surface of a project** through declarative
cases, captures each invocation's artifacts, and compiles per-surface reports
plus a top-level summary.

The **engine** knows nothing about any particular project. You describe a
project in exactly two places — one `config.py` (paths, binaries, settings) and
a set of `tests/<area>.py` case modules — and the engine drives it. This
checkout ships a complete working instance for **agda-graph-explorer**; see
[Porting to another project](#porting-to-another-project) to point it at yours.

> **Driving the bundled agda-graph-explorer instance as an agent?** Read
> **[`AgentsRun.md`](AgentsRun.md)** — prerequisites, running the matrix, *and*
> how to drive each tool directly (the full CLI / MCP surface).

## Architecture — engine vs. project descriptor

```
PyRun/
  ── engine (project-independent; identical across projects) ──
  harness.py       Case model, declarative checks, the runner, report writers
  discover.py      generic tool/binary resolution (path / which / cmd / env)
  run.py           orchestrator / CLI entry point; reads the descriptor

  ── project (the ONLY project-specific code) ──
  config.py        THIS project's descriptor (paths, binaries, settings, prepare)
  tests/<area>.py  THIS project's cases: each exposes cases(ctx) -> list[Case]

  ── docs + porting ──
  README.md            this file
  AgentsRun.md         agent guide for the bundled agda-graph-explorer instance
  config.template.py   commented skeleton to copy when porting
```

`run.py` reads the descriptor through a small documented interface (see the
top of `run.py`): **required** `AREAS`, `OUT_ROOT`, `Ctx`, `outdir()`,
`capped_timeout()`; **optional** `PROJECT_LABEL`, `CRASH_MARKERS`,
`DETERMINISM_RERUN_ARGS`, `prepare()`. The engine applies defaults for every
optional piece, so a minimal descriptor is tiny.

The bundled instance's `tests/` (for reference):

```
tests/
  opt.py      agda-optimization: 18 subcommands × flags × graphs (236 cases)
  unused.py   agda-unused: all kinds, json-out, exclude, config, errors (43)
  goals.py    agda-goals: drives `agda --interaction-json` over a session pool (15)
  explore.py  agda-explore: 13 MCP tools, preloaded + live, error paths (50)
  plugin.py   plugin/: .mcp.json, manifest, launcher, frontmatter (10)
```

## Running

```bash
cd PyRun
python3 run.py                       # run every area's full matrix
python3 run.py opt explore           # only the named areas
python3 run.py --list                # list cases per area without running
python3 run.py --force               # ignore cached results; re-run every case
python3 run.py --prepare             # run the project's fixture-prep hook, then exit
python3 run.py --prepare-if-missing  # prep only what's absent, then run
                                     # (--gen / --gen-if-missing are accepted aliases)
```

No third-party packages required. Runs are **resumable**: each case caches its
result in `<area>/raw/<name>.meta.json` and is skipped on the next run unless
`--force` is given, so an interrupted run picks up where it left off.

## Output

Results land under the **output root** (`OUT_ROOT`, defaults to `PyRun/out/` so
generated files stay isolated from tracked source), one subdir per area:

```
<OUT_ROOT>/                        (PyRun/out/ by default)
  <area>/
    report.md      human-readable per-area report (anomalies first)
    report.json    machine-readable summary (every case)
    raw/<case>.out / .err / .meta.json   captured stdout/stderr/metadata
  summary.md / summary.json    aggregate across all areas
```

All generated output (fixtures + per-area reports + summary) is **gitignored**;
only the engine, the descriptor, the case modules, and the docs are tracked.

## Cases and checks

Each `tests/<area>.py` exposes `cases(ctx) -> list[Case]`, where `ctx` is the
descriptor's `Ctx` (always has `ctx.bin(name)`; the bundled instance also
exposes `graph_base`, `graph_full`, `corpus`, `repo`, …).

```python
from harness import Case
def cases(ctx):
    return [Case(
        area="opt", name="motif.default",
        cmd=[str(ctx.bin("opt")), "motif", str(ctx.graph_full)],
        note="default motif run",
        timeout=120,
        checks=[{"type": "exit_eq", "v": 0}, {"type": "stdout_nonempty"},
                {"type": "no_crash"}],
    )]
```

`Case` fields: `area, name (unique, [a-z0-9._-]), cmd (full argv), note,
stdin (bytes|None), timeout (s), cwd, env (dict merged into os.environ),
checks (list of dicts), expect_error (bool — tolerate a nonzero exit / crash
marker in the summary)`.

Checks are declarative dicts evaluated against the captured run:

| `type` | meaning |
|---|---|
| `exit_eq` `{v}` / `exit_in` `{v:[…]}` | exit code equals / is in set |
| `stdout_json` | stdout parses as a single JSON document |
| `stdout_nonempty` / `stdout_empty` | stdout byte count |
| `stdout_contains` `{v}` / `stdout_not_contains` `{v}` | substring on stdout |
| `stderr_contains` `{v}` | substring on stderr |
| `no_crash` | stderr lacks crash markers (project `CRASH_MARKERS`, else the engine default) |
| `determinism` | re-runs the command (with `DETERMINISM_RERUN_ARGS` appended); stdout+exit must match |
| `max_seconds` `{v}` | wall-time budget (soft: flagged, not fatal by itself) |

Crash markers are **always** scanned and reported even without a `no_crash`
check. A case "passes" when it didn't time out and every check holds; a failed
check or an unexpected crash is an anomaly surfaced at the top of the area
report.

### Driving a long-running / stdio process (the MCP pattern)

The bundled `explore` area drives a stdio daemon: `cmd` launches the server and
`stdin` is a newline-delimited JSON-RPC blob (`initialize` →
`notifications/initialized` → `tools/call …`). The daemon exits on EOF;
responses (one JSON object per line) are asserted with `stdout_contains`. A
clean RPC-level tool error still exits 0 with `isError` in the payload, so error
cases assert the daemon stays up and emits the error text rather than a process
failure. Reuse this pattern for any request/response-over-stdio tool.

## Porting to another project

The engine (`harness.py`, `discover.py`, `run.py`) is reused verbatim. To
exercise a different project:

1. **Copy** the `PyRun/` folder into (or beside) that project.
2. **`cp config.template.py config.py`** and fill in the marked spots: a
   `PROJECT_LABEL`, your `OUT_ROOT`, the `AREAS`, a `TOOLS` map (each tool
   resolved via a [`discover`](discover.py) spec — `path` / `which` / `cmd` /
   `env` / `first`), a `Ctx` exposing `.bin(area)` plus whatever your cases
   need, and — if your tools consume fixtures — an optional `prepare(force)`
   hook. Override `CRASH_MARKERS` / `DETERMINISM_RERUN_ARGS` only if your
   runtime needs something tighter than the engine defaults.
3. **Write `tests/<area>.py`** for each area, each exposing `cases(ctx)`.
4. `python3 run.py --list` to sanity-check discovery + counts, then
   `python3 run.py`.

Nothing else changes — the orchestrator, checks, resumability, reporting, and
the determinism / crash machinery are all project-agnostic.

---

## The bundled instance: agda-graph-explorer

`config.py` targets this repo's four executables (`agda-optimization`,
`agda-unused`, `agda-goals`, `agda-explore`) plus the `plugin/` assets.

**What it needs:** `cabal build` green here (binaries resolved via `cabal
list-bin`); the corpus + the `agda-deps` producer repo; `agda` on `$PATH` for
the `goals` area. Optional: `scipy`+`numpy` for `fiedler`, `shellcheck` for one
plugin case. See [`AgentsRun.md`](AgentsRun.md#prerequisites).

**Env overrides** (all in `config.py`): `AGE_REPO` (defaults to the repo
containing PyRun), `AGE_DEPS`, **`AGE_CORPUS`** (required — the corpus is
external, so it has no usable default), `AGE_CORPUS_MAIN`, `AGE_OUT`,
`AGE_GRAPHS`, `AGE_GRAPH_BASE` / `AGE_GRAPH_FULL`, and `AGE_BIN_OPT` …
`AGE_BIN_DEPS`. The `explore` cases also need corpus-specific example
identifiers — `AGE_EX_FN`, `AGE_EX_FN2`, `AGE_EX_POSTULATE`,
`AGE_EX_MODULE_PREFIX`, `AGE_EX_SEARCH` — set to real names from your graph
(they default to non-matching placeholders).

**Graph fixtures** — `prepare()` produces two via `agda-deps`:

- **`graph-base.json`** — full type-checked closure incl. the stdlib, plain.
- **`graph-full.json`** — project-only (`--no-externals`) **with
  `--with-signatures --with-term-hashes --min-term-depth=3`** and edge
  provenance + `externals_summary`. Feeds the signature/term/provenance
  features (`type_of`, `similar_*`, `term-cluster`, `silhouette`,
  `concept-bundle`, `ledger`, `debt`).

Fixture resolution (`config._resolve_graph`): explicit `$AGE_GRAPH_BASE` /
`$AGE_GRAPH_FULL` → `PyRun/graphs/` → the existing `../BattleTest/graphs/`
fixtures (reused as-is) → otherwise `PyRun/graphs/` as the `prepare()` target.
So a checkout that still has the `BattleTest/` archive runs immediately; if that
archive is gone, run `python3 run.py --prepare-if-missing` once (needs the
corpus + `agda-deps`; ~15 min).
