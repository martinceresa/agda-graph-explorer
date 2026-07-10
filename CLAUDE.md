# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

`agda-graph-explorer` is a family of **consumers** of the dependency graph
produced by [`agda-deps`](https://github.com/input-output-hk/agda-dependencies)
(a separate repo — the Agda compiler backend). Nothing here links Agda: every
tool reads `agda-deps`' v2 `graph.json` (expanded form). That is the entire
contract between the repos — see [The wire contract](#the-wire-contract).

One shared library and four executables:

- **`agda-graph`** (library) — typed view of the expanded `graph.json` + an
  in-memory `Index`; the shared substrate for the JSON-consuming executables.
- **`agda-unused`** — flags unused imports / definitions / blanket opens /
  public re-exports from the expanded JSON.
- **`agda-optimization`** — 18 subcommand-driven graph-level analyses:
  `motif`, `load-bearing`, `polyglot`, `fingerprint`, `debt`, `basket`,
  `ledger`, `echo`, `gravity`, `pyre`, `chokepoint`, `silhouette`, `entwine`,
  `fiedler`, `horizon`, `strata`, `term-cluster`, `concept-bundle`.
- **`agda-goals`** — *process driver* (not a `Backend`): drives
  `agda --interaction-json` over the root files via a pool of persistent
  `AgdaInteract.Session`s (shared with `agda-explore`'s bridge; one per RTS
  capability, work-stealing queue, `+RTS -NK` caps it), captures each
  `AllGoalsWarnings`, and buckets goal states by canonical hash. Results
  reassembled in input order ⇒ byte-identical across `-N1`/`-NK`. Needs `agda`
  on `$PATH`; links no Agda.
- **`agda-explore`** — *interactive MCP server*: loads the expanded
  `graph.json` once into `AgdaGraph.Index` and answers point queries over
  stdio (`brief` / `locate` / `callers` / `callees` / `impact` / `path` /
  `roots` / `type_of` / `similar_types` / `similar_bodies` / `find_lemma` /
  `search` / `unused`; `brief` is a one-call orientation bundle, and
  `search`/`callers`/`callees` take `format:json` for a structured envelope),
  regenerating the graph on the fly by re-running `agda-deps` as a
  subprocess. `--overlay-graph FILE` (repeatable) federates a prebuilt
  overlay graph (e.g. agda-stdlib) into every snapshot — its defs render an
  `[external: …]` tag; project defs win key collisions. A closure-coverage
  warning (config `coverage-ignore:` globs) flags source files outside every
  entry's closure. A one-shot `agda-explore query <tool> key=value…` CLI
  dispatches through the same read-tool table without a daemon. Under
  `--enable-interact` it also exposes a **write-side
  interaction bridge** (`load` / `goal_brief` / `check` / `goal_type` / `goal_context` /
  `infer` / `normalize` / `case_split` / `refine` / `give` / `give_many` /
  `auto` / `auto_all` / `construct` / `give_file` / `new_module` / `lemmas` /
  `repair` / `stage` / `promote` / `discard`; `goal_brief` is the hole-side
  orientation bundle, and `repair` interprets the compiler's diagnostics to add
  missing imports and fix misspelled references — graph-backed, spec-preserving,
  refusing semantic errors, see `FixLoop.md`) over a long-lived
  `agda --interaction-json`
  subprocess: every mutator is Agda-validated and returns a unified diff (no
  write unless passed `write:true`, which applies + reloads), under a hard
  zero-axiom contract. Beyond hole-filling it authors files (`check`,
  `give_file`, `new_module`, `construct`, `lemmas`). A *second, independent*
  subprocess model beside the graph daemon — interaction tools reflect live
  on-disk state and bypass `ensureFresh` (except `lemmas` and `new_module`
  import resolution, which read the graph index). A live `check` also probes
  remaining goals with Mimer (`auto-hints`, on by default) and reports found
  terms inline. Under
  `--inspect`/`--inspect-port N` it also serves an opt-in localhost web
  inspector (`AgdaMcp.Inspect`): a live activity feed + editing view over
  HTTP+SSE, off by default, localhost-only, never touching the JSON-RPC
  stdout; probes upward from the start port so several daemons coexist.
  Under `--control-port N` (needs `--enable-interact`) it serves a second
  localhost side channel (`AgdaMcp.Control`, `GET /check?file=…` and
  `GET /repair?file=…`, diff-only) so the plugin's PostToolUse hook can run the
  warm check and suggest a repair from outside the MCP transport. Needs `agda`
  on `$PATH` (or `--agda-bin`).

A Claude Code plugin under `plugin/` bundles the `agda-explore` server with a
skill, two Agda agents, and two hooks (PostToolUse: validate Agda text edits
through the warm bridge / control endpoint; PreToolUse: route the first
structural grep to the graph tools). See [plugin/README.md](plugin/README.md).

## Build / run

```
cabal build
cabal run agda-optimization -- motif test/deps.json
cabal run agda-unused -- --json=test/deps.json --json-out .
cabal run agda-explore -- --version
```

This repo links **no Agda** — `cabal.project` has no
`source-repository-package` pin, so a clean build resolves from Hackage in
minutes. `test/deps.json` and `.agda-explore/deps.json` are committed
expanded-JSON fixtures.

## The wire contract

The single coupling to `agda-deps` is the **v2 `graph.json` schema** (expanded
form) plus `nodeKeyVersion`. `agda-deps` is the producer and source of truth;
`AgdaGraph.Schema` here is the consumer mirror and must track it. A
machine-readable JSON Schema for the expanded form lives in the producer repo
at `schema/graph-v2-expanded.schema.json` (the fixtures here validate against
it) — check it first when `AgdaGraph.Schema` drifts on a decode failure.

- **Schema version.** Payloads start with `"v": 2`; expanded form also emits
  `"schemaVersion": 2` and `"mode": "expanded"`. Refuse an unrecognised `v`.
- **`nodeKeyVersion`.** Tracks the node-*naming* convention (orthogonal to the
  schema version). `agda-explore` compares the JSON's value against
  `AgdaMcp.State.currentNodeKeyVersion` and rebuilds (live) / warns (preloaded)
  on a mismatch. **Cross-repo:** keep it in lock-step with the producer's
  `AgdaDeps.Deps.nodeKeyVersion` — independent literals in separate repos.
- **Provenance.** Optional `definitionEdgesProvenance :: [Provenance]`
  (`signature | body | module-local | with | unknown`), parallel to
  `definitionEdges`. The `module-local` tag (producer `nodeKeyVersion` 3,
  was `where` pre-v3 — the consumer still decodes the old tag) marks an
  anonymous-module-local target (a `where`-block helper or
  parameterised-section member). Absent in legacy JSON → every edge
  treated as `unknown`; `silhouette` falls back to fingerprint-equivalence
  with a stderr note.
- **Signatures.** Under `--with-signatures`, each definition carries an
  optional `"type"` string → `Definition.defSig`, consumed by `type_of`.

- **Module option escapes.** Optional top-level `moduleOptionEscapes`
  (`{ module → [flag] }`, ascending, escaping modules only, omitted when
  empty) → `ExpandedGraph.egModuleOptionEscapes`. Carries the file-level
  `{-# OPTIONS #-}` soundness escapes the producer kept (`--type-in-type`,
  `--no-positivity-check`, `--rewriting`, …). `AgdaGraph.Index.buildIndex`
  folds each module's flags into every enclosed def's `defUnsafe`, so the
  `search` / `roots` `unsafe=` audit (and transitive `unsafeDeps` taint)
  treat them exactly like the per-def `NON_TERMINATING` / `primTrustMe`
  escapes. Orthogonal to the per-def `unsafe` field and to `nodeKeyVersion`
  (an additive optional field — no bump).

## Cross-repo runtime link

Two tools shell out:

- **`agda-explore` → `agda-deps`.** Regenerates the graph by running
  `agda-deps` as a subprocess. `AgdaMcp.State.findBin` resolves it by
  precedence **`--agda-deps-bin` > `$AGDA_DEPS_BIN` > `$PATH`** (newest-mtime
  wins). Put `agda-deps` on `$PATH` (or pin it); preloaded mode (an existing
  `graph.json`) needs no `agda-deps`.
- **`agda-goals` → `agda`.** Drives `agda --interaction-json` over a pool of
  persistent subprocesses (`AgdaInteract.Session`); needs `agda` on `$PATH`.

## Module map

```
src/
  BuildInfo.hs                  Compile-time build identity (version + git
                                rev + date + GHC); in --version / status.
  BuildInfoTH.hs                TH git-revision splice (separate module for
                                the stage restriction).

  MainUnused.hs                 agda-unused entry point.
  AgdaUnused/
    Analysis.hs                 unused-import / def / open analysis.
    Config.hs                   YAML config loader for .agda-unused.yml.
    Json.hs                     --json-out emission.
    Source.hs                   snippet/source helpers.

  MainOptimization.hs           agda-optimization entry point.
  AgdaOptimization/
    CLI.hs                      subcommands table + runSubcommand dispatch
                                (add new analyses here); seeds each
                                subcommand's parseOptions from the YAML config.
    CLIParse.hs                 shared parseOptions helpers.
    FlagSpec.hs                 declarative per-flag specs → argv fold + YAML
                                overlay + help, one source per subcommand.
    Config.hs                   YAML loader for .agda-optimization.yml
                                (global: + one kebab-case section per cmd).
    Report.hs                   GlobalOpts, OutFormat, emitJsonReport.
    Motif.hs ... Strata.hs      the analyses (see overview above).
    TermCluster.hs              AST subterm fingerprint clusters
                                (reads definitionSubtermHashes).
    ConceptBundle.hs            Apriori over signature-provenance edges.
    FamilyFilter.hs             forced-by-elaborator suppressor; imported by
                                Basket + ConceptBundle.
    Common.hs                   shared name/graph helpers.
    Condense.hs                 shared SCC condensation.
    UnionFind.hs                shared path-light union-find.

  MainGoals.hs                  agda-goals entry point.
  AgdaGoals/
    Protocol.hs                 thin re-export of AgdaGraph.Interaction.Protocol.
    Driver.hs                   batch driver over a POOL of persistent
                                Sessions (runPooled work-stealing queue,
                                respawn-on-poison; runSerial for -N1). Results
                                reassembled in input order.
    Canon.hs                    thin re-export of AgdaGraph.GoalCanon.
    Bucket.hs                   hash-bucketing of canonical goals.
    Config.hs                   YAML config loader for .agda-goals.yml.

  MainMcp.hs                    agda-explore entry point.
  AgdaMcp/
    Config.hs                   YAML loader for .agda-explore.yml + the Opts
                                record the CLI parser fills.
    Rpc.hs                      newline-delimited JSON-RPC-over-stdio.
    State.hs                    Config + loaded snapshot + live regeneration:
                                ensureFresh/forceRebuild spawn agda-deps and
                                hot-swap the Index; binary discovery; fsnotify
                                watcher with poll fallback; warmStart (reuse
                                last run's per-entry graphs, mtime-diff to
                                re-run only changed entries); cold-start
                                fallback (ssColdError); the interaction-session
                                registry (ssSessions).
    Query.hs                    pure point queries over Index.
    Tools.hs                    MCP lifecycle + read-side tool catalogue +
                                tools/call dispatch; `unused` shells to
                                agda-unused; appends interactTools (gated on
                                --enable-interact).
    ToolDef.hs                  shared Tool/ToolRunner record + schema builders
                                + arg accessors (shared by Tools.hs and
                                AgdaInteract.Tools, no cycle).
    Inspect.hs                  opt-in localhost web inspector (--inspect):
                                hand-rolled HTTP + SSE server + broadcast bus
                                (unbounded TChan + bounded ring) + the
                                self-contained page. emitInspect is a no-op
                                when off; never writes stdout; each connection
                                leads with a `server` identity frame. Imports
                                no project module (so State can hold the hub
                                without a cycle).
    Control.hs                  opt-in localhost control endpoint
                                (--control-port, needs --enable-interact):
                                GET /check?file=… and GET /repair?file=…
                                (diff-only) run the same runners as the `check`
                                / `repair` tools (MainMcp passes them as plain
                                callbacks — imports no project module, no
                                cycle); 503 while busy; writes the bound port
                                to <out-dir>/control-port (removed on
                                shutdown). Serves the plugin's PostToolUse
                                hook.

  AgdaInteract/                 Write-side interaction bridge (agda-explore
                                only; the long-lived agda session model).
    Session.hs                  long-lived `agda --interaction-json`
                                subprocess: prompt-delimited reply bursts,
                                timeout→poison, reader/stderr threads.
    Registry.hs                 SessionEntry registry value + per-session
                                goal-id state (kept out of Session).
    GoalId.hs                   client goal ids (g0,g1,…) keyed by hole
                                char-offset (syncGoals): an id survives a
                                reload only while the hole's offset is
                                unchanged, else clients re-read (match line:col).
    Guard.hs                    no-postulate / no-escape-hatch guard on
                                give/refine input; checkFileInput is the
                                whole-file variant (give_file / new_module /
                                promote), tolerating benign module pragmas.
    Literate.hs                 .lagda.md code-block detection + isInsideCode
                                splice guard.
    Edit.hs                     splice / multi-range splice / clause re-indent
                                / unified-diff helpers (Data.Text char offsets).
    Tools.hs                    interaction tool runners + session registry +
                                interactTools list. give_many fills N goals
                                against one live session → one atomic diff.
                                stage/promote/discard build a def in an
                                ephemeral .agda-explore/scratch/ module, then
                                splice + re-validate the whole real target
                                (promote validates a renamed temp copy to dodge
                                AmbiguousTopLevelModuleName). applyOrDiff is the
                                shared finisher (write:true → write + reload +
                                refreshed goals, else diff). check reports full
                                diagnostics; give_file authors whole-file/append
                                content; new_module scaffolds + resolves imports
                                off the index; construct runs a step batch;
                                lemmas runs queryFindLemma off a live goal type.
                                Also hosts the `repair` loop driver (runRepair /
                                repairLoop / firstWorking / accepts) so it can
                                reuse loadRenamedTemp/applyOrDiff/interpretCheck
                                without exporting them (no cycle).

  AgdaRepair/                   Graph-backed, spec-preserving repair loop for
                                the `repair` tool (see FixLoop.md). Pure logic;
                                the IO driver lives in AgdaInteract.Tools.
    Diagnostic.hs               PURE classifier: agda's rendered errors →
                                [Diagnostic] (DScope/DParse/DIncomplete/DRefuse).
                                Parses NotInScope / NoParseFor* / error tags;
                                lenient (unknown → DRefuse); tested in test/Spec.hs.
    Strategy.hs                 PURE candidate generation off a base-name index
                                (Env) built once from ldRealDefs: imports via
                                defModule (constructor → datatype-parent module;
                                defOrigin flags external overlay defs); typos via
                                edit distance over in-scope + graph names. No
                                graph → typo-only.
    Edit.hs                     PURE comment/string/signature-safe edits
                                (EAddImport / ERename); `signatures` gives the
                                spec-preservation invariant the loop asserts.

src-agda-graph/AgdaGraph/       Shared library.
  Interaction/Protocol.hs       FromJSON mirror of the --interaction-json reply
                                wire shape (shared by agda-goals + the bridge).
  Interaction/Iotcm.hs          pure IOTCM command-string builders.
  Schema.hs                     FromJSON / NFData mirror of the expanded JSON;
                                consumer source of truth for the wire shape.
  Index.hs                      strict in-memory rep: Vector Definition,
                                fwd/rev IntMap IntSet, topoSort, descendants,
                                ancestors, longestPathDP, idxEdgeProvenance.
  GoalCanon.hs                  goal-type canonicaliser + vendored-Murmur64
                                hashString + find_lemma retrieval tokens
                                (matchTokens qualifier-strip/vocab-keep,
                                nameTokens, algebraic shapeTokens,
                                weightedCoverage).
  WL.hs                         Weisfeiler–Leman refinement / hashing /
                                fingerprints / weighted Jaccard.
  Similarity.hs                 shared structural-similarity cores so
                                silhouette / term-cluster / similar_* agree by
                                construction.
  Union.hs                      union of per-entry expanded graphs (multi-entry
                                and overlay federation; first graph wins on key
                                collision).
  Glob.hs                       tiny hand-rolled glob matcher (**/*/?), shared
                                by agda-unused --exclude and agda-explore
                                coverage-ignore.

scripts/
  fiedler_helper.py             SciPy λ₂ / Fiedler-vector helper for
                                AgdaOptimization.Fiedler (stdin → stdout).
  build-stdlib-graph.sh         build a reusable overlay graph (e.g. agda-stdlib)
                                for agda-explore --overlay-graph.
                                Needs `pip install scipy numpy`.

plugin/                         Claude Code plugin: agda-explore MCP server +
                                skill + two Agda agents.
```

## Hard-won gotchas (don't revert)

- **`AgdaGraph.Schema` is the consumer source of truth for the wire shape.**
  It mirrors the producer's v2 expanded JSON — update it in step when
  `agda-deps` changes the schema, and refuse unknown `v`.

- **`nodeKeyVersion` spans repos.** Bump
  `AgdaMcp.State.currentNodeKeyVersion` whenever the producer's
  `AgdaDeps.Deps.nodeKeyVersion` changes (independent literals, separate
  repos). The daemon rebuilds (live) / warns (preloaded) on `loaded < current`;
  a stale literal silently keeps a stale cache.

- **`hashString` is vendored Murmur64.**
  `AgdaGraph.GoalCanon.hashString = asWord64 . hash64` (`murmur-hash`) is
  byte-for-byte Agda's `Agda.Utils.Hash.hashString`, keeping the repo
  Agda-free while bucket hashes stay cross-referenceable with the producer's
  `hashQName`. Don't add an `Agda` dep for this.

- **Multicore + determinism.** `agda-unused` and `agda-optimization` build
  `-with-rtsopts=-N`. Determinism is an acceptance test: output byte-identical
  between `+RTS -N1` and `-NK` (human **and** `--json`) on `test/deps.json`.
  New parallelism must force to NF (`rdeepseq`) and use an order-preserving
  reduction (`parMap` keeps list order; `Map.unionsWith (+)` with an
  associative-commutative op).

- **`fiedler` is the only subcommand that shells out** — to
  `scripts/fiedler_helper.py`. Helper precedence: `--helper=PATH` >
  `$AGDA_OPTIMIZATION_HELPER` > the cabal `data-files` path. Missing-SciPy
  exits `3`, missing-helper exits `2` (distinct clean diagnostics). Reuse this
  pattern for any new shell-out; don't add a second mechanism.

- **Power-iteration orientation in `gravity`.** Per-theorem PPR walks
  **forward** from the seed, so the matrix-vector loop is called with
  `(idxReverse, outForward)`. The opposite orientation silently collapses PPR
  to a delta on the seed. Untested — eyeball-check mass flows from a
  high-degree theorem to a deep usee, and document the orientation at the call
  site.

- **Config layer (YAML).** Each executable reads its config via its own
  `Config.hs`. Discovery: `--config=PATH` > `$AGDA_<BIN>_CONFIG` >
  `./.agda-<bin>.yml` (or `.yaml`) > nearest ancestor with a `*.agda-lib`.
  Merge order: **defaults → config → CLI**. Keys are kebab-case flag mirrors;
  `agda-optimization` nests per-subcommand sections (`load-bearing`, not
  `loadBearing`). A stderr breadcrumb fires on apply (suppressed by
  `--json-out` / `--json`).

- **`BuildInfo` is split for the TH stage restriction.** The git-revision
  splice lives in `BuildInfoTH`; `BuildInfo` does the splice + CPP
  `__DATE__`/`__TIME__`. Both are `agda-explore`-only. The reliable "newer
  build?" discriminator is the binary's *mtime* (`AgdaMcp.State.binaryIdent`),
  not the fingerprint (whose `built` date freezes if `BuildInfo` isn't
  recompiled).

- **The `--interaction-json` protocol isn't version-stable, so it is pinned by
  golden fixtures.** `test/interaction/<agda-version>/*.jsonl` are real `agda`
  transcripts; the offline `interaction-spec` suite replays them through
  `AgdaGraph.Interaction.Protocol` (CI never runs `agda`). An Agda bump that
  changes the wire shape fails it — regenerate with
  `bash test/interaction/regen.sh`. Keep the parser **lenient** (unknown
  `kind` → `Other*`, never a decode crash).

- **Interaction bursts are delimited by the `JSON> ` prompt, not line
  structure.** Agda prints the prompt without a trailing newline, so it glues
  onto the next burst's first reply. `AgdaInteract.Session`'s reader breaks on
  the prompt prefix AND a trailing bare `JSON> ` (a line reader would block on
  the latter). One prompt = one command settled. Don't "simplify" to
  `hGetLine`.

- **Interaction positions are 1-based *character* offsets into the full file**
  (prose included for `.lagda.md`), so literate range-mapping is the identity
  and splicing uses `Data.Text` char indexing (`AgdaInteract.Edit`), never
  bytes (`→` is one char, three bytes). `AgdaInteract.Literate.isInsideCode`
  refuses splices into prose.

- **The write-side bridge enforces a hard zero-axiom contract and by default
  does not write.** `AgdaInteract.Guard.checkGiveInput` rejects `postulate` /
  termination-coverage-`OPTIONS` pragmas / escape identifiers before the term
  reaches Agda (`checkFileInput` is the whole-file variant). Mutators return a
  diff and mark the session dirty (next query reloads from unchanged disk).
  **`write:true`** (via `applyOrDiff`) instead writes + reloads + returns the
  refreshed goals in one round-trip. `auto` runs Mimer via
  `Cmd_autoOne Rewrite InteractionId Range String` — the leading `Rewrite` is
  mandatory (omit it and Agda "cannot read"); the trailing string carries
  Mimer options (`-t <secs>` bounds the search, verified on Agda 2.9) **and
  lemma hints** as space-separated identifiers. Plain Mimer won't try an
  in-scope lemma at any budget, so `auto`/`auto_all` seed the top
  `find_lemma` candidates (`Query.goalHintNames`) as hints. An
  unknown/out-of-scope or *qualified* hint aborts the whole call (Agda 2.9),
  so hints must be in-scope short names tried ONE AT A TIME — scope
  resolution is instant, so a bad hint fails before searching. Don't batch.

- **`repair`'s three invariants are enforced structurally — don't relax them**
  (see `FixLoop.md`). (1) *Spec preservation*: `AgdaRepair.Edit.renameInBody`
  never edits a signature/import/module line or a comment/string, and
  `firstWorking` rejects any candidate whose `signatures` set changed — so a
  repair can't rewrite a theorem. (2) *Zero axioms*: every candidate goes through
  `checkFileInput` first. (3) *Monotone termination*: `accepts` takes a candidate
  only if it resolves the targeted name without raising the error count — imports
  only grow scope, so it can't oscillate. Semantic errors and open goals are
  refused/routed, never faked. And `AgdaRepair.Diagnostic.parseErrorNames` must
  read the expression on the line(s) *after* `Could not parse …` — dropping an
  operator import yields a `NoParseFor*`, not a `NotInScope`.

- **A successful Mimer probe solves the meta in Agda's *session* state, so
  anything that runs `Cmd_autoOne` without writing must mark the session
  dirty.** Both the check-time `auto-hints` probe and `auto_all` do this
  (the next interaction reloads from unchanged disk); dropping the
  `markSessionDirty` makes later goal queries disagree with the file.
  `auto_all` accumulates its edits in ORIGINAL-text offsets (in-session
  gives never move the disk file), merged by `spliceRanges` like
  `give_many`/`construct`.

- **`agda-goals` and the bridge share one session driver
  (`AgdaInteract.Session`), which must stay goal-id-free.** Per-session
  goal-id state lives in `AgdaInteract.Registry` (`SessionEntry`), so
  `agda-goals` reuses the bare transport without `AgdaInteract.GoalId`.
  `agda-goals` drives a POOL (`runDriverBatch` → `runPooled`; `runSerial` at
  `-N1`); goal extraction is byte-identical across pool sizes (results
  reassembled in input order). That byte-identity (`-N1` vs `-NK`, human +
  `--format=json`) is the acceptance test — re-check it if you touch the
  driver, pool, or reader.

- **Cold start must degrade, not go dark.** Serve-stale only protects you
  after one good build. On a first build that emits no graph,
  `ensureFresh`/`firstBuild` records an actionable diagnostic in `ssColdError`
  and every tool + `status` serve it (not the raw producer exit) while the
  background worker retries, so the daemon self-heals. Don't make the cold
  path a synchronous per-query rebuild (it blocks the stdio loop on a
  minutes-long run).

- **`--keep-going` and `--incremental` are mutually exclusive at the
  producer.** `agda-deps` disables its fragment cache under `--keep-going`, so
  `buildBaseArgs` picks one: tolerant `--keep-going` (partial graph on error)
  by default, or `--strict-producer` (`cfgStrictProducer`), which drops it for
  `--incremental` + a shared `--cache-dir` (race-free: builds are serialised;
  needs Agda >= 2.9). Orthogonally, `--require-well-typed`
  (`cfgRequireWellTyped`) makes `commitOrKeep` withhold a rebuild with failed
  modules while a prior snapshot exists, but always commit on cold start.
  Holes aren't failures (tagged `Hole`, never `failedModules`), so hole-filling
  still refreshes. Both default off; `--strict-producer` subsumes
  `--require-well-typed`.

- **Warm cold-start reuses the last run's on-disk graphs (`warmStart`).**
  Called at daemon init *after* `startWatcher`, it decodes the per-entry graphs
  the previous run left in `cfgOutDir/entry-i/deps.json`, seeds the snapshot +
  `ssEntryCache`, and uses each graph's mtime as its last-built time: a newer
  closure file re-runs that entry; a source newer than the whole prior build
  and in no closure becomes a Stage-B ad-hoc entry. Changed/added sets feed the
  serve-stale path's selective (`chooseReRun`) background refresh, so the first
  query is instant. Conservative: all entries must decode, else it serves the
  last union (`cfgGraphPath`) and forces a full rebuild. Never blocks on
  `agda-deps` (reads files only). A no-op outside live + auto-rebuild +
  incremental + multi-entry. Don't move it before `startWatcher` (the
  incremental path gates on `isWatching`).

## v2 graph.json schema (consumer view)

This repo only ingests the **expanded** form. See the `agda-deps` repo for the
full schema (including the `packed` form and `--lazy` split-file layout, used
only by the HTML views). Consumer essentials are in
[The wire contract](#the-wire-contract); the typed mirror is `AgdaGraph.Schema`.
