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
  `agda --interaction-json` per file as a **subprocess**, captures the
  `AllGoalsWarnings` reply, and buckets goal states by canonical hash.
  Needs `agda` on `$PATH`; links no Agda library.
- **`agda-explore`** — *interactive MCP (Model Context Protocol)
  server*: a long-running daemon that loads the expanded `graph.json`
  once into `AgdaGraph.Index` and answers point queries over stdio
  (`locate` / `callers` / `callees` / `impact` / `path` / `roots` /
  `type_of` / `similar_types` / `similar_bodies` / `search` / `unused`).
  It regenerates the graph *on the fly* by re-running `agda-deps` as a
  **subprocess** (see [Cross-repo runtime link](#cross-repo-runtime-link)).

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
`AgdaGraph.Schema` is the *consumer* mirror and must track it.

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
- **`agda-goals` → `agda`.** Drives `agda --interaction-json` per file;
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
    Protocol.hs                 --interaction-json wire format.
    Driver.hs                   per-file agda subprocess driver.
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
    Tools.hs                    MCP lifecycle + tool catalogue +
                                tools/call dispatch; `unused` shells to
                                agda-unused.

src-agda-graph/AgdaGraph/       Shared library.
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

## v2 graph.json schema (consumer view)

This repo only ingests the **expanded** form. See the `agda-deps` repo's
`CLAUDE.md` / `README.md` for the canonical, full schema (including the
`packed` form and the `--lazy` split-file layout, which only the HTML
views consume). Consumer essentials are in
[The wire contract](#the-wire-contract) above; the typed mirror is
`AgdaGraph.Schema`.
