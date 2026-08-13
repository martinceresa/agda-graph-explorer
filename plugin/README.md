# agda-explore — Claude Code plugin

An interactive Agda library explorer for [Claude Code](https://code.claude.com). It bundles:

- **An MCP server (`agda-explore`)** — a daemon that holds an Agda project's dependency graph in memory and answers point queries instead of `grep`. The graph is regenerated on the fly (re-runs `agda-deps`, hot-swaps the in-memory graph). `--enable-interact` adds a write-side interaction bridge; `--inspect` adds a localhost web inspector (both below).
- **A skill (`agda-explore`)** — teaches Claude when to use the tools and how to read their output.
- **Two Agda agents** — `agda-simplifier` and `agda-protocol-formalizer`.
- **Two hooks** — after any text edit to an Agda file, validate it through the warm bridge (or nudge to); on the first structural `grep`, route to the graph tools instead (below).

The server reuses the `agda-deps` toolset; it does not link Agda itself.

## Prerequisites

Build this repo's binaries (GHC 9.14.x + cabal 3.16; `cabal.project` pins `ghc-9.14.1`, which earlier GHCs cannot substitute for — see the repo README):

```bash
cabal build agda-explore agda-unused
```

That's enough — the launcher finds `agda-explore` in the `dist-newstyle` build tree. Optionally put the binaries on `PATH`:

```bash
cabal install agda-explore agda-unused   # onto PATH
```

At runtime `agda-explore` also needs **`agda-deps`** — a *separate* repo (the Agda backend that builds the graph); put it on `PATH`. It needs `agda-unused` for the `unused` tool. If any aren't discoverable, point at them with `AGDA_EXPLORE_BIN`, `AGDA_DEPS_BIN`, `AGDA_UNUSED_BIN`. Preloaded mode (a fixed `--graph`) needs no `agda-deps`.

## Install the plugin

Point Claude Code at this directory:

```bash
claude --plugin-dir /path/to/agda-graph-explorer/plugin
```

Or add it to a marketplace and `claude plugin install agda-explore@<marketplace>`. To enable it for every session, add its directory to `enabledPlugins` in `~/.claude/settings.json` (see the Claude Code plugin docs).

### Verify it loaded

Run `/mcp` inside Claude Code — `agda-explore` should show as connected with its tools. If it failed, check the server's stderr for the binary-not-found message and set `AGDA_EXPLORE_BIN`.

For a full environment preflight (is `agda-deps` / `agda` resolvable? is the graph valid?), run `agda-explore doctor` (add `--enable-interact` to also check `agda`, `--json` for a machine-readable envelope). It prints one ✓/✗ line per check with a fix hint on each failure.

### Without the plugin (MCP server only)

For just the tools (no skill/agents), register the server directly:

```bash
claude mcp add agda-explore -- /abs/path/to/agda-explore --project "$PWD"
```

or check a project-scoped `.mcp.json` into the Agda repo:

```json
{
  "mcpServers": {
    "agda-explore": {
      "command": "/abs/path/to/agda-explore",
      "args": ["--project", "."]
    }
  }
}
```

## What the launcher passes

The launcher starts the server with a few opinionated defaults (all overridable):

- **`--tool-tier core`** — advertises the measured-used tool subset (read tools + the `load`/`goal_brief`/`inspect`/`check`/`repair`/`lemmas` validate loop), cutting the agent's per-choice decision-load. The authoring/advanced tools (`auto`, `construct`, `scratch`, `give_file`, `new_module`, and `path`/`roots`/`similar_*`) stay reachable — add `--tool-tier full` to `.mcp.json`'s `args` to advertise them.
- **`--enable-interact --control-port 7100`** — turns on the write bridge and a localhost control endpoint (port probed upward on clash) so the edit hook runs a *real* warm `check` after every Agda edit, not just a nudge. Set **`AGDA_EXPLORE_NO_INTERACT=1`** to opt out (e.g. no `agda` on the machine).

## Usage

Open Claude Code inside an Agda project. The server auto-discovers the project: it finds a conventional entry module (`Main.lagda.md`, `Everything.agda`, …) and uses its directory as the include path. Then ask structural questions:

> Where is `commit-eventually` defined, and what depends on it?

If auto-discovery misses your layout, set env vars before launching Claude Code:

```bash
export AGDA_EXPLORE_ENTRY=agda-src/Main.lagda.md
export AGDA_EXPLORE_INCLUDE=agda-src          # PATH-separated for several
```

Or serve a fixed, pre-generated graph (no rebuilds):

```bash
export AGDA_EXPLORE_GRAPH=/abs/path/to/deps.json
```

## Tools

| Tool             | Question it answers                                            |
|------------------|---------------------------------------------------------------|
| `brief`          | Orient on `X` in one call: location + type + callers + callees + structural twins (one-call bundle; drill in with the individual tools). |
| `locate`         | Where is `X` defined? (module, file:line, kind, owner, blast radius) |
| `callers`        | Who uses `X`? (`transitive`; `module_prefix` / `provenance` / `by_module`) |
| `callees`        | What does `X` depend on? (same filters as `callers`) |
| `impact`         | What breaks if I change `X`'s type? (blast radius) |
| `path`           | *Why* does `A` depend on `B`? (shortest chain, per-hop provenance; `k`, `module_prefix`) |
| `roots`          | Which assumptions does `X` rest on? (transitive postulates / primitives, with witness chains; `kind` / `state` / `module_prefix` / `by_module` / `chains=false`). `unsafe=any` makes it a transitive soundness audit. |
| `type_of`        | What's the type of `X`? (elaborated; `source=true` for as-written) |
| `similar_types`  | What else has a type like `X`'s? |
| `similar_bodies` | What else is implemented like `X`? |
| `find_lemma`     | Goal-directed lemma search: `anchor=<def>` (WL fingerprint) or `goal="<type>"` (name/shape match — combinator shape + def name + conclusion; needs signatures). Filter with `kind` / `module_prefix`. |
| `search`         | Find by name substring, or list by `kind` / `state` / `module_prefix` (`top_level_only`). `unsafe=any` audits soundness escapes; `mode=text` ripgreps the source bytes for what the graph doesn't index (pragmas, comments, regex). |
| `unused`         | Unused imports / dead code (`scope` / `exclude`; FP caveats). |
| `rebuild`        | Force-regenerate the graph now. |
| `status`         | Server fingerprint + binary path/mtime, config, freshness, graph stats (flags a stale-format graph or a newer build on disk). |

A fully-qualified name is always accepted; any *unique dotted suffix* (e.g. `roundLeader`, `Theorem3.liveness′`) resolves too. Same-named `where`/anonymous helpers stay distinct, named by binding line (`Mod.QED@388`). Run `agda-explore --help` for server flags — including `--normalise-signatures` and `--show-implicit`, which tune the types `type_of` reports.

## Write-side interaction bridge (opt-in)

Start with **`--enable-interact`** (or `enable-interact: true` in `.agda-explore.yml`) and `agda` on `$PATH` (or `--agda-bin`) to add a write surface backed by a live `agda --interaction-json` session — the Agda-validated alternative to a blind `Write` + `agda File`, covering authoring and hole-driving. See the skill for details.

| Tool           | Question / action |
|----------------|-------------------|
| `load`         | Open a module; list goals (`g0, g1, …`) + positions. Re-`load` after edits — diffs can renumber goals. |
| `goal_brief`   | One-call orientation on an open goal: its type + in-scope context + the top reusable lemmas whose conclusion resembles it. Lead with this after `load`. |
| `inspect`      | Read-only live-goal query (batcher): `op=type` (goal type + in-scope context) / `op=context` (just the binders + types) / `op=infer` / `op=normalize` (of `expr`) → the live-hole analogue of `type_of`. `load` first. |
| `auto`         | Mimer proof search on one goal → a fill diff, or a "no solution" note. On failure it retries seeded with the top `find_lemma` lemmas for the goal, so one-lemma goals close (`timeout` / `hints` tune). The recommended when-stuck move. |
| `construct`    | Primary hole-filling interface: drive holes with a SEQUENCE of `{op, goal, …}` steps against one warm load — `give` (`term`) / `refine` (`expr`) / `case_split` (`var`) / `auto` → one combined diff. A single `{op:auto, goal:"*"}` step runs Mimer over EVERY open goal. |
| `scratch`      | Scratch-module lifecycle (batcher): `op:open` opens an ephemeral scratch module (optional `target` seeds imports) to build a new def in isolation; `op:promote` splices its def(s) into the real `target`, merges imports, re-validates the whole target (honours `write`); `op:discard` drops it. |
| `check`        | Type-check a module (on-disk or `content` dry-run) → ✓/✗ + every error/warning + open goals. On the live path it also probes remaining goals with Mimer and reports ready-made solutions inline (`--no-auto-hints` disables; `--auto-hints-limit` / `--auto-hints-timeout` tune). |
| `give_file`    | Author a whole file (`content`) or append a block (`append`), guarded + type-checked → diff (or `write:true`). |
| `new_module`   | Scaffold a NEW validated module: header, literate fences, imports resolved off the graph, a hole per `{name,type}` stub. |
| `lemmas`       | Goal-directed lemma search off a live goal's type → candidates to feed a `construct` `give`/`refine` step. |
| `repair`       | Drive an almost-correct file to typecheck by interpreting the compiler's diagnostics: add missing imports (resolved off the graph — operators/constructors included) and fix misspelled references. Spec-preserving + zero-axiom; semantic errors refused, not faked → report + diff (or `write:true`). |

By default each mutator **returns a diff and does not write** — apply it yourself, then `load` again. **`write:true`** instead applies the edit, reloads, and returns the diff plus refreshed goals. A bad term fails locally (file never left broken). Any `postulate` / termination / coverage / unsafe-`OPTIONS` pragma / escape hatch is rejected before Agda sees it (a hard zero-axiom contract, enforced over whole-file content too). `.lagda.md` edits land inside the ```` ```agda ```` fence, never the prose. To turn the bridge on for the plugin, add `enable-interact: true` to the project's `.agda-explore.yml`.

## Hooks

**Requirements:** both hooks need **`jq`** on `PATH` to parse their input, and
the edit hook's real-check path additionally needs **`curl`** to reach the
control endpoint. Without them the hooks degrade silently (the launcher prints
a one-line notice at startup so you know why). Install both to enable the full
loop.

The plugin ships two hooks (`hooks/hooks.json`; they need `jq` on `PATH` and are active only while the plugin is enabled):

- **`post-agda-edit`** (PostToolUse on `Edit`/`Write`): after any text edit to an `.agda` / `.lagda*` file, close the edit→check loop. If the daemon serves its control endpoint (below), the hook runs a REAL warm `check` and injects the verdict + diagnostics + goals as context; otherwise it injects a one-line nudge to call the bridge's `check` (rate-limited per session+file, so refactors aren't spammed). It never blocks the edit.
- **`pre-grep-route`** (PreToolUse on `Grep`): the FIRST structural grep over Agda sources in a session is denied with the grep→graph tool mapping (`locate` / `search` / `callers` / `callees` / `type_of` / `find_lemma`); every later grep sails through — text searches over prose and comments are legitimate.

**Kill switch:** disable the plugin, or delete/blank `hooks/hooks.json`.

### Measuring tool usage

In live mode the server appends one JSON line per `tools/call` to
`<out-dir>/query-log.jsonl`. Turn any deployment's log into a per-tool table
(call count, error %, stale %, dur_ms p50/p95) with:

```bash
scripts/tool-usage-report.sh <project>/.agda-explore/query-log.jsonl
```

That table is the evidence for tuning `--tool-tier` (which tools are actually
used, and how reliably). Needs `jq`.

### Control endpoint (Phase 2 of the edit hook)

Start the daemon with **`--control-port N`** (or `control-port: N` in `.agda-explore.yml`; needs `--enable-interact`) to serve `GET /check?file=…` and `GET /repair?file=…` (diff-only, never writes) on localhost — the same warm check and repair the MCP `check` / `repair` tools run, callable by the hook from outside the MCP transport. The bound port (probed upward from N) is written to `<out-dir>/control-port` for discovery and removed on shutdown; a busy endpoint answers `503` and the hook degrades to the nudge. Localhost-only, off by default.

## Live web inspector (opt-in)

Start with **`--inspect`** (or `inspect: true` in `.agda-explore.yml`) to watch the agent live in a browser:

- an **activity feed** of every tool call (one line each; click to expand args + result);
- an **editing view** — the loaded module with each proposed diff highlighted, plus the open goals.

It streams over Server-Sent Events; the daemon prints the URL on stderr (`inspector at http://127.0.0.1:7000`). Read-only, localhost-only, no auth — a pure side channel that never touches the MCP stdio.

**One inspector per daemon.** With several projects open, give each a distinct `inspect-port:` in its `.agda-explore.yml` (otherwise it probes upward from 7000 on a clash). The page header and tab title name the project + port; `ss -ltnp | grep ':70'` maps ports → daemons. After a rebuild or config change, reconnect (`/mcp`) to pick it up.
