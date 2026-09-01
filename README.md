# agda-graph-explorer

Consumers of the dependency graph emitted by
[`agda-deps`](https://github.com/input-output-hk/agda-dependencies) — a shared
library plus five executables that read `agda-deps`' v2 `graph.json` and answer
questions over it. **Nothing here links Agda**, so the whole repo builds from
Hackage in minutes.

| Tool                       | What it does                                                                                                                              |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| **`agda-graph`** (library) | Typed view of the expanded `graph.json` + an in-memory `Index`. The substrate the executables share.                                      |
| **`agda-unused`**          | Flags unused imports / definitions / blanket opens / public re-exports / never-projected record fields / unused arguments.                 |
| **`agda-optimization`**    | 19 subcommands: 18 graph-level analyses (centrality, clustering, motif mining, axiom footprint, …) + `hint-bench`, an offline lemma-ranker eval. |
| **`agda-goals`**           | Drives `agda --interaction-json` over a pool of persistent processes and buckets goal states by canonical hash. Needs `agda` on `$PATH`. |
| **`agda-explore`**         | Interactive MCP server: a daemon that answers point queries over the graph for coding agents, regenerating it on the fly via `agda-deps`. |
| **`agda-auto`**            | Batch hole-filler: runs `agda-explore`'s Mimer + graph-hint ladder over every open hole in a file (or a project), prints a diff or applies it, and annotates holes it can't close. Needs `agda` on `$PATH`. |

Runnable recipes: [Examples.md](Examples.md). Per-subcommand analysis reference
(what each one does, how to read its report): [docs/](docs/README.md). YAML
config: [Configuration.md](Configuration.md). Wire schema:
[The wire contract](#the-wire-contract). Roadmap / deferred / shipped work:
[TODO.md](TODO.md), [Backlog.md](Backlog.md), [Deferred.md](Deferred.md),
[Changelog.md](Changelog.md).

## Try it in 30 seconds

No `agda-deps`, no `agda`, no project — every read tool runs against the
committed fixture `test/deps.json`:

```sh
cabal build

# Rank the definitions that most results rest on:
cabal run -v0 agda-optimization -- load-bearing test/deps.json

# Find a definition by name substring:
cabal run -v0 agda-explore -- query search query=eval --graph test/deps.json

# Orient on one definition — location, type, callers, callees, twins:
cabal run -v0 agda-explore -- query brief name=Test.eval --graph test/deps.json
```

(The committed fixtures predate the current node-key convention and carry the
paths of the project they were generated from, so the `explore` queries print
harmless freshness / closure-coverage notes — that tracking is a feature; the
answers themselves are correct.)

## Prerequisites

- GHC 9.14.x + cabal 3.16. `cabal.project` pins `ghc-9.14.1`, and that is a
  requirement rather than a preference: GHC 9.12.x's RTS corrupts the heap under
  ≥ 2 capabilities, and every batch executable is built `-with-rtsopts=-N`.
- `agda-optimization`'s `fiedler` subcommand only: `pip install scipy numpy`.
- `agda-goals`, `agda-auto`, `agda-explore --enable-interact`: `agda` on `$PATH`.
- `agda-explore`'s live regeneration: `agda-deps` on `$PATH` (see
  [Cross-repo runtime link](#cross-repo-runtime-link)).

## Build

```sh
cabal build
```

### Installing the binaries

`cabal run` works but re-checks the build and prints startup noise on every
invocation. For repeated use, install real binaries onto your `PATH`:

```sh
cabal install exe:agda-explore exe:agda-auto exe:agda-optimization \
              exe:agda-unused exe:agda-goals \
              --installdir="$HOME/.local/bin" --overwrite-policy=always
```

The plugin launcher resolves `agda-explore` by precedence
`$AGDA_EXPLORE_BIN` > `$PATH` > newest `dist-newstyle` build tree, so an
installed binary wins over a stale in-tree build automatically.

## Producing the input graph

Every tool consumes the **expanded** v2 JSON, produced by `agda-deps`:

```sh
agda-deps --format=json --json-mode=expanded -i src/ -o out/ src/Everything.agda
# → out/deps.json
```

Two committed fixtures let you try the tools without `agda-deps`:
`test/deps.json` and `.agda-explore/deps.json`.

### Getting `agda-deps`

`agda-deps` is a **separate** repo (the Agda compiler backend that emits the
graph). Build and install it once:

```sh
git clone https://github.com/input-output-hk/agda-dependencies
cd agda-dependencies
cabal install exe:agda-deps --installdir="$HOME/.local/bin" --overwrite-policy=always
```

Then put it on `$PATH`, or point `agda-explore` at it with `--agda-deps-bin`
/ `$AGDA_DEPS_BIN`. Only live graph regeneration needs it — every tool in
**preloaded mode** (`--graph FILE` / a positional `graph.json`) works with no
`agda-deps` at all.

## Running the tools

Essential invocations below; flag-by-flag recipes are in
[Examples.md](Examples.md), YAML config in [Configuration.md](Configuration.md).

**Flag conventions.** Across the tools, the input graph is `--graph FILE`
(`agda-optimization` also takes it positionally) and the output format is
`--format human|json`. The older spellings — `agda-unused`'s `--json=FILE`
(input) and `--json-out`, and `--json` (output) on `agda-optimization` /
`agda-auto` — remain as permanent aliases, so existing scripts keep working.
All five binaries also answer `--help`, `--version`, `--numeric-version` (the
bare number, for scripts) and `--show-defaults`.

### `agda-unused` — flag unused imports / defs / opens

```sh
cabal run agda-unused -- --graph=out/deps.json ROOT…            # human-readable
cabal run agda-unused -- --graph=out/deps.json --format=json .  # JSON array
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

Every human-format report ends with a **`## How to read this`** legend: what
that analysis answers, what each section is, what every column means, and which
row is worth acting on — so a `--out FILE` report explains itself to whoever
opens it. `--no-explain` (or `explain: false` under `global:`) drops it; `--json`
is unaffected.

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
cabal run agda-explore -- doctor --graph out/deps.json                 # environment preflight
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

When the server or a tool misbehaves, run **`agda-explore doctor`** first: it
checks `agda-deps` / `agda` resolution, the graph's schema and capabilities,
and out-dir writability, printing a fix hint on every failure (`--json` for a
structured envelope).

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

## Shell completions

`agda-optimization` can print a completion script (generated from its flag
table, so it never drifts from the parser):

```sh
# bash — install into your completions dir:
agda-optimization --completion-script=bash \
  > "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/agda-optimization"

# zsh (reuses the bash function via bashcompinit):
agda-optimization --completion-script=zsh > ~/.agda-optimization.zsh && echo 'source ~/.agda-optimization.zsh' >> ~/.zshrc
```

It completes the 19 subcommands and each subcommand's flags.

## Configuration (YAML)

Each binary reads an optional YAML config; every key is a kebab-case mirror of a
CLI flag, merged **defaults → config → CLI** (the command line always wins).
Discovery, first match wins: `--config=PATH` > `$AGDA_<TOOL>_CONFIG` >
`./.agda-<tool>.yml` > nearest ancestor with a `*.agda-lib`. Bootstrap a
ready-to-edit file with `<binary> --show-defaults`, or all of them at once —
each pointed at one shared `.agda-deps/deps.json` — with
`python3 scripts/zero-config.py --project DIR`, after which every tool runs with
no flags. Full per-tool key reference: [Configuration.md](Configuration.md).

An **unknown key is an error**, not a silent no-op — the same treatment the
argv parsers give an unknown flag, since a mistyped key would otherwise just
fail to do anything. The diagnostic names the offender and suggests the
intended key (`unknown key: min-suport (did you mean min-support?)`). A `--no-x`
flag reads the positive key `x`, so write `x: false` rather than `no-x: true`;
`--show-defaults` prints only keys that load.

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
- Two optional fields separate *missing* evidence from an honest hole, which
  `state: "H"` alone cannot: per-definition `unsolvedMetas` (count of silent
  non-interaction metas, omitted when `0`) and top-level `unsolvedModules`
  (`{module → {metas: [line], constraints: [line]}}`, omitted when empty). They
  only appear when the producer ran with `--allow-unsolved-metas` /
  `--lenient-imports` — there Agda postulates the open metas and the module
  *succeeds*, so `failedModules: []` does **not** mean the project type-checks.
  Meta lines are exact; constraint lines are best-effort locations.
- Optional per-definition `argUsage` — which telescope positions the definition
  never uses, read off Agda's own occurrence/polarity analysis. `removable`
  (binder and call-site argument can go) and `erasable` (used only in types, an
  `@0` candidate) are 0-based positions with **implicits counted**, on the
  definition's *own* signature line; `arity` bounds them, `binders` gives each
  reported position's hiding and name, and `removableRequires` maps a position
  to the others that must be deleted **with** it. Omitted when there is nothing
  to report. Two rules for a consumer: act on a `removableRequires` set, never
  a lone position, or the removal strands a later binder; and never align these
  indices against the sibling `type` string, which still shows the binders a
  parametrised module or `where` block lifted in. Consumed by `agda-unused`'s
  `arg-removable` / `arg-erasable` kinds.

A machine-readable JSON Schema (draft 2020-12) for the expanded form lives in the
producer repo at `schema/graph-v2-expanded.schema.json`. For the full schema
prose (the `packed` form and `--lazy` layout used only by `agda-deps`' HTML
views), see the `agda-deps` repo.

## Relevant links

- Producer / Agda backend: <https://github.com/input-output-hk/agda-dependencies>
- Similar project -- Glean <https://github.com/facebookincubator/Glean>
  Ideas are a bit different but may be related.
  Semantic grepable source code projects.

## AI Disclaimer

Substantial portions of this codebase were developed with AI assistance.
Everything that works is thanks to AI; whatever does not is my fault.
