# Changelog

## Unreleased

### Transitive soundness taint on `roots` / `impact` (R12 follow-on) (2026-07-09)

`search unsafe=` flagged only a def's *direct* escape. A theorem can carry no
escape itself yet transitively reach a `{-# NON_TERMINATING #-}` helper or a
`primTrustMe` body through its dependencies — invisible to a per-def audit.
This layers a reachability query over the already-adopted `unsafe` field (R12).
No new producer field; pure consumer-side. Tests in `test/Spec.hs`.

- **`AgdaGraph.Index.unsafeDeps`** — the directly-`unsafe` defs in a node's
  forward (uses) closure, excluding the node itself: the escapes it
  transitively *rests on*. O(V+E) via `descendants`; deterministic ascending
  order.
- **`roots … unsafe=any|non-terminating|trustme`** — a transitive soundness
  audit rooted at one theorem: the reachable escapes, each with the same
  witness chain `roots` already renders (`T → … → loops`). Overrides the
  postulate/primitive default; `kind`/`state` still narrow it; a bad value is
  rejected (`unsafeFilterError`). If the subject itself carries an escape, a
  self-note flags it (a def is not its own transitive dependency).
- **Passive `⚠ soundness taint` banners.** With no `unsafe=` filter, `roots`
  prepends a one-line banner naming the escapes the subject rests on (so it is
  never silent), and `impact` prepends one when the subject carries *or* rests
  on an escape — every dependent it lists transitively inherits it.

### Producer follow-ups: `unsafe` audit (R12) + `renaming` alias resolution (R14) (2026-07-09)

Consumer-side wiring for two graph fields `agda-deps` shipped 2026-07-09.
Both decode with empty defaults, so an older graph stays valid. Schema-decode
+ backward-compat tests in `test/Spec.hs`; determinism gates hold.

- **`unsafe` soundness escapes (R12).** `AgdaGraph.Schema.Definition` gains
  `defUnsafe :: ![Text]` (`.:? "unsafe" .!= []`; values `non-terminating` /
  `trustme`, the def's *direct* escapes, orthogonal to the 4-state `state`).
  `search` gains an `unsafe` filter — `unsafe=any` (with an empty `query`)
  enumerates every escape, an `agda --safe`-style audit that was grep-only
  before; `unsafe=non-terminating|trustme` narrows. The escape shows as an
  `[unsafe: …]` tag in list rows / the JSON `unsafe` field and as an
  `unsafe:` line in `locate`.
- **`renaming` re-export aliases (R14).** `AgdaGraph.Schema.ReExport` gains
  `rxRenames :: !(Map Text Text)` (`.:? "renames" .!= mempty`), an in-scope
  alias → canonical node-key. The daemon builds a host-qualified alias index
  (`ldAliases`) at load; `resolveDefNote` gains an alias tier so
  `locate`/`type_of`/… on `Reexports.combine` resolve to `Core.Base.merge`
  with an `is a renaming alias for` note, and `search combine` now surfaces
  the alias (`Reexports.combine → Core.Base.merge`) instead of silently
  returning only the unrelated real `Data.Fin.Base.combine` — the X1-style
  misleading case where the MCP was worse than reading source.

### Arena-feedback round 2: staleness signals, graph identity, dead cycles, text search (2026-07-09)

The [ToFix.md](ToFix.md) batch — the correctness + feature items from the
MCPBenchArena triage. Arena CI gate (G1–G4) re-verified green; the
`interaction-spec` suite (now including the dead-cycle cases) passes; the
`agda-unused` `-N1`/`-N4` byte-identity determinism test holds.

- **Partial-graph flagging (I6) + source staleness (R1).** A parse error
  under the default `--keep-going` producer drops the offending module's defs
  while the build still exits 0, so a "no match" read as authoritative. Every
  read answer (and `unused`) whose snapshot has failed/unparseable modules now
  carries a `# partial:` footer; a snapshot whose graph file predates a source
  edit (`ldStaleVsSource`, computed once at load) carries a `# stale:` footer
  that **also fires in preloaded mode** (previously hardcoded never-stale).
  Footers are suppressed on `format:json` answers (`appendTextFooters`) — which
  also fixes a latent bug where `staleFooter` could corrupt a JSON envelope.
  The withhold behaviour stays opt-in via `--require-well-typed` (withholding
  by default would throw away the partial progress of modules that did build).
- **Graph identity hashes in `status` (R9).** `status` now prints
  `graph id: config=… content=…` — a config digest (build-date-stripped
  producer + node-key/schema version + producer flags; stable across
  machines/dates) and a content digest (a fold over the sorted def
  name/kind/state set). The content hash makes a silent def drop (I6) visible;
  both use the vendored Murmur64, no new dependency. `status` also lists any
  failed modules and the source-vs-graph flag.
- **Dead mutual-recursion cycles (I5, second half).** `agda-unused --kinds=dead`
  now flags an `A ↔ B` cycle with no external entry (an SCC pass via
  `Data.Graph.stronglyConnComp` over per-module intra-edges; a size-≥2
  `CyclicSCC` is dead iff no member has a cross-module user or an
  outside-the-SCC intra caller). Note: `deletion candidate (dead cycle with …)`.
- **Coverage counts beyond `search` (R2).** `callers`/`callees`/`impact`/`roots`
  now carry the same one-line closure-coverage footer on non-empty text
  answers, and `callers`/`callees` add `unsearched_files` to the JSON envelope.
- **`search mode=text` (R3).** A new `mode=text` shells out to ripgrep over the
  source bytes (`findBin "rg"` / `$AGDA_EXPLORE_RG`), so pragmas, comments,
  `using`-lists and regex — which the definition/edge index can't see — are
  reachable; results are always current (read off disk, not the snapshot).
  Makes `search` a superset of grep rather than a different-shaped subset.
- **Tool ergonomics (R7).** Category tags (`[orient]`/`[find]`/`[trace]`/
  `[reuse]`/`[audit]`) on the read-tool descriptions and `[prove]` on `check`,
  which also gained a "when a goal is stuck, reach for `lemmas`/`auto`/
  `case_split` before writing by hand" routing note.
- **`format:json` for `unused`.** The `unused` tool takes `format:json` and
  passes `--json-out` to agda-unused (which already emits the array to stdout),
  returning it verbatim.

### Arena-feedback fixes: false-100 similarity, recursive dead code, per-answer coverage (2026-07-09)

First batch from the MCPBenchArena upstream-request triage (R1–R14 →
I4/I5/I6 filed; features recorded in TODO). The arena's CI gate (G1–G4)
re-verified green against these changes.

- **`similar_types` / `find_lemma` anchor mode (I4).** The WL fingerprint is
  pure signature topology, so different-typed defs with the same shape scored
  a confident 100%. `capDifferingSig` now caps the score at 99.0% whenever
  both rendered signatures are present and differ (whitespace-insensitive);
  identical rendered types keep 100%. The arena's `similar-types-false-100`
  case flips from `mcp_worse` to `tie`.
- **`agda-unused --kinds=dead` (I5, self-recursion half).** A self-edge no
  longer counts as an intra-module caller (`ctxSelfRecursive`), and the
  dead branch's in-file token-count suppression is skipped for
  self-recursive defs (their own RHS calls explain the extra occurrences).
  `deadC (suc n) = deadC n` with no external refs is now a High-confidence
  `deletion candidate (recursive: …)`; a self-edge plus a real intra caller
  stays internal-only. Unit-tested in `test/Spec.hs` (`unusedDeadTests`,
  which now compiles the `AgdaUnused.*` modules into `interaction-spec`);
  `-N1`/`-N4` byte-identity holds.
- **`search` per-answer closure coverage (arena R2, minimal).** Non-empty
  results get a compact one-line footer (`⚠ N source file(s) outside the
  entry closure are invisible to this search — see status`) and the
  `format:json` envelope a top-level `unsearched_files` count
  (`listEnvelope` grew an extras slot). Empty results keep the full
  `coverageNote`; silent when nothing is orphaned.
- **Advisor blurbs (arena R7).** `type_of`/`locate` descriptions now say to
  run `search` first when a short/operator name misses; `search`'s
  description marks it as the entry point that feeds FQNs to the others.
  (The nudge previously existed only in runtime not-found text, after the
  dead-end.)

### `agda-explore`: trim tool response bytes (2026-07-08)

Tool *outputs* (not descriptions) are re-read by the agent on every call, so
response size is a running token cost. Measured on the agda-stdlib sig graph:
sum-of-medians across the read catalogue **−43%**, with no correctness change
(`find_lemma` still 10/10, every hit rate held).

- **Shared list line (`oneLine` / `loc`, every list tool).** Location is now
  `L<line>` — the module was already the FQN prefix printed on the same row,
  i.e. twice; the `/Defined` state is dropped (shown only for the exceptions
  Postulate/Hole/Failed); single-space separators. ~40% shorter
  caller/callee/search/impact/roots lines.
- **`find_lemma` / `lemmas` −56%.** Each candidate's `⊢` conclusion is
  module-qualifier-stripped for display (`⊢ RightIdentity _≡_ (+ 0) _+_`
  instead of the fully-qualified form, `AgdaGraph.GoalCanon.stripQualifiers`);
  header sentence trimmed to a tag.
- **`type_of`.** The ~230 B "elaborated type: reified from the type-checker…"
  footer → `(elaborated, not normalised; source=true for surface syntax)`.
  (The type body stays fully qualified — it's the precision tool.)
- **`brief` −34%.** Drops the redundant `module:` line and inherits the
  shorter list lines.
- **Interactive mutators (`give`/`refine`/`auto`/`give_many`/…).** The
  "Apply this diff and then call `load` — the bridge does not write the file:"
  preamble → `(diff only — write:true to apply + reload)`.
- `stripQualifiers` unit-tested in `test/Spec.hs`.

### `agda-explore`: goal→lemma retrieval overhaul + hint-guided `auto` (2026-07-08)

Fixes I1/I2 (VerinaAgda A/B benchmark): free-text `find_lemma` found the
right lemma in only 2/10 textbook cases, and `auto` couldn't close a
one-lemma goal.

- **`find_lemma` / `lemmas` (goal mode).** Reworked the ranking
  (`AgdaGraph.GoalCanon` + `Query.rankGoalCandidates`): reduce a qualified
  name to its last component (`Data.Nat._+_` → `+`, dropping the
  module-qualifier noise that clustered lemmas by module, not math); keep a
  lowercase head symbol only when it is a known definition name (graph
  vocabulary — `map`/`length`/`reverse` survive, bound vars drop); fold the
  candidate's own name (`+-comm`, `length-++`) into the match bag; score by
  operator-weighted **coverage** (Jaccard tiebreak) instead of symmetric
  Jaccard; and inject the goal's algebraic **shape** as a combinator token
  (`a⊕b ≡ b⊕a` → `Commutative`, `x⊕e ≡ x` → `Identity`, `f (f x) ≡ x` →
  `Involutive`, `R x x` → `Reflexive`), which the stored sigs already carry.
  On the real agda-stdlib sig graph: **2/10 → 10/10** in-top-25, median rank
  1. Below `min_sim` the message points at `search`/ripgrep. `lemmas`
  inherits it (same `queryFindLemma`).
- **`auto` / `auto_all` are hint-guided.** Plain Mimer 2.9 won't try an
  in-scope lemma at *any* budget, but solves instantly when the lemma is
  named as a hint. On a no-solution, `auto`/`auto_all` now seed the top
  graph-ranked lemma base-names (`Query.goalHintNames`, sharing the
  `find_lemma` core) as Mimer hints — tried **one at a time** (an
  unknown/out-of-scope hint aborts the whole `Cmd_autoOne` call; scope
  resolution is instant, so bad hints cost ~nothing), first `GiveAction`
  wins, and the fill reports which lemma closed it. New `timeout` / `hints`
  args expose the budget. Live: `auto goal=…` closes `n + zero ≡ n` via
  `+-identityʳ`; `auto_all` closes both `Holes.agda` goals in one diff.
- Unit tests in `test/Spec.hs` (`goalCanonTests`, token + shape cases).

### `agda-explore`: trim the always-on tool catalogue (FableAna §4) (2026-07-05)

The `tools/list` payload is loaded into every session where the plugin is
enabled — including sessions that never touch Agda — so the tool *descriptions*
are pure always-on context. Rewrote all 35 to ≤2 sentences (one "what does it
answer", one routing cue), relocating parameter/recipe depth to the JSON-schema
property descriptions and `SKILL.md` (the skill loads on demand, not always).
**No tool renames, no schema-structure changes** — Jolteon's
`mcp__agda-explore__*` allow-lists and agent memory files stay valid.

- Shared property values so repeated boilerplate is written once: `fmtProp`
  (the `format` enum, ×3), `fileProp` / `goalProp` (the write-side `file` /
  `goal` params, ×~18).
- Measured `tools/list` (via `initialize` + `tools/list` on `test/deps.json`):
  **description bytes −61%** read-only (6310→2453) / **−55%** full catalogue
  (14342→6388); total payload −32% (15780→10738) / −26% (35784→26498). The
  remainder is JSON schema *structure* (per-property type wrappers, `required`,
  `additionalProperties`) — a functional floor, not trimmable prose.
- Overlap-pruning (merging near-duplicate tools like `find_lemma`/`lemmas`)
  stays open, pending the usage histogram's data.

### `agda-explore`: orientation bundles, stdlib federation, JSON output, coverage warning, one-shot CLI (2026-07-05)

Five capability additions (FableAna §2–§7), each verified end-to-end against
Agda 2.9.0:

- **Orientation bundles `brief` / `goal_brief` (§3).** `brief name=X` composes
  `locate` + type signature + direct `callers`/`callees` (capped) +
  `similar_bodies` into one sectioned block — the opening sequence an agent
  otherwise pays ~4 round trips for. `goal_brief goal=gN` (write side) does the
  same for a hole: live `goal_type` (type + context) + top reusable `lemmas`.
  Both are pure composition of existing runners (resolve once, drive off the
  canonical FQN so the auto-resolve note appears at most once); read-only.
- **Stdlib graph federation (§2).** `--overlay-graph FILE` (repeatable) /
  `overlay-graphs:` decode a prebuilt expanded graph (e.g. agda-stdlib) once at
  startup, origin-tag every def (`defOrigin`), and union it into every snapshot
  inside `loadedFromGraph` (project graph FIRST ⇒ project wins every key
  collision). Overlay defs render an `[external: <label>]` suffix so an agent
  knows they need an `open import`; `search`/`type_of`/`find_lemma` gain overlay
  coverage (edge queries don't — overlays carry no cross-boundary edges). A
  version-mismatched / unparseable overlay is warned-and-skipped, never fatal.
  `scripts/build-stdlib-graph.sh` builds one. `loadedFromGraph`/`loadLoaded`
  now take `Config` (subsumes the earlier per-arg threading).
- **`format: json` on `search`/`callers`/`callees` (§5).** Opt-in structured
  `{tool, query, resolved?, total, shown, items[]}` envelope (`total`/`shown`
  keep the `…and N more` affordance); each item carries name/module/line/kind/
  state/access + edge provenance + overlay origin. Default stays prose
  (byte-identical to before — the text branch is untouched). New `ep` enum
  schema builder in `ToolDef`.
- **Closure-coverage warning (§6).** At snapshot commit, `loadedFromGraph`
  diffs on-disk sources under the include roots against the graph's module
  files; files outside every entry's closure (invisible to queries) are stored
  on `ldOrphanFiles`, filtered through `coverage-ignore:` globs
  (`--coverage-ignore`, matched against absolute/basename/root-relative forms).
  Surfaced in `status` and appended to an *empty* `search`/`locate` result — so
  an absent name reads as "outside the closure", not "does not exist". Glob
  matcher lifted to the shared `AgdaGraph.Glob` (deduped with `agda-unused`).
- **One-shot CLI `agda-explore query <tool> key=value… [--json] (§7)`.** Loads
  the graph once (no daemon/watcher) and dispatches through the SAME tool table
  the server uses — inherits every read tool for free. Numeric/bool values are
  coerced so `limit=50` reaches `argInt` as a JSON number. Exit 0 on an answer
  (including "no results"), nonzero only on operational error (bad graph,
  unknown tool, missing arg). Read-oriented; the write bridge stays MCP-only.

### `agda-explore`: drive agents toward the write-side bridge (2026-07-05)

The write bridge went essentially unused in practice — across the VerinaAgda
A/B benchmark (364 transcripts) and Jolteon-FastBFT (909 MCP calls) agents
authored with `Edit`/`Write` and validated with `check`, but never touched
`auto`/`give`/`refine`/`case_split`/… (0 calls). These five changes target
the moments an agent already passes through, so proof search and hole-driving
become the path of least resistance rather than a catalogue entry read once.

- **`check` next-step footer.** Wherever open goals are listed (`check`,
  `load`, a `write:true` reload) the output now ends with a copy-pasteable
  routing footer naming the first live goal id (`auto goal=g0 write:true` ·
  `auto_all` · `goal_type` · `case_split` · `give` · `lemmas`).
- **Speculative Mimer hints on `check`.** A live `check` probes the first few
  remaining goals with Mimer (`Cmd_autoOne … "-t <secs>"`) and reports any
  ready-made solutions inline, so the payoff of proof search is visible
  without the agent having to remember `auto` exists. Bounded by
  `--auto-hints-limit` (default 3) and `--auto-hints-timeout` (default 1s);
  `--no-auto-hints` disables. A success solves the meta in Agda's *session*
  state, so it marks the session dirty (the file is untouched).
- **New `auto_all` tool.** Runs Mimer over **every** open goal of a module in
  one call — no goal ids to manage — accumulating one atomic diff for the
  solved goals (via `spliceRanges`, like `give_many`) and listing the
  survivors. `write:true` applies + reloads. Per-goal budget via `timeout`
  (default 5s); continue-on-failure (an unsolved goal is a result, not an
  abort).
- **Loop-closing plugin hooks (`plugin/hooks/`).** A PostToolUse hook
  (Edit|Write) validates every Agda text edit through the warm bridge — a
  real `check` via the control endpoint when available, else a rate-limited
  nudge — and a PreToolUse hook denies the *first* structural `grep` per
  session with the grep→graph tool mapping (later greps sail through). Need
  `jq`; kill switch is disabling the plugin or blanking `hooks/hooks.json`.
- **`--control-port` localhost endpoint (`AgdaMcp.Control`).** Serves
  `GET /check?file=…` (the same runner as the `check` tool) so the edit hook
  can validate from outside the MCP transport; `503` while busy, writes the
  bound port to `<out-dir>/control-port` (removed on shutdown). Needs
  `--enable-interact`; off by default. A new module imported by no other
  project module (MainMcp passes it the check runner as a callback — no
  cycle, same layering rule as `AgdaMcp.Inspect`).
- **Tool-usage histogram in `status`.** `handleCall` counts every dispatch
  per tool name (`ssToolCounts`); `status` renders a per-run histogram, so
  adoption is measurable passively instead of by parsing transcripts.

### `agda-explore`: opt-in strict producer + well-typed-only promotion (2026-07-01)

Two independent, default-off daemon knobs for how it consumes `agda-deps`
builds (both moot in preloaded mode):

- **`--strict-producer` (`strict-producer:`).** Drops `--keep-going` (any
  error aborts ⇒ serve-stale keeps the last graph) and enables `agda-deps`'
  `--incremental` fragment cache under a shared `--cache-dir`. The producer
  disables `--incremental` under `--keep-going`, so `buildBaseArgs` picks
  one. Needs Agda ≥ 2.9.
- **`--require-well-typed` (`require-well-typed:`).** The new `commitOrKeep`
  seam withholds a rebuild whose `ldFailed` is non-empty while a prior
  snapshot exists (keep serving the last well-typed graph), but always
  commits on cold start. Holes are tagged `Hole`, never `failedModules`, so
  hole-filling still refreshes. `--strict-producer` subsumes it.

### Adopt producer `nodeKeyVersion` 3 — anonymous-module lifting + `module-local` provenance (2026-06-30)

Tracks the producer's 2026-06-30 change, which lifts `where`-block and
`module _ (…) where` section members into their nearest *named* parent
(`Mod._.helper@15` ↦ `Mod.helper@15`, module re-homed to `Mod`) and
renames the edge-provenance tag `where` → `module-local`. Three parts:

- **Provenance enum (blocking — a v3 graph won't decode otherwise).**
  `AgdaGraph.Schema` gains a `ProvModuleLocal` constructor with wire tag
  `module-local`; the legacy `ProvWhere`/`where` case is **kept** so v2
  fixtures and on-disk caches still parse. `AgdaMcp.Query.parseProv`
  accepts `module-local` and keeps `where` as a legacy alias (both match
  edges of either vintage via `provFilterEq`, which collapses `ProvWhere`
  onto `ProvModuleLocal`); `renderProv` round-trips both. Filter help in
  `AgdaMcp.Tools` and the `silhouette`/`similar_*` body-bucket docs
  updated. `Similarity.splitSigBodyAdj` needed no logic change (its
  `Just _` catch-all already buckets the new tag body-side).
- **`AgdaMcp.State.currentNodeKeyVersion` 2 → 3.** A v2 cache now
  correctly trips the live-rebuild / preloaded-stale-warn path instead of
  being judged current.
- **Re-keyed locally-scoped-helper detection off the surviving
  `@<line>` disambiguator** (`AgdaMcp.Query.isLocalName` /
  `AgdaMcp.State.isLocalName'` in `buildOwnerMap`), since v3 names no
  longer carry the `._.` marker the old check keyed on. The producer
  appends `@<line>` to (and only to) anonymous-module helpers, so the tag
  is the node-local signal — and it matches pre-v3 `Mod._.helper@15`
  names too. `AgdaUnused.Analysis.isAnonymousModule` and
  `Fingerprint.derivedOwner` (both `._`-keyed) are now inert for v3 input
  by producer intent — retained for v2-cache reads, doc-noted. Stale
  `._.` doc examples swept across `Query.hs` / `Fingerprint.hs`.

Verified against the producer's regenerated v3 golden (`module-local`
edges, lifted `@<line>` names, no `._.`): `silhouette` / `concept-bundle`
/ `motif` run clean; `agda-explore` `top_level_only` drops exactly the
`@<line>` helpers and owner notes resolve on re-homed names; the
`provenance:module-local` / legacy `provenance:where` filters both hit;
v2 fixtures still decode and now warn `v1 < v3 (stale)` in preloaded mode.

### Write-side bridge: file authoring + structured validation (2026-06-16)

The interaction bridge gained tools so agents can WRITE whole files under
the zero-axiom contract — not just fill existing holes — closing the gap
that had agents reaching for `Write` + `agda File` instead of the bridge
(see `Jolteon-FastBFT/docs/MCP/UsageAnalysis.md` for the adoption data
that motivated this). All in `AgdaInteract.Tools`, exposed under
`--enable-interact`:

- **`check`** — type-check a module (on-disk, or a proposed `content`
  dry-run) over the warm session and return structured diagnostics: a ✓/✗
  verdict, **every** error and warning (not just the first), and the open
  goals with stable ids. The bridge's `agda File`, reusing the `.agdai`
  cache and handing the goals straight back.
- **`give_file`** — author whole-file `content` (also creates a new file)
  or an `append` block; the whole text is run through the no-postulate /
  no-escape-hatch guard (`Guard.checkFileInput`, the whole-file variant
  that tolerates benign module pragmas) and type-checked, returning a diff
  (or applied with `write:true`). The validated counterpart to `Write`.
- **`new_module`** — scaffold a validated module skeleton: a header
  matching the path, literate fences for a `.lagda.md` path, `open import`
  lines **resolved off the dependency graph** from bare names, and a hole
  per `{name,type}` stub.
- **`construct`** — run a planned heterogeneous batch of
  `give`/`refine`/`case_split`/`auto` steps against one warm load → one
  combined diff (reload-per-step; edits accumulated against the pristine
  original).
- **`lemmas`** — goal-directed lemma search wired off a live goal's type
  (a front-end to the read-side `find_lemma`), so a stuck goal surfaces a
  reusable candidate to `give`/`refine` with.
- **`write:true`** — opt-in on every mutator (`give` / `refine` /
  `case_split` / `give_many` / `auto` / `construct` / `give_file` /
  `promote`, and `new_module`): the bridge applies the edit, reloads, and
  returns the diff **plus the refreshed goals** in one round-trip, instead
  of only returning a diff. (Default stays off — the bridge does not write
  unless asked.) `promote` now also runs the whole-file guard over the
  staged body.

### Live web inspector (`--inspect`) (2026-06-15)

- **`agda-explore`: opt-in localhost web inspector.** Started with
  `--inspect` (or `inspect: true` in `.agda-explore.yml`; `--inspect-port N`
  sets the start port and implies it), the daemon serves a self-contained
  web page over a hand-rolled HTTP + Server-Sent-Events server (new
  `AgdaMcp.Inspect`, on the small `network` dep) that shows, live:
  - an **activity feed** — every `tools/call` with its arguments, result,
    duration, and stale flag, collapsed to one clickable line that expands on
    demand;
  - an **editing view** — the loaded module with each proposed
    `give` / `refine` / `case_split` / `auto` / `give_many` diff highlighted
    over the on-disk file, plus the open goals.

  It is a read-only **side channel**: events are teed from the single
  `handleCall` chokepoint (the feed) and the bridge's diff-producing helpers
  (the editing view) through `emitInspect`, which is a no-op when the
  inspector is off — so the feature is **inert unless asked for**, never
  blocks a query (one STM transaction over an unbounded broadcast channel +
  a bounded backlog ring for newly-connected browsers), and **never writes
  the JSON-RPC stdout**. Localhost-only, no auth (it streams your own
  source). On a port clash the daemon **probes upward** from the start port
  so several projects coexist, and each connection leads with a `server`
  identity frame so the page header + tab title name the project + bound
  port — you can tell several inspector tabs apart. The offline test suite,
  `-N1`/`-NK` determinism, and every other binary are unaffected (the new
  deps `network` + `stm` are scoped to the `agda-explore` executable only).

### Staging-buffer include-path fix (2026-06-15)

- **`agda-explore`: `stage` / `promote` now load on projects with an
  `.agda-lib`.** The scratch module and promote's renamed validation temp have
  *bare* top-level module names, but both load sites passed Agda only the
  project's `cfgIncludes`. When the include root doesn't cover the generated
  dirs (the `.agda-lib` case, root e.g. `agda-src` with the scratch *under*
  it), Agda rejected both with `ModuleNameDoesntMatchFileName` and the staging
  workflow was dead. Fix: `AgdaInteract.Tools.loadIncludes` prepends the loaded
  file's own directory for exactly the scratch and `.validate` dirs (`doLoad` /
  `validateCandidate`); normal project loads are byte-identical. Regression
  locked in the live `convergence.py` harness (`stage`→`promote` with an
  `.agda-lib` at the root as the trigger); stays a live test, since the bug is
  Agda module-resolution behaviour the offline transcript replay can't
  exercise.

### Bridge batching + staging, cold-start fallback, parallel goals (2026-06-13)

- **`agda-explore`: `auto` now works (Mimer).** The earlier "unavailable on
  2.9" was a wrong `Cmd_autoOne` invocation — Agda 2.9's signature is
  `Cmd_autoOne Rewrite InteractionId Range String` and we were omitting the
  leading `Rewrite`. `iotcmAutoOne` now sends it; `auto <goal>` returns a
  fill diff (or a clear no-solution note).
- **`agda-explore`: `give_many`** (bridge) — fill several open goals in one
  shot against a single live session, so the (possibly minutes-long) module
  load is paid ONCE instead of reloaded between gives. Each term is
  Agda-validated + guarded; returns one combined unified diff; atomic — if
  any term is rejected, nothing is applied and the error names the goal.
- **`agda-explore`: `stage` / `promote` / `discard`** (bridge) — author a
  *new* definition in isolation. `stage` opens an ephemeral scratch module
  under `.agda-explore/scratch/` (seeded with a target's imports), so each
  `load` re-checks only the scratch's tiny closure instead of the target's
  whole module; build the def with the usual tools, then `promote` splices
  it into the real target — merging missing imports and re-validating the
  **whole target** in Agda — returning a unified diff on success or the
  localized error with nothing changed (validation runs against a temp copy
  under a renamed module, so it never trips `AmbiguousTopLevelModuleName`
  against the real file). `discard` drops a dead-end scratch.
- **`agda-optimization`: `term-cluster` ranking flags.** `--sort=`
  `score|log-score|size` and `--min-mean-depth=N` make the AST-subterm
  cluster report rankable/filterable (default `score`); determinism holds
  (`+RTS -N1` ≡ `-NK`, human and `--json`).
- **`agda-explore`: cold-start fallback.** Serve-stale only covered the
  *after one good build* case; a corpus that fails to build from the very
  first load left the daemon dark (every tool echoed `agda-deps exit 120`).
  Now the first-build failure is cached as an actionable diagnostic
  (`status` and every tool report "the graph has never built — module X
  doesn't type-check; fix it or point `entries:` at a clean module"), the
  background worker keeps retrying, and the daemon self-heals once the
  corpus builds — no reconnect. (Observed dark on the Jolteon-FastBFT
  corpus whose auto-discovered `Main` entry never built.)
- **`agda-goals`: parallel sessions.** Drives the root files over a pool of
  persistent `agda --interaction-json` sessions (work-stealing queue, pool
  size = RTS capabilities; `+RTS -N4` to cap memory on a heavy corpus)
  instead of one serial process. Output is reassembled in input order, so
  it stays **byte-identical** between `+RTS -N1` and `-NK` (human and
  `--format=json`).
- **Packed graph form — refused with guidance, not silently degraded.**
  `AgdaGraph.Schema` now rejects a `--json-mode=packed` graph with an
  actionable message: packed omits the per-definition kind / line / access /
  type / subterm-hashes the analyses need (it is the HTML-viewer form), so a
  consumer load would cripple `type_of`/`similar_*`/`unused`/etc. The format
  + gap are documented in `test/packed/README.md`; the real fix is a
  producer `packed-complete` mode (see `Backlog.md`).

### Write-side interaction bridge for `agda-explore` (2026-06-12)

An opt-in (`--enable-interact`, or `enable-interact: true` in
`.agda-explore.yml`) **write surface** on the `agda-explore` daemon,
backed by a long-lived `agda --interaction-json` subprocess — the
symmetric counterpart to the read-side query tools, and a *second,
independent* subprocess model beside the graph daemon (interaction tools
reflect live on-disk state and bypass `ensureFresh`). Needs `agda` on
`$PATH` (or `--agda-bin`).

New MCP tools:

- **read:** `load` (open a module; lists goals with ids `g0, g1, …` and
  their `(line:col)` — an id is preserved across a reload while the hole's
  position is unchanged, but applying an edit can renumber goals, so
  re-`load` after edits), `goal_type`, `goal_context`, `infer`,
  `normalize`.
- **write (Agda-validated):** `case_split`, `refine`, `give` — each
  returns a **unified diff** (the bridge never writes the file); a term
  that doesn't typecheck returns the localized Agda error with the file
  left untouched. `auto` runs Mimer proof search (fills the hole, or
  reports no solution).
- **hard zero-axiom contract:** `give` / `refine` input is rejected up
  front if it uses `postulate`, a termination / coverage / `OPTIONS`
  pragma, or another escape hatch (`AgdaInteract.Guard`).
- `.lagda.md` literate sources are first-class: Agda reports positions
  as character offsets into the full file, so edits land inside the
  ```` ```agda ```` fence and never in surrounding prose.

Internals:

- The `--interaction-json` reply parser + IOTCM command builders were
  promoted into the `agda-graph` library
  (`AgdaGraph.Interaction.Protocol` / `.Iotcm`); `AgdaGoals.Protocol` is
  now a thin re-export.
- `agda-goals` was migrated onto the same long-lived session driver
  (`AgdaInteract.Session`): one persistent `agda` process across all
  files (reusing the `.agdai` cache) instead of one per file. Goal
  extraction is **byte-identical** to the old one-shot driver (the
  acceptance gate, human and `--format=json`).
- New offline test-suite `interaction-spec` replays committed golden
  `--interaction-json` transcripts (`test/interaction/<version>/`) as a
  protocol-skew tripwire, plus pure guard / literate / goal-id / edit
  unit tests. CI runs it with **no `agda` binary** (regenerate the
  fixtures with `bash test/interaction/regen.sh` after an Agda bump).

### Agent-usage-analysis recommendations (2026-06-12)

Implemented all nine recommendations mined from a downstream consumer
project's agent-session analysis (the *negative space* — why agents with
the MCP available fell back to grep). See the `agda-deps` repo for
producer-side items.

**`agda-explore` (daemon):**

- **serve-stale + async rebuild.** `ensureFresh` now returns the
  last-good snapshot *immediately* (tagged stale via a `# stale:` text
  footer) and schedules the `agda-deps` rebuild on a single background
  worker, instead of blocking every query — and the whole stdio loop —
  behind a multi-minute subprocess. Only the genuine first build (no
  snapshot to serve) is synchronous. `status` never blocks on a rebuild.
  A failed background rebuild keeps serving stale and retries on a
  bounded backoff.
- **fail-fast `type_of`.** An out-of-snapshot name is reported instantly
  ("not in the graph, reachable from entry …") against the current
  snapshot rather than paying the rebuild barrier.
- **multi-entry roots.** `.agda-explore.yml` accepts an `entries:` list
  (and `--entry` is repeatable); the daemon runs `agda-deps` once per
  entry and **unions the graphs in-process** (`AgdaGraph.Union`, dedup by
  qname, parallel-array-faithful), since the producer compiles only one
  entry's closure per run. Single-entry is byte-identical to before. The
  union is materialised back to the graph file so the shell-out `unused`
  tool sees the same graph.
- **universal unique-candidate auto-resolution.** When the "did you
  mean" set has exactly one candidate, every name-taking tool now
  resolves to it (with an explicit `(auto-resolved …)` note) instead of
  erroring. `--no-auto-resolve` opts out.
- **`find_lemma`** (new tool). Goal-directed lemma search in two modes:
  `anchor=<def>` reuses WL type-fingerprint ranking; `goal=<free text>`
  canonicalises the goal and ranks by conclusion token-overlap. The goal
  canonicaliser moved to the shared library as `AgdaGraph.GoalCanon`
  (one home for the vendored Murmur64).
- **query telemetry.** Each `tools/call` appends one line to
  `<out-dir>/query-log.jsonl` (tool, args, `dur_ms`, `ok`, `stale`); on
  by default in live mode, `--no-query-log` to disable.

**`agda-unused`:**

- **never silently return 0.** Relative `ROOT`s are absolutised so they
  match the graph's absolute `moduleFiles`; if files are scanned but none
  match the graph, it hard-errors (stderr + non-zero exit) instead of
  printing `# total: 0`.
- **inliner-gap confidence.** Dead findings with a trivial single-clause
  body (proxied via subterm-hash arrays) are tagged
  `confidence: low (possibly inlined)`; a trivial-bodied name still used
  textually in another file is suppressed entirely. The MCP `unused`
  caveat no longer tells agents to grep-verify *every* dead finding.
- **aggregation output.** `--group-by=dir|file|kind` and `--count-only`
  (CLI + the MCP `unused` tool), mirroring the `by_module` idiom. Output
  is a total order, so the determinism gate holds.

Determinism acceptance test (`+RTS -N1` vs `-NK` byte-identical on
`test/deps.json`, human and `--json`) verified for `agda-unused` and
`agda-optimization`, including the new `--group-by`/`--count-only` modes.

### Split out of `agda-deps` (2026-06-10)

`agda-graph-explorer` was factored out of the `agda-deps` repository.
It carries everything that *consumes* the dependency graph, leaving
`agda-deps` as a focused Agda compiler backend (the *producer*):

- the **`agda-graph`** library (typed `graph.json` view + `Index`);
- **`agda-unused`**, **`agda-optimization`**, **`agda-goals`**,
  **`agda-explore`**;
- the **`plugin/`** bundling the `agda-explore` MCP server.

This repo links **no Agda** — `cabal.project` has no
`source-repository-package` pin. `agda-goals`' single Agda dependency
(`Agda.Utils.Hash.hashString`) was vendored as
`AgdaGoals.Canon.hashString = asWord64 . hash64` (`murmur-hash`),
byte-identical to Agda's definition, so goal-bucket hashes are
unchanged.

The pre-split history (all rounds of analysis development, the wire
schema, the gotchas) lives in the `agda-deps` repository's
`Changelog.md`.
