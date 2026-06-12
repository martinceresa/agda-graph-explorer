# AgentsRun — how to run agda-graph-explorer end-to-end

A field manual for an **agent** (or anyone) who needs to exercise every tool in
this repository. Two ways in:

- **The fast path** — run the PyRun harness, which drives all five surfaces
  through ~354 declarative cases and writes pass/fail reports. Use this to
  prove "everything still works" or to reproduce the battle test.
- **The direct path** — invoke each executable yourself with the exact command
  shapes below. Use this when you're investigating one tool, crafting a new
  query, or adding a harness case.

Everything here is grounded in `tests/*.py` (which encode the verified
invocation shapes) and the repo's `CLAUDE.md` (the wire contract + gotchas).

> PyRun itself is a **project-independent** harness; this guide covers its
> bundled **agda-graph-explorer** instance (the `config.py` descriptor +
> `tests/`). To run the harness against a different project, see
> [`README.md` → Porting](README.md#porting-to-another-project).

---

## 0. The five surfaces

This repo ships one shared library and four executables — all **consumers** of
the v2 *expanded* `graph.json` produced by the separate `agda-deps` repo
(except `agda-goals`, which drives `agda` itself):

| area | binary | what it does | needs |
|---|---|---|---|
| `opt` | `agda-optimization` | 18 graph-level analysis subcommands | a graph.json |
| `unused` | `agda-unused` | flags unused imports/defs/opens/re-exports | a graph.json + corpus sources |
| `goals` | `agda-goals` | drives `agda --interaction-json` per file, buckets goals | `agda` on `$PATH` |
| `explore` | `agda-explore` | long-running MCP stdio daemon answering point queries | a graph.json (preloaded) or `agda-deps` (live) |
| `plugin` | — | the Claude Code plugin under `plugin/` (config/launcher/frontmatter) | — |

The **wire contract** is the only coupling to `agda-deps`: every tool reads the
v2 expanded `graph.json`. You produce that graph with `agda-deps` (§2).

---

## 1. Prerequisites

```bash
# 1. Build this repo's binaries (resolved later via `cabal list-bin`).
cd /home/mceresa/Repositories/Projects/agda-graph-explorer
cabal build            # links NO Agda — resolves from Hackage in minutes

# 2. Confirm the moving parts the harness expects:
cabal list-bin agda-optimization   # … agda-unused / agda-goals / agda-explore
agda --version                     # REQUIRED for the `goals` area (2.9.x)
ls "$AGE_CORPUS"                    # your Agda corpus (export AGE_CORPUS=…)
ls ~/Repositories/Projects/AgdaDependencies  # the agda-deps producer repo
```

Optional, per-area:

- **`scipy` + `numpy`** — only for `agda-optimization fiedler` (shells out to
  `scripts/fiedler_helper.py`). Absent → clean diagnostic exit (2/3); the
  harness tolerates that, so you can skip it.
- **`shellcheck`** — enables one extra `plugin` case (the launcher lint).
- **`agda-deps` binary** — needed only to *(re)generate* graphs (§2) or for
  `agda-explore` **live** mode. PyRun finds it via, in order:
  `$AGE_BIN_DEPS` → a recorded path in `PyRun/.agda-deps-bin` or
  `BattleTest/.agda-deps-bin` → `cabal list-bin agda-deps` in the producer repo.
  For ad-hoc direct use, putting `agda-deps` on `$PATH` is the reliable route.

The corpus is external, so **`AGE_CORPUS` must be set** to your Agda
development; other paths take repo-relative or machine defaults (see
`config.py`). Override any with `AGE_REPO`, `AGE_DEPS`, `AGE_CORPUS`,
`AGE_CORPUS_MAIN`, `AGE_OUT`, `AGE_GRAPHS`, `AGE_GRAPH_BASE`, `AGE_GRAPH_FULL`,
`AGE_BIN_*`. The `explore` cases also need corpus-specific example identifiers —
set `AGE_EX_FN`, `AGE_EX_FN2`, `AGE_EX_POSTULATE`, `AGE_EX_MODULE_PREFIX`,
`AGE_EX_SEARCH` to real names from your graph (they default to non-matching
placeholders).

---

## 2. The wire input — generating graph fixtures with `agda-deps`

Every analysis reads a graph. The harness reuses the two fixtures already under
`../BattleTest/graphs/`; to make your own, run `agda-deps` **from the corpus
dir** over the entry module:

```bash
DEPS=$(cat BattleTest/.agda-deps-bin)            # or: $(cd $AGDA_DEPS_REPO && cabal list-bin agda-deps)
CORPUS="$AGE_CORPUS"                              # your Agda corpus

# graph-base: full stdlib closure, plain (~15k nodes, ~135 MB)
( cd "$CORPUS" && "$DEPS" --keep-going --format=json --json-mode=expanded \
    --out-dir=/tmp/gb Main.lagda.md ) && mv /tmp/gb/deps.json graph-base.json

# graph-full: project-only + signatures + term-hashes + provenance (~5.8k nodes)
( cd "$CORPUS" && "$DEPS" --keep-going --no-externals --with-signatures \
    --with-term-hashes --min-term-depth=3 --format=json --json-mode=expanded \
    --out-dir=/tmp/gf Main.lagda.md ) && mv /tmp/gf/deps.json graph-full.json
```

Or just let the harness do it: `python3 run.py --prepare` (writes to `PyRun/graphs/`).

> Which graph for which feature? `graph-full` carries signatures + term-hashes +
> edge provenance, so it feeds `type_of`, `similar_*`, `term-cluster`,
> `silhouette`, `concept-bundle`, `ledger`, `debt`. `graph-base` is the big,
> plain scale-stress graph.

---

## 3. The fast path — run the PyRun harness

```bash
cd PyRun
python3 run.py --list           # see the 354 cases without running
python3 run.py                  # run everything (resumable; cached cases skipped)
python3 run.py opt explore      # just these areas
python3 run.py --force unused   # re-run an area from scratch
```

Output (under `OUT_ROOT`, = `PyRun/` by default — override with `$AGE_OUT`):

- `PyRun/<area>/report.md` — human report, **anomalies first**.
- `PyRun/<area>/report.json` — every case, machine-readable.
- `PyRun/<area>/raw/<case>.{out,err,meta.json}` — captured stdout/stderr/metadata.
- `PyRun/summary.{md,json}` — the aggregate (passed/total/crashes per area).

A case passes iff it didn't time out and every declarative check held. Crash
markers in stderr (`Uncaught exception`, `Prelude.head`, `<<loop>>`, OOM, …)
are **always** scanned and surfaced even without a `no_crash` check. See the
check vocabulary in [`README.md`](README.md#checks).

**Triage workflow:** run → open `summary.md` → for any area with failures open
`<area>/report.md` (anomalies are at the top, each with the exact cmd + links to
its `raw/<case>.out`/`.err`) → reproduce that one cmd by hand (§4).

---

## 4. The direct path — driving each tool by hand

Resolve a binary once and reuse it:

```bash
OPT=$(cabal list-bin agda-optimization)
UNUSED=$(cabal list-bin agda-unused)
GOALS=$(cabal list-bin agda-goals)
EXPLORE=$(cabal list-bin agda-explore)
GFULL=BattleTest/graphs/graph-full.json
GBASE=BattleTest/graphs/graph-base.json
CORPUS="$AGE_CORPUS"                              # your Agda corpus
```

### 4.1 `agda-optimization` — graph analyses

Invocation shape: **`agda-optimization [GLOBAL…] <subcommand> <graph.json> [SUBFLAGS…]`**.
Global flags (`--json`, `--out=FILE`, `--config=PATH`) are peeled *before* the
subcommand, so they must precede it; the token right after the subcommand is
taken verbatim as the graph path. A trailing `--json` after the path is also
honoured.

```bash
"$OPT" --help                          # top-level help + subcommand list
"$OPT" motif --help                    # per-subcommand flags (its flagSpecs)
"$OPT" motif "$GFULL"                  # default human report
"$OPT" --json motif "$GFULL"           # machine-readable JSON
"$OPT" --out=/tmp/r.txt motif "$GFULL" # redirect report to a file (stdout empty)
"$OPT" --config=my.yml motif "$GFULL"  # YAML config (stderr breadcrumb in human mode)
```

The 18 subcommands:

```
motif  load-bearing  polyglot  fingerprint  debt  basket          (rounds 1–3)
ledger echo gravity pyre chokepoint silhouette entwine fiedler
       horizon strata                                              (round 4)
term-cluster  concept-bundle                                       (rounds 6–7)
```

Notes that bite:
- **`fiedler`** shells out to `scripts/fiedler_helper.py` + scipy. Missing scipy
  → exit 3; missing helper → exit 2; both are *clean* diagnostics, not crashes.
- **`term-cluster`** needs term-hashes → use `graph-full`. On the plain base
  graph it degrades (no crash), not produces clusters.
- **Determinism is a contract:** output must be byte-identical under `+RTS -N1`
  vs `+RTS -NK` (human *and* `--json`). To check: append `+RTS -N4 -RTS` and diff.
- Config YAML is nested: a `global:` section + one **kebab-case** section per
  subcommand (`load-bearing:`, not `loadBearing:`); field names are the flags
  minus `--`. Merge order: defaults → config → CLI.

### 4.2 `agda-unused` — unused imports / defs / opens

Reads the expanded graph (`--json=`) and source-scans one or more ROOT dirs:

```bash
"$UNUSED" --help
"$UNUSED" --json="$GBASE" "$CORPUS"                       # default kinds: using,duplicate
"$UNUSED" --json="$GBASE" --kinds=all "$CORPUS"           # the rich set (382+ findings)
"$UNUSED" --json="$GBASE" --kinds=all --json-out "$CORPUS"        # JSON array out
"$UNUSED" --json="$GBASE" --kinds=all --rel-to="$CORPUS" "$CORPUS"  # relativise paths
"$UNUSED" --json="$GBASE" --kinds=all --exclude='**/Protocol/**' "$CORPUS"  # drop a subtree
"$UNUSED" --config=.agda-unused.yml                       # json+kinds+roots from YAML
```

`--kinds` tokens: `using | blanket | defined | dead | internal-only | public |
duplicate | all` (CSV, e.g. `--kinds=defined,public`; `defined` = dead +
internal-only). `--json-out` also suppresses the "applied config from" stderr
breadcrumb (clean stdout for pipes). `--exclude` is a repeatable glob matched
against path **and** dotted module name (`**` spans `/`, `*` stops at `/`).

### 4.3 `agda-goals` — drive `agda` and bucket goal types

Spawns `agda --interaction-json` **per file** (needs `agda` on `$PATH`),
captures `AllGoalsWarnings`, canonicalises each `?`-hole's type, buckets by hash.

```bash
"$GOALS" --format=human -i "$CORPUS" "$CORPUS/DebugTrace.agda"     # solved file → 0 buckets
"$GOALS" --format=json  -i "$CORPUS" "$CORPUS/DebugTrace.agda"     # {buckets, errors} JSON
# A file with holes needs --allow-unsolved-metas forwarded to agda:
"$GOALS" --format=human --agda-arg=--allow-unsolved-metas -i DIR Holes.agda
"$GOALS" --config=goals.yml FILE.agda                             # include-paths/top-n via YAML
```

Flags: `--format=human|json`, `-i/--include=DIR` (repeatable), `--agda-arg=…`
(forwarded), `--agda-bin=PATH`, `--top-n=N` (human only), `--quiet`, `--verbose`
(echoes the IOTCM `Cmd_load` + raw agda output to stderr), `--config=PATH`.
Exit codes: `0` ok · `1` CLI/usage · `2` agda missing/unexec or file-not-found ·
`3` agda exited nonzero · `4` unparseable output · `5` no AllGoalsWarnings ·
`6` agda reported a structured error first. A finished `--safe` corpus is
hole-free, so its files always yield **0 buckets** — synthesise a tiny
two-hole module to see non-empty bucketing.

### 4.4 `agda-explore` — the MCP stdio daemon

A long-running server speaking **newline-delimited JSON-RPC over stdio**. It
loads the graph once and answers point queries. Two launch modes:

```bash
# Preloaded: serve an existing graph (no agda-deps needed at all)
"$EXPLORE" --graph "$GFULL" --project "$CORPUS" \
           --agda-deps-bin "$DEPS" --agda-unused-bin "$UNUSED"

# Live: (re)generate the graph on the fly by running agda-deps as a subprocess
"$EXPLORE" --entry "$CORPUS/Main.lagda.md" -i "$CORPUS" --project "$CORPUS" \
           --agda-deps-bin "$DEPS" --out-dir /tmp/age_live

"$EXPLORE" --version    # build identity (version + git rev + date + GHC)
```

The 13 tools (from `src/AgdaMcp/Tools.hs`):
`locate · callers · callees · impact · path · roots · type_of ·
similar_types · similar_bodies · search · unused · rebuild · status`.
(`type_of` / `similar_*` need signatures/term-hashes → use `graph-full`.)

Drive it by piping a handshake + one or more `tools/call`s on stdin; the daemon
replies one JSON object per line and exits on EOF:

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent","version":"1"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"step","limit":5}}}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"locate","arguments":{"name":"My.Module.someFunction"}}}' \
 | "$EXPLORE" --graph "$GFULL" --project "$CORPUS" --agda-unused-bin "$UNUSED"
```

A clean tool-level error still exits the process 0 with `isError` in the
response payload — the daemon stays up. The `tests/explore.py` `_rpc()` helper
is the canonical blob builder; copy its examples for `callers`/`callees`
(params: `transitive`, `module_prefix`, `provenance`, `by_module`, `limit`),
`impact`, `path` (`from`/`to`/`k`), `roots`, `type_of` (`source`),
`similar_types`/`similar_bodies` (`min_sim`/`limit`), `search`
(`query`/`kind`/`state`/`module_prefix`/`top_level_only`/`limit`), and `unused`.

### 4.5 The plugin (`plugin/`)

Static assets, no run loop. Validate them as the `plugin` area does: `.mcp.json`
is valid JSON with `mcpServers` whose command ends in
`agda-explore-launch.sh`; `.claude-plugin/plugin.json` has name/version/
description; the launcher passes `bash -n` (and `shellcheck` if present), execs
`agda-explore --version` when `AGDA_EXPLORE_BIN`+`CLAUDE_PROJECT_DIR` are set,
and emits a clean exit-127 diagnostic mentioning `AGDA_EXPLORE_BIN` when no
binary resolves; the skill + agents carry `name`/`description` frontmatter.

---

## 5. Gotchas worth knowing before you trust output

These are distilled from `CLAUDE.md` — read it for the full list.

- **Determinism is an acceptance test**, not a nicety: `agda-unused` and
  `agda-optimization` build `-with-rtsopts=-N`; output must be byte-identical
  across core counts. The harness's `determinism` check enforces it on a spread.
- **`gravity` power-iteration orientation** is unguarded by tests — eyeball that
  mass flows from a high-degree theorem to a deep usee before trusting it.
- **`nodeKeyVersion`** spans repos: `agda-explore` rebuilds (live) / warns
  (preloaded) when the graph's `nodeKeyVersion` differs from
  `AgdaMcp.State.currentNodeKeyVersion`. A stale literal silently keeps a stale
  cache.
- **`fiedler` is the only opt subcommand that shells out.** Distinguish
  missing-scipy (exit 3) from missing-helper-script (exit 2).
- **A missing graph file** used to escape as an uncaught IOException — the
  battle test pinned and then fixed several such rough edges; see
  `../BattleTest/Impr.md` for the catalogue of findings and fixes.

---

## 6. TL;DR for an agent

```bash
cd /home/mceresa/Repositories/Projects/agda-graph-explorer && cabal build   # 1. build
cd PyRun && python3 run.py --list                                           # 2. see the matrix
python3 run.py                                                              # 3. run all 354 cases
#   → read PyRun/summary.md, then PyRun/<area>/report.md for any failures,
#     then reproduce the offending cmd by hand using §4.
```
