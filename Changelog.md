# Changelog

## Unreleased

### I7 resolved — `agda-optimization` `-N` crash root-caused to a GHC 9.12.x runtime bug (2026-07-22)

- The multicore `agda-optimization` SIGSEGV / `ARR_WORDS`/`TSO object entered!` faults (I7) are a **GHC 9.12.x parallel-runtime heap-corruption bug**, not an application defect: no unsafe code on the parallel paths, the fault needs ≥2 capabilities, is scale-gated (large live heap), and its rate is proportional to GC frequency. Bisection on the 278 MB Jolteon-FastBFT union graph (GHC 9.12.4): default `-N` `polyglot --json` ≈13%, `motif`/`load-bearing`/`gravity` ≈100%, `-N1` clean, `-qg` (serial GC) 100%, `-c` (compacting) 87%. **GHC 9.14.1 — the toolchain CI and the README already pin — is clean (0/N across every crasher), so building on the supported 9.14.x resolves it; no code change.**
- `-A64m` (large nursery) was rejected as the fix: it cuts GC count enough to mask the low-allocation subcommands (`polyglot`) but `motif`/`load-bearing`/`gravity` still crash ≈90% under it. The only clean workaround for anyone stuck on GHC 9.12.x is `+RTS -N1` (single-capability, deterministic, byte-identical output).

### `--show-defaults`: emit a starter config for every binary (2026-07-22)

- All five executables gain `--show-defaults`: print a documented `.agda-<tool>.yml` populated with the current defaults to stdout, then exit (before any config discovery / graph build, so it works from anywhere). Redirect it to bootstrap a config — `agda-unused --show-defaults > .agda-unused.yml`.
- The four single-command tools bind every emitted value to their defaults record (no drift); scalar keys are active and optional path/list keys are commented examples, so the dump is a no-op overlay saved verbatim. `agda-optimization` emits a `global:` + per-subcommand skeleton whose keys come from each subcommand's `flagSpecs` (defaults noted in each key's description). Offline suite pins the `agda-auto` dump: it parses and round-trips to `defaultOpts`.

### `agda-auto`: batch hole-filling CLI (2026-07-22)

- New fifth executable `agda-auto`: runs `agda-explore`'s Mimer + graph-hint ladder (`AgdaInteract.Tools.autoAllCore`, split out of the `auto_all` path — the MCP rendering stays byte-identical) over every open hole in a file, from the terminal. Diff by default; `--write` applies (Agda-validated, zero-axiom). Needs `agda` on `$PATH`.
- Unsolved holes get a strippable, idempotent in-hole marker (`AgdaInteract.Annotate`, a block comment inside the hole) recording the goal type + in-scope lemmas to try (with import lines for out-of-scope ones); a later run reads those hints back and re-seeds them. `--no-annotate` disables.
- Project mode (directory / >1 file): serial sweep in module-dependency order (`AgdaGraph.Index.moduleDependencyOrder` — a module with open holes can't be imported, so a dependency is filled + written before its dependents load), aggregate footer, `--json` `{files, summary}` envelope, `--wall-budget N`. Exit `0`/`1`/`2` = none-open / holes-remain / error.
- Flags `--repair` (run the graph `repair` tool on a load failure, then re-probe), `--fixpoint` (with `--write`, re-sweep until a pass fills nothing new), `--ledger FILE` (one JSON line per goal). Config `.agda-auto.yml` / `$AGDA_AUTO_CONFIG`.
- MCP: `construct {op:auto, goal:"*", annotate:true}` now leaves the same markers (default off, so the write-tool surface is otherwise unchanged); found that Mimer does not read hole contents as a hint on Agda 2.8 (pinned by `test/interaction/2.8.0/auto-hole-content.jsonl`).

### Behavior-preserving simplification pass (2026-07-12)

- Repo-wide cleanup: dead code removed, duplication consolidated into shared homes.
- Fixed `LoadBearing.guessEntryModule` tie-break determinism; `isAgdaFile` now recognizes `.lagda.tree` / `.lagda.typ`.

### Write-tool catalogue reduction: constructor-style batchers (21 → 11) (2026-07-10)

- Folded the `--enable-interact` write-side tool catalogue from 21 to 11 via constructor-style batchers; no capability lost.
- `construct` subsumes give/refine/case_split/give_many/auto_all; `inspect` (new) subsumes goal_type/goal_context/infer/normalize; `scratch` (new) subsumes stage/promote/discard.
- Kept standalone: `load`, `goal_brief`, `auto`, `check`, `give_file`, `new_module`, `lemmas`, `repair`. New pure module `AgdaInteract.Batch` for the batcher vocabulary.

### Arena-feedback round 4: live-watch staleness delta + brief/path coverage (R16 + R17) (2026-07-10)

- `brief`/`path` now carry the closure-coverage footer (R17).
- Live-watch staleness flag: `ensureFresh` returns `Freshness` (Fresh/Rebuilding/BehindPending), flagging reads served behind an on-disk edit the watcher has not yet rebuilt (R16).

### Arena-feedback round 3: out-of-scope `auto` hints + carrier-aware lemma ranking (R19 + R20) (2026-07-10)

- `auto`/`auto_all` flag out-of-scope closing lemmas (suggest `open import`/`repair`) instead of a flat "no solution" (R19).
- Carrier-aware lemma ranking: carrier-module affinity tie-breaker (new shared `AgdaGraph.LemmaRank`); `goal` argument now accepts a JSON integer (R20).

### Transitive soundness taint on `roots` / `impact` (R12 follow-on) (2026-07-09)

- `roots`/`impact` flag transitive soundness taint: `Index.unsafeDeps` (escapes in a node's forward closure), `roots … unsafe=any|non-terminating|trustme` audit, and passive `⚠ soundness taint` banners.

### Producer follow-ups: `unsafe` audit (R12) + `renaming` alias resolution (R14) (2026-07-09)

- `unsafe` escapes: `Definition.defUnsafe`; `search unsafe=any|non-terminating|trustme` audit with `[unsafe: …]` tags (R12).
- `renaming` aliases: `ReExport.rxRenames`; `locate`/`type_of`/`search` resolve re-export aliases to their canonical def (R14).

### Arena-feedback round 2: staleness signals, graph identity, dead cycles, text search (2026-07-09)

- Partial-graph `# partial:` and source `# stale:` footers (stale now also fires in preloaded mode) (I6/R1).
- Graph identity hashes in `status` (`graph id: config=… content=…`); `agda-unused --kinds=dead` flags dead mutual-recursion cycles (R9/I5).
- Closure-coverage footer on callers/callees/impact/roots + `unsearched_files` in the JSON envelope (R2).
- `search mode=text` (ripgrep over source) (R3); read-tool category tags (R7); `format:json` for `unused`.

### Arena-feedback fixes: false-100 similarity, recursive dead code, per-answer coverage (2026-07-09)

- `similar_types`/`find_lemma` cap the score at 99% when rendered signatures differ (I4).
- `agda-unused --kinds=dead` flags self-recursive dead defs (I5).
- `search` per-answer closure-coverage footer + `unsearched_files` (R2); advisor blurbs pointing to `search` first (R7).

### `agda-explore`: trim tool response bytes (2026-07-08)

- Trimmed read-tool response bytes (~−43%): shorter shared list lines (`L<line>`), qualifier-stripped `find_lemma`/`lemmas` conclusions, shorter `type_of`/`brief`/mutator preambles.

### `agda-explore`: goal→lemma retrieval overhaul + hint-guided `auto` (2026-07-08)

- `find_lemma`/`lemmas` goal-mode ranking reworked (qualifier-strip, operator-weighted coverage, algebraic shape tokens): 2/10 → 10/10 in-top-25.
- `auto`/`auto_all` are hint-guided: seed the top graph-ranked lemma names as one-at-a-time Mimer hints; new `timeout`/`hints` args.

### `agda-explore`: trim the always-on tool catalogue (2026-07-05)

- Rewrote all 35 tool descriptions to ≤2 sentences (description bytes −61% read-only); no renames or schema-structure changes.

### `agda-explore`: orientation bundles, stdlib federation, JSON output, coverage warning, one-shot CLI (2026-07-05)

- Orientation bundles `brief` (def) and `goal_brief` (hole).
- Stdlib graph federation via `--overlay-graph FILE` (repeatable); overlay defs tagged `[external: <label>]`, project wins key collisions.
- `format: json` on `search`/`callers`/`callees`; closure-coverage warning (`coverage-ignore:` globs).
- One-shot CLI `agda-explore query <tool> key=value… [--json]` (no daemon).

### `agda-explore`: drive agents toward the write-side bridge (2026-07-05)

- `check` next-step footer + speculative Mimer hints on `check`.
- New `auto_all` tool (Mimer over every open goal in one call).
- Loop-closing plugin hooks (PostToolUse validate Agda edits / PreToolUse grep→graph); `--control-port` localhost `GET /check?file=…` endpoint.
- Tool-usage histogram in `status`.

### `agda-explore`: opt-in strict producer + well-typed-only promotion (2026-07-01)

- `--strict-producer` (drops `--keep-going`, enables the `--incremental` cache) and `--require-well-typed` (withhold a rebuild with failed modules while a prior snapshot exists); both default off, moot in preloaded mode.

### Adopt producer `nodeKeyVersion` 3 — anonymous-module lifting + `module-local` provenance (2026-06-30)

- Track producer nodeKeyVersion 3: new `module-local` provenance tag (legacy `where` kept), `currentNodeKeyVersion` 2→3, re-keyed local-helper detection off the `@<line>` disambiguator.

### Write-side bridge: file authoring + structured validation (2026-06-16)

- New write tools: `check` (structured diagnostics + goals), `give_file` (author whole file/append), `new_module` (scaffold with graph-resolved imports), `construct` (batch steps), `lemmas`; `write:true` on every mutator applies + reloads + returns refreshed goals.

### Live web inspector (`--inspect`) (2026-06-15)

- Opt-in localhost web inspector (`--inspect`): live activity feed + editing view over HTTP+SSE; read-only side channel, never writes JSON-RPC stdout, probes upward on port clash.

### Staging-buffer include-path fix (2026-06-15)

- `stage`/`promote` now load on projects with an `.agda-lib` (`loadIncludes` prepends the loaded file's own dir for the scratch and `.validate` dirs).

### Bridge batching + staging, cold-start fallback, parallel goals (2026-06-13)

- `agda-explore`: `auto` now works (correct `Cmd_autoOne Rewrite …` invocation); `give_many` (fill several goals in one session); `stage`/`promote`/`discard` (author a new def in isolation); cold-start fallback caches the first-build failure and self-heals.
- `agda-optimization`: `term-cluster` ranking flags (`--sort=`, `--min-mean-depth=N`).
- `agda-goals`: parallel sessions over a work-stealing pool (byte-identical across `-N`).
- Packed graph form refused with actionable guidance.

### Write-side interaction bridge for `agda-explore` (2026-06-12)

- Opt-in write surface (`--enable-interact`) over a long-lived `agda --interaction-json` subprocess.
- read: `load`, `goal_type`, `goal_context`, `infer`, `normalize`; write (Agda-validated): `case_split`, `refine`, `give` (unified diff), `auto` (Mimer); hard zero-axiom guard; `.lagda.md` first-class.
- Protocol parser + IOTCM builders promoted to the `agda-graph` library; `agda-goals` migrated onto the shared session driver; new offline `interaction-spec` suite replays golden transcripts.

### Agent-usage-analysis recommendations (2026-06-12)

- `agda-explore`: serve-stale + async rebuild; fail-fast `type_of`; multi-entry `entries:` roots (in-process union); universal unique-candidate auto-resolution; new `find_lemma` tool; query telemetry to `query-log.jsonl`.
- `agda-unused`: never silently return 0; inliner-gap confidence tagging; `--group-by=dir|file|kind` + `--count-only`.

### Split out of `agda-deps` (2026-06-10)

- Factored `agda-graph-explorer` out of `agda-deps`: the `agda-graph` library + `agda-unused`/`agda-optimization`/`agda-goals`/`agda-explore` + `plugin/`. Links no Agda (`hashString` vendored from Murmur64).
