# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

`agda-graph-explorer` is a family of **consumers** of the dependency
graph produced by [`agda-deps`](https://github.com/input-output-hk/agda-dependencies)
(a separate repository — the Agda compiler backend). Nothing here links
Agda: every tool reads `agda-deps`' v2 `graph.json` (the expanded form)
and answers questions over it. That is the entire contract between the
two repos — see [The wire contract](#the-wire-contract) below.

The repo ships one shared library and four executables:

- **`agda-graph`** (library) — typed view of the v2 expanded
  `graph.json` plus an in-memory `Index`. The shared substrate for the
  three JSON-consuming executables.
- **`agda-unused`** — flags unused imports / definitions / blanket
  opens / public re-exports from the expanded JSON.
- **`agda-optimization`** — subcommand-driven graph-level analyses
  (`motif`, `load-bearing`, `polyglot`, `fingerprint`, `debt`,
  `basket` — rounds 1–3 — plus `ledger`, `echo`, `gravity`, `pyre`,
  `chokepoint`, `silhouette`, `entwine`, `fiedler`, `horizon`,
  `strata` — round 4 — plus `term-cluster`, `concept-bundle`).
- **`agda-goals`** — *process driver* (not a `Backend`): drives
  `agda --interaction-json` over the root files using a **single
  persistent process** (`AgdaInteract.Session`, shared with
  `agda-explore`'s bridge — reuses one `.agdai` cache across files),
  captures each `AllGoalsWarnings` reply, and buckets goal states by
  canonical hash. Needs `agda` on `$PATH`; links no Agda library.
- **`agda-explore`** — *interactive MCP (Model Context Protocol)
  server*: a long-running daemon that loads the expanded `graph.json`
  once into `AgdaGraph.Index` and answers point queries over stdio
  (`locate` / `callers` / `callees` / `impact` / `path` / `roots` /
  `type_of` / `similar_types` / `similar_bodies` / `search` / `unused`).
  It regenerates the graph *on the fly* by re-running `agda-deps` as a
  **subprocess** (see [Cross-repo runtime link](#cross-repo-runtime-link)).
  Under `--enable-interact` it *also* exposes a **write-side interaction
  bridge** (`load` / `goal_type` / `goal_context` / `infer` /
  `normalize` / `case_split` / `refine` / `give` / `auto`) backed by a
  long-lived `agda --interaction-json` **subprocess** — every `give` /
  `refine` is Agda-validated and returns a unified diff (the bridge
  never writes the file). This is a *second, independent* subprocess
  model beside the graph daemon: interaction tools reflect live on-disk
  state and deliberately bypass `ensureFresh`. Needs `agda` on `$PATH`
  (or `--agda-bin`).

A Claude Code plugin under `plugin/` bundles the `agda-explore` server
with a skill and two Agda agents. See [plugin/README.md](plugin/README.md).

## Build / run

```
cabal build
cabal run agda-optimization -- motif test/deps.json
cabal run agda-unused -- --json=test/deps.json --json-out .
cabal run agda-explore -- --version
```

This repo links **no Agda** — `cabal.project` carries no
`source-repository-package` pin, so a clean build resolves entirely
from Hackage in minutes. (Contrast: the `agda-deps` repo builds Agda
2.9 from source.) `test/deps.json` and `.agda-explore/deps.json` are
committed expanded-JSON fixtures for the analyses and for the
`agda-explore` preloaded mode.

## The wire contract

The single coupling to `agda-deps` is the **v2 `graph.json` schema**
(expanded form) plus `nodeKeyVersion`. `agda-deps` is the *producer*
and the canonical source of truth for the wire shape; this repo's
`AgdaGraph.Schema` is the *consumer* mirror and must track it. A
machine-readable JSON Schema (draft 2020-12) for the expanded form
lives in the producer repo at `schema/graph-v2-expanded.schema.json` —
the fixtures here (`test/deps.json`, `.agda-explore/deps.json`)
validate against it. When `AgdaGraph.Schema` drifts from a decode
failure, check it against that schema first.

- **Schema version.** Every payload starts with `"v": 2`; expanded form
  also emits `"schemaVersion": 2` and `"mode": "expanded"`. Refuse a
  `v` you don't recognise.
- **`nodeKeyVersion`.** Orthogonal to the schema version: it tracks the
  node-*naming* convention. `agda-explore` compares the JSON's
  `nodeKeyVersion` against `AgdaMcp.State.currentNodeKeyVersion` and
  rebuilds (live) / warns (preloaded) on a mismatch. **Cross-repo
  coordination:** this constant must move in lock-step with the
  producer's `AgdaDeps.Deps.nodeKeyVersion` in the `agda-deps` repo.
  They are independent literals in separate repositories — whenever
  `nodeKey`'s shape changes there, bump `currentNodeKeyVersion` here.
- **Provenance.** Expanded JSON carries an optional
  `definitionEdgesProvenance :: [Provenance]` parallel to
  `definitionEdges` (`signature | body | where | with | unknown`).
  Absent in legacy JSON → consumer treats every edge as `unknown`.
  Fresh `agda-deps` output always emits it; `silhouette` relies on it
  and falls back to fingerprint-equivalence with a stderr note if it is
  `Nothing`.
- **Signatures.** Under the producer's `--with-signatures`, each
  definition object carries an optional `"type"` string, parsed into
  `Definition.defSig` and consumed by `agda-explore`'s `type_of`.

## Cross-repo runtime link

Two tools shell out:

- **`agda-explore` → `agda-deps`.** To regenerate the graph when sources
  change, `agda-explore` runs `agda-deps` as a subprocess.
  `AgdaMcp.State.findBin` resolves it by precedence
  **`--agda-deps-bin` > `$AGDA_DEPS_BIN` > `$PATH`** (newest-mtime
  wins among candidates). The legacy `dist-newstyle`-sibling probe only
  fires when both binaries share a build tree, which is no longer the
  case after the repo split — so the documented, reliable path is to
  put `agda-deps` on `$PATH` (or pin it). The plugin launcher
  (`plugin/bin/agda-explore-launch.sh`) says as much in its
  not-found message. Preloaded mode (point the daemon at an existing
  `graph.json`) needs no `agda-deps` at all.
- **`agda-goals` → `agda`.** Drives `agda --interaction-json` over the
  root files as one persistent subprocess (via `AgdaInteract.Session`);
  needs `agda` on `$PATH`.

## Module map

```
src/
  BuildInfo.hs                  Compile-time build identity for
                                agda-explore: package version + git
                                revision + compile date + GHC. Surfaced
                                in --version / status.
  BuildInfoTH.hs                TH helper behind BuildInfo (separate
                                module for the stage restriction):
                                captures the git revision at build time.

  MainUnused.hs                 agda-unused entry point.
  AgdaUnused/
    Analysis.hs                 unused-import / def / open analysis.
    Config.hs                   YAML config loader for .agda-unused.yml.
    Json.hs                     --json-out emission.
    Source.hs                   snippet/source helpers.

  MainOptimization.hs           agda-optimization entry point.
  AgdaOptimization/
    CLI.hs                      subcommands table + runSubcommand
                                dispatch. Add new analyses here. Loads
                                the YAML config once and seeds each
                                subcommand's parseOptions.
    CLIParse.hs                 shared parseOptions helpers.
    Config.hs                   YAML config loader for
                                .agda-optimization.yml (nested: global:
                                + one kebab-case section per subcommand).
    Report.hs                   GlobalOpts, OutFormat, emitJsonReport.
    Motif.hs ... Strata.hs      the analyses (see overview above).
    TermCluster.hs              (round 6 P3) AST subterm fingerprint
                                clusters. Reads definitionSubtermHashes.
    ConceptBundle.hs            (round 7) Apriori over signature-
                                provenance edges.
    FamilyFilter.hs             (round 7) forced-by-elaborator
                                suppressor; imported by Basket +
                                ConceptBundle.
    Common.hs                   shared name/graph helpers.
    Condense.hs                 shared SCC condensation.
    UnionFind.hs                shared path-light union-find.

  MainGoals.hs                  agda-goals entry point.
  AgdaGoals/
    Protocol.hs                 thin re-export of
                                AgdaGraph.Interaction.Protocol (kept for
                                the historical name; mirrors Canon.hs).
    Driver.hs                   batch driver over a single persistent
                                AgdaInteract.Session (one process for all
                                files; respawn-on-poison fallback).
    Canon.hs                    textual goal-type canonicaliser +
                                local Murmur64 hashString (vendored from
                                murmur-hash to keep this repo Agda-free).
    Bucket.hs                   hash-bucketing of canonical goals.
    Config.hs                   YAML config loader for .agda-goals.yml.

  MainMcp.hs                    agda-explore entry point.
  AgdaMcp/
    Config.hs                   YAML config loader for .agda-explore.yml
                                + the Opts record the CLI parser fills.
    Rpc.hs                      newline-delimited JSON-RPC-over-stdio.
    State.hs                    Config + loaded snapshot + live
                                regeneration: ensureFresh/forceRebuild
                                spawn agda-deps and hot-swap the Index;
                                sibling-binary discovery; fsnotify
                                watcher with poll fallback.
    Query.hs                    pure point queries over Index.
    Tools.hs                    MCP lifecycle + read-side tool catalogue
                                + tools/call dispatch; `unused` shells to
                                agda-unused. Appends interactTools (gated
                                on --enable-interact).
    ToolDef.hs                  shared Tool/ToolRunner record + schema
                                builders + arg accessors (so Tools.hs and
                                AgdaInteract.Tools share them, no cycle).

  AgdaInteract/                 Write-side interaction bridge (agda-explore
                                only; the long-lived agda session model).
    Session.hs                  long-lived `agda --interaction-json`
                                subprocess: prompt-delimited reply bursts,
                                timeout→poison, reader/stderr threads,
                                SessionEntry registry value.
    GoalId.hs                   stable goal ids (g0,g1,…) keyed by hole
                                char-offset, surviving Agda's renumbering
                                across reloads (syncGoals).
    Guard.hs                    no-postulate / no-escape-hatch guard on
                                give/refine input (hard zero-axiom contract).
    Literate.hs                 .lagda.md code-block detection + the
                                isInsideCode splice guard.
    Edit.hs                     splice / clause re-indent / unified-diff
                                helpers (Data.Text char offsets).
    Tools.hs                    the interaction tool runners + session
                                registry management + interactTools list.

src-agda-graph/AgdaGraph/       Shared library.
  Interaction/Protocol.hs       FromJSON mirror of the --interaction-json
                                reply wire shape (consumer source of truth;
                                shared by agda-goals + the bridge).
  Interaction/Iotcm.hs          pure IOTCM command-string builders.
  Schema.hs                     FromJSON / NFData mirror of the expanded
                                JSON. Consumer source of truth for the
                                wire shape.
  Index.hs                      strict in-memory rep: Vector Definition,
                                fwd/rev IntMap IntSet, topoSort,
                                descendants, ancestors, longestPathDP,
                                idxEdgeProvenance.
  WL.hs                         Weisfeiler–Leman refinement / hashing /
                                fingerprints / weighted Jaccard.
  Similarity.hs                 shared structural-similarity cores
                                (buildSigBodyFingerprints,
                                subtermMultisetsVec) so silhouette /
                                term-cluster / agda-explore's similar_*
                                agree by construction.

scripts/
  fiedler_helper.py             SciPy λ₂ / Fiedler-vector helper for
                                AgdaOptimization.Fiedler. Reads graph
                                JSON on stdin, writes result on stdout.
                                Requires `pip install scipy numpy`.

plugin/                         Claude Code plugin bundling the
                                agda-explore MCP server + skill + two
                                Agda agents.
```

## Hard-won gotchas (don't revert)

- **`agda-graph` library is the consumer source of truth for the wire
  shape.** `AgdaGraph.Schema` mirrors the producer's v2 expanded JSON.
  When `agda-deps` changes the schema, update `Schema.hs` here in step
  and refuse unknown `v`.

- **`nodeKeyVersion` spans repos.** Bump
  `AgdaMcp.State.currentNodeKeyVersion` here whenever the producer's
  `AgdaDeps.Deps.nodeKeyVersion` changes in the `agda-deps` repo. The
  daemon detects `loaded < current` and rebuilds (live) / warns
  (preloaded); a stale literal silently keeps a stale cache.

- **`agda-goals`' `hashString` is vendored Murmur64.**
  `AgdaGoals.Canon.hashString = asWord64 . hash64` (from `murmur-hash`)
  is byte-for-byte Agda's `Agda.Utils.Hash.hashString`. This keeps the
  repo Agda-free while leaving canonical-goal bucket hashes identical
  and cross-referenceable with the producer's `hashQName`. Don't
  re-introduce a dependency on `Agda` just for this.

- **Multicore + determinism.** `agda-unused` and `agda-optimization`
  build with `-with-rtsopts=-N` and use `Control.Parallel.Strategies`
  at known hot loops. Determinism is an acceptance test: output must be
  byte-identical between `+RTS -N1` and `+RTS -NK` (human **and**
  `--json`) on `test/deps.json`. If you add parallelism, force results
  to NF (`rdeepseq`) and use an order-preserving reduction
  (`Map.unionsWith (+)` with an associative-commutative op; `parMap`
  preserves list order).

- **`fiedler` is the only subcommand that shells out** — to
  `scripts/fiedler_helper.py` via `System.Process`. Helper-path
  precedence: `--helper=PATH` > `$AGDA_OPTIMIZATION_HELPER` >
  `Paths_agda_graph_explorer.getDataFileName "scripts/fiedler_helper.py"`
  (cabal `data-files`). Missing-SciPy → clean diagnostic (helper exits
  `3`), distinct from missing-helper-script (exit `2`). Follow the same
  pattern for any new shell-out subcommand; don't introduce a second
  mechanism.

- **Power-iteration orientation in `gravity`.** Per-theorem PPR walks
  **forward** from the seed to its usees, so the matrix-vector loop is
  called with `(idxReverse, outForward)`. The opposite orientation
  silently encodes a backward walk and collapses PPR to a delta on the
  seed. No unit test guards this — eyeball-check mass flows from a
  known high-degree theorem to a known deep usee before relying on
  output, and document the orientation in a comment at the call site.

- **Config layer (YAML).** Every executable reads a YAML config via its
  own `Config.hs` (`AgdaUnused.Config`, `AgdaOptimization.Config`,
  `AgdaGoals.Config`, `AgdaMcp.Config`). Discovery, in order:
  `--config=PATH` > `$AGDA_<BIN>_CONFIG` > `./.agda-<bin>.yml` (or
  `.yaml`) > walk up to the first ancestor containing a `*.agda-lib`.
  Merge order: **defaults → config → CLI** — never the other way.
  Top-level keys are kebab-case mirrors of the CLI flags;
  `agda-optimization` additionally nests per-subcommand sections
  (kebab-case spellings — `load-bearing`, not `loadBearing`). A stderr
  breadcrumb fires when a config applies; suppressed by `--json-out`
  (unused) / `--json` (optimization).

- **`BuildInfo` is split across two modules for the TH stage
  restriction.** The git-revision splice generator lives in
  `BuildInfoTH`; `BuildInfo` does the `$(gitRevisionE)` splice + the CPP
  `__DATE__`/`__TIME__`. Both are in `agda-explore`'s `other-modules`
  (the only executable that uses them) with `Paths_agda_graph_explorer`
  + `template-haskell`. The reliable "is this a newer build?"
  discriminator is the running binary's *mtime*
  (`AgdaMcp.State.binaryIdent`), not the fingerprint, whose `built` date
  freezes across a rebuild that doesn't recompile `BuildInfo`.

- **The `--interaction-json` protocol is not version-stable, so it is
  pinned by golden fixtures.** `test/interaction/<agda-version>/*.jsonl`
  are real `agda` transcripts; the offline `interaction-spec` test-suite
  replays them through `AgdaGraph.Interaction.Protocol` (CI never runs
  `agda`). An Agda bump that changes the wire shape fails that suite —
  regenerate with `bash test/interaction/regen.sh` (needs `agda`) and
  review the diff. The parser is deliberately **lenient** (unknown
  `kind` → `Other*`, never a decode crash) for the same reason; keep it
  that way.

- **Interaction bursts are delimited by the `JSON> ` prompt, not by line
  structure.** Agda prints the readiness prompt *without* a trailing
  newline, so it glues onto the first reply of the next burst
  (`JSON> {…}`). `AgdaInteract.Session`'s reader emits a burst boundary
  on the prompt *prefix* of a line AND on a trailing bare `JSON> `
  (a line reader would block on the latter — it has no newline). One
  prompt = one command settled. Do not "simplify" this to `hGetLine`.

- **Interaction positions are 1-based *character* offsets into the full
  file** (prose included for `.lagda.md` — verified by fixture). So
  literate range-mapping is the identity; splicing uses `Data.Text`
  character indexing (`AgdaInteract.Edit`), never bytes (`→` is one
  char, three bytes). `AgdaInteract.Literate.isInsideCode` is a guard
  that refuses to splice into literate prose.

- **The write-side bridge enforces a hard zero-axiom contract and never
  writes the file.** `AgdaInteract.Guard.checkGiveInput` rejects
  `postulate` / termination-or-coverage-or-`OPTIONS` pragmas / escape
  identifiers *before* the term reaches Agda; `give`/`refine` return a
  unified diff for the caller to apply, then mark the session dirty so
  the next query reloads from (unchanged) disk — keeping the bridge's
  view consistent with disk. `auto` (Mimer) is wired but Agda 2.9.0's
  IOTCM reader rejects `Cmd_autoOne`, so it degrades with a clear note;
  it lights up automatically on an Agda that accepts the command.

- **`agda-goals` and the bridge share one session driver
  (`AgdaInteract.Session`), but it must stay goal-id-free.** The
  daemon's per-session goal-id state lives in `AgdaInteract.Registry`
  (`SessionEntry`), NOT in `Session`, so `agda-goals` can reuse the bare
  transport without pulling in `AgdaInteract.GoalId`. `agda-goals` now
  drives all files over ONE persistent process (`runDriverBatch`); its
  goal extraction is **byte-identical** to the old one-process-per-file
  driver — a `Cmd_load` yields the same `AllGoalsWarnings` whether the
  process is fresh or reused, and `scanReplies` is unchanged. That
  byte-identity is the acceptance test for the unification; re-check it
  (human + `--format=json`) against a known corpus if you touch the
  driver or the session reader.

## v2 graph.json schema (consumer view)

This repo only ingests the **expanded** form. See the `agda-deps` repo's
`CLAUDE.md` / `README.md` for the canonical, full schema (including the
`packed` form and the `--lazy` split-file layout, which only the HTML
views consume). Consumer essentials are in
[The wire contract](#the-wire-contract) above; the typed mirror is
`AgdaGraph.Schema`.
