# agda-explore — Claude Code plugin

An interactive Agda library explorer for [Claude Code](https://code.claude.com).
It bundles:

- **An MCP server (`agda-explore`)** — a long-running daemon that holds an
  Agda project's dependency graph in memory and answers *point queries*
  (locate / callers / callees / impact / path / roots / type / similar /
  search / unused) instead of
  forcing the agent to `grep`. The graph is **regenerated on the fly**: when
  sources change, the server re-runs `agda-deps` (reusing Agda's `.agdai`
  cache) and hot-swaps the in-memory graph. Optionally (`--enable-interact`)
  it also exposes a **write-side interaction bridge** — goal-driven editing
  tools (`load` / `goal_type` / `case_split` / `refine` / `give` / …) backed
  by a live `agda --interaction-json` session (see below).
- **A skill (`agda-explore`)** — teaches Claude when to reach for those tools
  instead of grep, and how to read their output (including the known
  `agda-unused` false-positive caveats).
- **Two Agda agents** — `agda-simplifier` and `agda-protocol-formalizer` .

The server reuses the `agda-deps` toolset; it does not link Agda itself.

## Prerequisites

Build the binaries from the [agda-deps](../)
project:

```bash
cabal build agda-explore agda-deps agda-unused
```

Use a GHC that satisfies the project's `base < 4.22` bound — newer GHCs
(9.12+) won't resolve. If your default `ghc` is too new, pin the compiler
explicitly, e.g. `cabal build agda-explore agda-deps agda-unused -w ghc-9.6.7`.

Building is enough: the plugin's launcher finds `agda-explore` in the
`dist-newstyle` build tree automatically. Optionally put the binaries on
your `PATH` for convenience:

```bash
cabal install agda-explore agda-deps agda-unused   # onto PATH
```

`agda-explore` needs `agda-deps` (to (re)build the graph) and `agda-unused`
(for the `unused` tool). If they aren't discoverable, point at them with
`AGDA_EXPLORE_BIN`, `AGDA_DEPS_BIN`, and `AGDA_UNUSED_BIN`.

## Install the plugin

For local testing, point Claude Code at this directory:

```bash
claude --plugin-dir /path/to/agda-dependencies/plugin
```

Or add it to a marketplace and `claude plugin install agda-explore@<marketplace>`.

To enable the plugin for every session, add its directory to
`enabledPlugins` / your marketplace config in `~/.claude/settings.json`
(see the Claude Code plugin docs).

### Verify it loaded

Inside Claude Code, run `/mcp` — you should see an `agda-explore` server
listed as connected, with its tools. If it shows as failed, check the
server's stderr (Claude Code surfaces MCP server logs) for the
binary-not-found message and set `AGDA_EXPLORE_BIN` accordingly.

### Without the plugin (MCP server only)

If you only want the tools (no skill/agents), register the server directly
instead of installing the plugin:

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

## Usage

Open Claude Code inside an Agda project. The server auto-discovers the project
from the working directory — it looks for a conventional entry module
(`Main.lagda.md`, `Everything.agda`, …) and uses its directory as the include
path. Then just ask structural questions; Claude will call the tools:

> Where is `commit-eventually` defined, and what depends on it?

If auto-discovery misses your layout, set environment variables before
launching Claude Code:

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
| `locate`         | Where is `X` defined (module, file:line, kind, owner, blast radius)? |
| `callers`        | Who uses `X`? (`transitive`; `module_prefix` / `provenance` / `by_module`) |
| `callees`        | What does `X` depend on? (same `transitive` / `module_prefix` / `provenance` / `by_module`) |
| `impact`         | What breaks if I change `X`'s type? (blast radius)            |
| `path`           | *Why* does `A` depend on `B`? (shortest `from → … → to` chain, per-hop provenance; `k` for several; `module_prefix` to stay in a subtree) |
| `roots`          | Which assumptions does `X` rest on? (transitive postulates / primitives, or a `kind` / `state` / `module_prefix`, each with a witness chain; `by_module` (total + module count) / `chains=false` for a scan) |
| `type_of`        | What's the type of `X`? (elaborated, numeric literals de-sugared; `source=true` for as-written) |
| `similar_types`  | What else has a type like `X`'s?                              |
| `similar_bodies` | What else is implemented like `X`?                            |
| `find_lemma`     | Goal-directed lemma search: is there an existing def whose conclusion matches my goal? Two modes (pass one) — `anchor=<def>` (WL signature-fingerprint shape, like `similar_types`) or `goal="<type>"` (free-text conclusion token-overlap; needs a signatures-enabled graph). Filter with `kind` / `module_prefix`. |
| `search`         | Find by name substring, or list by `kind` / `state` / `module_prefix` (`top_level_only`). |
| `unused`         | Unused imports / dead code (`scope` / `exclude`; reports an excluded/suppressed count; FP caveats). |
| `rebuild`        | Force-regenerate the graph now.                               |
| `status`         | Server build fingerprint + binary path/mtime, config, freshness, graph statistics (flags a stale-format graph, and warns if a newer build is on disk — reconnect to use it). |

A fully-qualified name is always accepted; any *unique dotted suffix* (e.g.
`roundLeader`, or `Theorem3.liveness′`) resolves too, so you only need more
of the path to disambiguate. Same-named `where`/anonymous helpers are kept
distinct, named by their binding line (`Mod._.QED@388`), so `callers` /
`callees` / `impact` / `path` reflect the true call structure. Run
`agda-explore --help` for server flags — including `--normalise-signatures`
(semantic form) and `--show-implicit`, which tune the elaborated type
signatures `type_of` reports.

## Write-side interaction bridge (opt-in)

The tools above are read-only. Started with **`--enable-interact`** (or
`enable-interact: true` in `.agda-explore.yml`) and with `agda` on `$PATH`
(or `--agda-bin`), the server adds a **write** surface backed by a live
`agda --interaction-json` session — the agent edits through Agda's own
goal / case-split / refine workflow instead of blind string replacement:

| Tool           | Question / action                                                                 |
|----------------|-----------------------------------------------------------------------------------|
| `load`         | Open a module; list open goals with ids (`g0, g1, …`) + source positions. Re-`load` after edits — applying a diff can renumber goals. |
| `goal_type`    | The goal's type + in-scope context at a hole.                                     |
| `goal_context` | Just the in-scope binders and their types.                                        |
| `infer`        | Infer the type of an expression in a goal's context.                              |
| `normalize`    | Normalise (compute) an expression in a goal's context.                            |
| `case_split`   | Split a goal on a variable → unified diff of the generated clauses.               |
| `refine`       | Refine a goal by a head symbol (`f ?`) → unified diff.                            |
| `give`         | Fill a goal with a complete term, **Agda-validated** → unified diff (or the localized type error). |
| `auto`         | Mimer search (unavailable on Agda 2.9.0 — its reader rejects the command; degrades cleanly). |

Each mutator **returns a unified diff and never writes the file** — apply
it yourself, then `load` again to refresh the goals. A bad `give` term
fails locally (the file is never left broken), and a `give` / `refine`
using `postulate`, a termination/coverage/`OPTIONS` pragma, or another
escape hatch is rejected before Agda sees it (a hard zero-axiom contract).
`.lagda.md` literate sources are handled — edits land inside the
```` ```agda ```` code fence, never in the surrounding prose. To turn the
bridge on for the plugin, add `enable-interact: true` to the project's
`.agda-explore.yml` (the launcher otherwise starts the server read-only).
