# Changelog

## Unreleased

### Field report on the argument checks: the dead-check net, and four new producer signals (2026-09-04)

Everything here comes from the first run of the `arg-*` checks over a real
6 000-definition proof development, and the numbers are measured on that
corpus and its graph.

- **Fixed: the `defined-dead` false-positive net was structurally disabled for
  module-local and mixfix names — 42 of 157 findings (27%) were false
  positives it should have caught.** `definedButUnused` suppresses a dead
  verdict when the name is mentioned in another file, or more than twice in its
  own; both lookups used the producer's short name *verbatim*, including the
  `@<line>` disambiguator it appends to `where`/anonymous-module helpers.
  `PreEnoughV?@240` appears in no source file, so the net answered "never
  mentioned" for **every** module-local definition (87 of 157 here). Mixfix
  names missed the same way: `_:InitTC?` is written `𝔹 :InitTC?` at its call
  sites. Both spellings are now tried (`AgdaGraph.Index.stripLineTag` for the
  tag, name parts for the mixfix form, all parts required in one file so a
  one-part operator like `_+_` is not suppressed by the `+` that appears
  everywhere), and the whole-name spelling is still tried first — it does occur
  verbatim in a `using (…)` list. Pure suppression: nothing new appears.
- **`arg-removable` / `arg-erasable` consume four new producer signals** —
  `syntacticArity`, `binders[i].type`, `occursInBody` and `partiallyApplied`
  (`agda-deps` round 5; all optional, so older graphs behave as before). Each
  is an *actionability* fact Agda knows and the report cannot re-derive:
  - a position past the signature line is **labelled, not dropped**. It exists
    because a type in the signature unfolds, so the verdict is still true — a
    premise the proof never inspects means the statement could be strengthened
    — but the edit target is that other definition. 54 of the 133
    `arg-removable` findings here are in that class, and the earlier plan to
    drop them would have deleted true positives.
  - an **unnamed** binder now renders its *type* (`argument 5 (GST ≤ s) of 11`
    instead of `argument 5 of 11`). 63 of the 94 mapped removable positions on
    this corpus are unnamed explicit binders, because the project writes
    premises bullet-style.
  - a definition **used unsaturated** cannot lose a binder at all (its arity is
    part of its interface: `Eager ∩¹ AfterT t` needs `AfterT t` unary), and an
    argument **passed on to a callee** that discards it needs that callee
    edited too.
  - without `--erasure` in force (new top-level `moduleEffectiveOptions`), the
    `@0` that `arg-erasable` suggests is a syntax error, and the finding says
    so. 1 259 findings on this corpus were un-appliable as configured.
- **`--kinds=all` no longer includes `arg-erasable`.** It fires on roughly a
  quarter of all definitions (1 328 of 1 433 `argUsage` rows here, 41% of the
  whole report) and is dominated by level binders, so it swamped a triage run;
  ask for it by name or via `args`. `--kinds=all` went from 3 028 findings to
  1 729 on this corpus, without losing a kind.
- **New `--min-confidence=low|high`** (config `min-confidence:`), and
  confidence is **re-derived from actionability**: `High` only when the edit
  the finding names can be made as stated — contained blast radius, every
  position on the signature line, not partially applied, and not `@0` advice in
  a module without `--erasure`. A callee edit is a *cost*, not a doubt, so it
  does not grade down. `--min-confidence=high` takes `arg-removable` from 133
  to 41 here.
- **Confidence is printed in plain text** (`[low confidence]`), which the
  Haddock had claimed for some time while only `--format=json` carried it. It
  now has one spelling: the two notes that said "low confidence:" in prose no
  longer do.
- **`--format=json` gained the finding's `note`** — the prose the human line
  carries, including the blast radius (`2 caller(s) here, 5 other module(s)`)
  a consumer costs a refactor from. JSON was the machine format and the only
  one without it. The `arguments` object also gained `unwritten`, `nonLocal`
  and `partiallyApplied`.
- **Fixed: `unused-in-using` — a DEFAULT kind, and this tool's namesake
  check — could never fire.** Usage was measured against `bodyTokens`, which
  covers the whole file *including* the import block, so every symbol in a
  `using (…)` clause was credited by that clause itself. Verified on a
  two-symbol minimal case with the released binary (`open import Lib using
  (wanted; neverUsed)`, only `wanted` used → `# total: 0 finding(s)`) and by
  a 6 000-definition corpus that reported zero `unused-in-using` findings in
  its entire history. The import-usage checks now search a haystack with the
  import lines removed (`AgdaUnused.Source.bodyTokensOutside`, numbering
  lines exactly as `scanImports` does). That corpus now reports 3 findings,
  all verified true positives — two `IO.Base` symbols and one lemma whose
  names appear nowhere but their own import lines. The module header had
  claimed the analyser "ignores the per-import line itself"; it did not.
- **Fixed: a multi-line `{- … -}` comment shifted every reported line below
  it.** `scanImports` numbers `ilLine` off `lines . stripBlock`, and
  `stripBlock` dropped the comment's own newlines — an import three lines
  under a three-line comment was reported three lines too high (pinned by a
  fixture). Harmless while nothing consumed those numbers; not harmless now
  that `unused-in-using` fires and points a reader at a line. `stripBlock`
  now keeps newlines, which diverges deliberately from the
  `AgdaDeps.Precompute` copy it was taken from.
- **A mixfix name in a `using` clause is credited by its parts.**
  `using (_∷_)` is written whole but applied as `x ∷ xs`, so requiring the
  whole spelling in the body would report a used import as unused —
  a false positive newly reachable now that the kind fires at all.
- **`unused-blanket-open`'s source-side credit is normalised too**
  (`mentionedInTokens`): a re-exported name is very often line-tagged or
  mixfix — 790 of 1549 distinct re-export shorts on the measured corpus —
  and neither spelling occurs verbatim in a body, so a plain set
  intersection lost the credit and flagged an import the file does use.
  Yield was one finding of 137 (`Running/Proc.agda`, which uses `Type`,
  `Σ` and `L.∷ʳ` from its `open import Prelude`): the two graph-side credits
  already carry almost everything, and the source fallback only matters when
  the underlying definition was dropped by `--no-externals`.
- **New `--group-by=premise`**: buckets an argument finding by the head symbol
  of each flagged position's *type*, so "which hypotheses has this development
  stopped using" is one row per family instead of one line per lemma. On the
  measured corpus the 20 high-confidence `arg-removable` findings collapse to
  `Reachable 5`, `AwaitingGS 4`, `≥ 3`, `GlobalState 2`, `≤ 2`, … — the report's
  item 7 (its most-valued output) and the clustering half of its FP-8, without
  a new kind and without keying on binder names, which would be one project's
  convention dressed up as an analysis. A finding touching two families counts
  under both, so rows can sum above the total.
- **Fixed: `AgdaGraph.GoalCanon.flattenShape` did not know Agda's instance
  brackets.** `⦃ … ⦄` was not in its bracket sets, so an instance argument's
  contents stayed at depth 0 and the bracket itself read as a top-level
  operator — `headSymbol` answered `⦃` for any goal or premise carrying one
  (`Reachable {a} (…) ⦃ Init s ⦄ s`) instead of `Reachable`. That is the
  shared "top-level relation or type constructor" the lemma ranker keys
  conclusions on, so the head-symbol strategies were mis-firing on every
  instance-carrying goal too.
- **`partiallyApplied` only blocks an EXPLICIT position.** An unsaturated
  reference pins the order of the explicit arguments, so deleting one shifts
  every call site's list; a hidden position is never written at a call site and
  Agda re-solves it, so its removal is invisible. Measured on a rebuilt graph:
  the unscoped rule was burying `Enumeration.enumProof`'s `⦃ Q ⁇¹ ⦄`, one of
  the two findings the field report hand-verified as genuine, on a definition
  that *is* passed unsaturated (`return (enumProof enum allQ)`).
  High-confidence `arg-removable` findings 18 → 20.
- **Measured on a graph rebuilt with the round-5 producer** (same entry, same
  5818 definitions): defs with a `removable` verdict 139 → 122, positions
  173 → 150, `arg-removable` findings 132 → 115, and at
  `--min-confidence=high` 40 → 20. The 17 definitions the producer's
  solvability guard dropped are the field report's false-positive taxonomy by
  name — `Prelude.Init.typeOf` (its FP-7) and `AfterT` / `BeforeT` / `Between`
  / `WithinNow` (its FP-5). All 69 unnamed removable positions now carry a
  type, 55 of 150 positions are flagged as not on the signature line, 104 of
  150 need a callee edit, and zero modules enable `--erasure`.
- **The PostToolUse hook's `/unused` route is narrowed to `arg-removable`.**
  It ran `unused kinds=args`, so on a project without `--erasure` every
  injection could carry `@0` advice that is a syntax error there — and
  `arg-erasable` fires on roughly a quarter of all definitions. A hook lands
  in every edit's turn, so a kind that is usually noise does not belong on
  that route; `unused kinds=args` is still one MCP call away. The section
  header now names the narrowed kind, and the hook's comment points at the
  per-finding confidence and the note that says what stands in the way of the
  edit.
- **Fixed: `duplicate-using` flagged two opens that differ only in
  `public`-ness.** Merging them would change the file's re-export surface, so
  they are not consolidation candidates; `ilPublic` is part of the bucket key.
- **`defined-dead` says what it cannot see.** The note now reads "verify first:
  a use in a `with` scrutinee leaves no edge" rather than leaving every finding
  looking equally solid.
- **Documentation: "the definition's own signature line" was wrong**, in this
  repo's `CLAUDE.md`, `--help`, `README.md`, the plugin skill and the MCP
  `unused` caveat. Argument indices address the definition's own *reduced*
  telescope, which can be **longer** than the signature line. That one word
  cost a careful reviewer two "false positives" that were sound verdicts.

### The post-edit hook reports unused arguments (2026-09-01)

- **The plugin's PostToolUse hook now runs `unused kinds=args` on a clean edit.** After a `✓` check of the edited file it appends that file's unused-argument findings; a `✗` still gets the diff-only `repair` suggestion instead, and a file with no findings injects nothing. This is the one defect class the edit→check loop was structurally blind to: Agda raises no warning for an argument a definition never uses, so a spare binder type-checks clean, and the verdict lives in the graph (the producer's `argUsage`) rather than in the compiler session.
- **New `GET /unused?file=…` control-endpoint route**, beside `/check` and `/repair`, wired to the same `unused` runner the MCP tool uses (`kinds=args`, scoped to the file). Being graph-side it reports the last `agda-deps` build, so findings can lag an edit by one rebuild — the report's own freshness footer says so when they do.
- **Fixed: an `agda-unused` ROOT naming a single file scanned nothing** and reported `# total: 0 finding(s)` for every kind — `discoverAgdaFiles` walked directories only, and a scan that reads no file also trips no "none of these matched the graph" guard. `agda-explore`'s `unused scope=FILE` (which validates the path against the graph first) has always been silently empty because of it. CI now asserts the single-file scope finds what the directory scan finds.
- **The `unused` tool's caveat is narrowed to the kinds requested.** A `kinds=args` call was spending a paragraph on the `dead` confidence tag and the `blanket`/`public` false positives; it now gets the two rules that govern acting on an argument finding (delete a `(with …)` set whole; indices count implicits — read against the definition's own reduced telescope, corrected 2026-09-04). An unrecognised kind token still selects every paragraph, so a new kind can't lose its advice.

### Unused arguments, never-projected fields, exact duplicates (2026-09-01)

- **`agda-unused` reports unused *arguments*.** Two kinds off the producer's new optional per-def `argUsage`: `arg-removable` (the binder and every call-site argument can go) and `arg-erasable` (used only in types — an `@0` candidate). Tokens `arg-removable`, `arg-erasable` and the alias `args`; not in the default set, because `arg-erasable` fires on ~26% of definitions against `arg-removable`'s ~1%. One finding per definition per verdict, with positions that must be deleted together named inline (`0 (with 1, 3)`) so a partial removal can't be suggested. Binders render as the signature spells them — `0 {a}`, `3 ⦃d⦄` — since an index alone misreads an implicit as the first explicit argument.
- **Confidence grades the deletion, not the analysis.** Agda's verdict is certain; deleting a binder changes the definition's *type*. `High` when the deletion is contained (private, or no cross-module user), `Low` when exported with outside users — an API break this tool cannot scope. The check reads the module's shared `usersClosure`, so it agrees with `defined-dead` and `public-no-downstream` about who uses a definition.
- **`--format=json` findings carry an `arguments` object** — `positions`, `arity`, `binders`, and for `arg-removable` a `delete` map from each position to the full set that must go with it. The prose note is no longer the only place the actionable payload lives.
- **New `field` kind** (`field-never-projected`): a record field whose projection is never applied. Reported instead of `defined-dead` for a `KProjection`, always `Low` — a no-eta record matched positionally reads its fields without the projection. Included in `dead`, so an existing `--kinds=dead` run doesn't silently lose findings. A record's edge to its own field and its enclosing module's automatic re-export are not counted as uses; without that the kind cannot fire at all (1,698 of agda-stdlib's 1,702 projections sit in a re-export row).
- **`agda-optimization term-cluster` gains an exact-duplicate tier** above the similarity clusters: definitions whose subterm-hash *multiset* is identical and whose signature matches. No threshold and no new flag — it reuses `--top-n` and `--max-defs`. A multiset has no shape, so it is evidence rather than proof; the signature match is what rules most false pairs out, and the report says so when the graph carries no signatures.
- **`scripts/verify-arg-removal.py`** (needs `agda`, offline, not CI): deletes each finding's whole `delete` set from the source signature and re-typechecks. Every positive is paired with a negative control — deleting an *unflagged* position must break the build, or the result is reported inconclusive rather than as a pass. Covers implicit/instance binders in a named group; explicit binders are skipped and counted, since the clause LHS would have to change too.

### Self-describing `agda-optimization` reports (2026-08-11)

- Every human-format report now ends with a **`## How to read this`** legend: what that analysis answers, what each section is, what every column means, and which row is worth acting on. A `--out FILE` report is usually read by someone who did not run it, and column names like `spanBet`, `IQR`, `recDeps` or `ε⁺+ε⁻` carried their meaning only in the source. All 19 subcommands are covered, plus `silhouette`'s no-provenance fallback (whose columns mean something different).
- New pure `AgdaOptimization.Legend` holds the text; `AgdaOptimization.Report.withHumanReport` is the single call every analysis' `OutHuman` branch goes through, so the legend lands inside the `--out` redirect and cannot be forgotten. Glosses are unwrapped strings wrapped at render time — adding a column needs no re-flowing. Degenerate one-line paths ("empty graph", "no term hashes", a `fiedler` helper failure) print no legend: there is no table there to explain.
- Global **`--explain` / `--no-explain`** (default on) and `explain:` under `global:` in `.agda-optimization.yml`. One switch for all 19 reports rather than a per-subcommand flag; `--json` is unaffected (that payload is self-describing already).
- The offline suite reads the subcommand list out of the committed `--help` golden and asserts every name has a legend that renders a heading, an `Act on:` line, and no line past 80 columns — so a new analysis can't ship an unexplained table.

### Zero-config bootstrap: one shared graph, every tool configured (2026-08-11)

- **`scripts/zero-config.py`** (stdlib-only) writes a config for every tool in one shot — the five `.agda-<tool>.yml` files plus a producer-side `.agda-deps.yml` — each seeded from that binary's own `--show-defaults` payload (so emitted defaults can't drift) and pointed at **one shared graph**, `.agda-deps/deps.json` (`--graph-dir DIR` moves it; the file name is the producer's). Include dirs come from the project's `*.agda-lib`, the entry from the root modules nobody imports (`--include` / `--entry` override; several roots become multi-entry, and past `MAX_AUTO_ENTRIES` it asks instead of guessing). Overlays are line-level edits over the payload text, so comments, key order and byte-identical re-runs all survive.
- Two deliberate asymmetries: **`agda-explore` is wired live** (`entries:` + `include:` + `out-dir:`, *not* `graph:`) — its graph path is `<out-dir>/deps.json`, so the daemon regenerates the shared file in place and the other four read what it published (pinning `graph:` would mean preloaded: no rebuilds, no watcher); **`agda-goals` gets no graph** (it drives `agda --interaction-json`), only `roots:` + `include-paths:`. `.agda-deps.yml` mirrors `AgdaMcp.State.buildBaseArgs`, so a hand build and a daemon rebuild agree on the graph's shape.
- The script **never builds the graph** — it verifies one, delegating to `agda-explore doctor --json` (graph decode, node-key version, the three capability probes, `agda-deps` / `agda` resolution, out-dir writability; a local decode+probe fallback when that binary is absent), cross-checks that every config resolves to the same file (including `--skip`ped and hand-edited ones), validates `.agda-deps.yml` through `agda-deps doctor`, and prints the exact build command. Exit 0 clean / 1 a check failed / 2 usage-environment error — a not-yet-built graph is a warning, matching `doctor`'s "exit 0 iff no ✗" rule. `--force`, `--dry-run`, `--json`, `--only` / `--skip`, `--bin-dir`.
- **`agda-optimization` gains a `graph:` key in its `global:` config section** (`AgdaOptimization.Config.globalGraph`), the config spelling of the input graph, so a configured project runs `agda-optimization motif` with no path. Precedence `--graph` > positional > config; config discovery now happens *before* the graph is resolved (a missing positional is only an error once the config has had its say).
- **Fixed:** `--graph FILE` used to swallow the first subcommand flag — `motif --graph g.json --top-n=2` reported the top 50 and printed a spurious "both --graph and a positional graph.json given" note, because the residual head was consumed as the positional path unconditionally. The graph is now taken from the residual only when it doesn't look like a flag (`takePositional`).

### UX/DX pass: version unification, actionable errors, canonical flag vocabulary (2026-07-23)

- **One version source.** New `AgdaGraph.Version` (off `Paths_agda_graph_explorer`) backs `--version` / `--numeric-version` on all five executables. `agda-unused` and `agda-goals` gain `--version` (previously had none); `agda-explore` and `agda-auto` stop hard-coding `0.1`; `plugin.json` tracks the cabal version. A CI step asserts cabal == `plugin.json` == every binary's `--numeric-version`.
- **Actionable graph-load errors.** `AgdaGraph.Schema.loadExpandedGraph` now: names the producer command on a missing file, sniffs a non-JSON payload before aeson, and wraps a bare decode error — while passing the parser's own diagnostics (wrong schema `v`, packed mode, parallel-array mismatch) through un-double-framed (factored as the pure, pinned `explainDecodeError`).
- **Canonical flag vocabulary.** Input graph is `--graph FILE` and output is `--format human|json` everywhere; the old spellings — `agda-unused`'s `--json=FILE` / `--json-out`, and `--json` on `agda-optimization` / `agda-auto` — stay as **permanent aliases** (no deprecation), with matching config-key aliases (canonical wins on collision). `--show-defaults` now emits the canonical keys. `agda-optimization` additionally accepts `--graph` (position-independent; wins over the positional path with a note).
- **Usage errors** print `<tool>: <error>` + `Try '<tool> --help'.` instead of dumping the full usage block; every `--help` documents that tool's exit codes. Exit codes themselves are unchanged (documented, not renumbered).
- **`agda-explore doctor`.** A one-shot environment preflight (`AgdaMcp.Doctor`, beside the `query` dispatch): binary identity, discovered config, mode, graph decode + node-key version + capability probes (signatures / provenance / subterm hashes, each naming the tools it gates), `agda-deps` / `agda` resolution, out-dir writability, overlays — one ✓/!/✗/– line each with a fix hint on every failure; `--json` envelope; exit 0 iff nothing failed. Read-only (never spawns a build).
- **Missing-agda hint.** A spawn failure now appends a shared one-line install/`--agda-bin` hint (`AgdaInteract.Session.agdaMissingHint`), so `agda-goals` / `agda-auto` / the bridge all guide the user identically.
- **Plugin launcher** warns once on stderr when `jq` / `curl` are absent (the hooks degrade silently otherwise); `plugin.json` bumped to the cabal version.
- **Tool tiering.** New `--tool-tier core|full` (YAML `tool-tier:`): `full` (default in the binary — no behaviour change) advertises every tool; `core` advertises only the measured-used subset (read tools + `load`/`goal_brief`/`inspect`/`check`/`repair`/`lemmas`), cutting the agent's per-choice decision-load. The plugin launcher now defaults to `--tool-tier core --enable-interact --control-port 7100` (so the edit hook runs a real warm `check`; opt out with `AGDA_EXPLORE_NO_INTERACT=1`). Every tool stays reachable via the one-shot `query` CLI regardless of tier. `tools/list` goldens pin both tiers. The plugin skill and PreToolUse routing message name the same core set.
- **Instrumentation.** `scripts/tool-usage-report.sh` turns a `query-log.jsonl` into a per-tool call-count / error-% / stale-% / p50-p95 table (jq only) — the evidence for tiering decisions without transcript archaeology.
- **Docs & contributor tooling.** README gains a fixture-first "Try it in 30 seconds", an `agda-deps` bootstrap, and install instructions; a root `justfile` encodes the build/test/smoke/determinism/quickstart/help-golden rituals; committed `--help` + `tools/list` goldens (`test/help/`) guard the CLI surface; working notes moved under `notes/`.

- **Shell completions.** `agda-optimization --completion-script=bash|zsh` prints a completion script (generated from the `FlagSpec` table + subcommand list via the new `AgdaGraph.Completion`, so it can't drift from the parser) covering all 19 subcommands and their flags. CI syntax-checks it and asserts every subcommand appears.

Follow-ups (not in this pass): (1) flipping the `--premise-select` / `--rank-idf` ranking defaults on for the plugin, gated on a fresh `agda-optimization hint-bench` measurement over a live stdlib-scale corpus (harness + strategies exist in `AgdaGraph.PremiseBench`); (2) migrating the four hand-rolled CLIs onto the shared `FlagSpec` — reassessed and deferred (see [Backlog.md](Backlog.md)): the byte-identical-`--help` acceptance conflicts with generated help for the bespoke usages, so the churn isn't justified now (the `--help` goldens + per-tool `--show-defaults` already cover the drift risk).

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
