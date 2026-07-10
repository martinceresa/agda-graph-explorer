# FixRLess — consolidated fix plan for the open TODOs and arena requests

> Relocated from the repo-root `ToFix.md` to `Plan/FixRLess.md` (2026-07-10).
> Scope unchanged: the R1–R14 triage batch. The later R19/R20 work has its own
> plan in [Fix19.20.md](Fix19.20.md).

Working plan for everything left open after the 2026-07-09 MCPBenchArena
triage (Requests R1–R14 → Issues I4–I6 + TODO entries; the quick wins
R5/R13/R7/R2-search shipped that day — see [Changelog.md](../Changelog.md)).
Each item: the problem, the fix design, where it goes, size, and how to
verify. Ordered by priority (correctness first, then leverage per effort).
Items in [Deferred.md](../Deferred.md) stay deferred and are not re-planned here.

**Status (2026-07-09):** items 1–5, 9, 10 are **DONE** (shipped this session;
see [Changelog.md](../Changelog.md) and Issues I5/I6). Item 1 is done as a
*mitigation* — every affected answer is flagged; the complete producer-side
fix is I6c under section P. Items 6, 7, 8, 11 remain; the section text below is
the standing design for them.

Quick map:

| # | Item | Source | Size | Kind | Status |
|---|------|--------|------|------|--------|
| 1 | Partial-graph commit + staleness cluster | I6, R1, R10 | M | correctness | **done** (mitigated; I6c → agda-deps) |
| 2 | Dead mutual-recursion cycles (SCC) | I5 open half | S–M | correctness | **done** |
| 3 | Graph identity hash in `status` | R9 | S | feature | **done** |
| 4 | Coverage counts beyond `search` | R2 follow-up | S | feature | **done** |
| 5 | `search mode=text` (ripgrep fallback) | R3 | M | feature | **done** |
| 6 | Arena CI regression gate | R8 | L | process | open (staged plan below) |
| 7 | VerinaAgda A/B re-run | TODO | M | benchmark | open (now unblocked) |
| 8 | Stdlib overlay auto-build | TODO | M | feature | open |
| 9 | Tool-catalogue grouping | TODO idea | S | ergonomics | **done** (tags; reduction still gated on §7) |
| 10 | `format: json` for `unused` | TODO | S | feature | **done** (simpler than planned — `--json-out` already stdout) |
| 11 | Structural goal canonicalisation | TODO (P5) | L | deferred-ish | parked (unchanged) |
| P | Producer-side items to file in agda-deps | R12, R14, I6c | — | cross-repo | open (agda-deps) |

---

## 1. The staleness/content cluster — I6 + R1 + R10 (priority 1)

**Problem.** Every staleness signal is inferred from *build scheduling*
(dirty flag, scan signature, in-flight build), never from *graph content*.
So a parse error under the default `--keep-going` commits a partial graph
served as fresh (I6): `runOneEntry` (`src/AgdaMcp/State.hs:727-739`) judges
success by `doesFileExist` only, parse failures never reach `failedModules`,
and `commitOrKeep`'s `--require-well-typed` guard (`State.hs:1198`) never
trips. Separately (R1), the `# stale:` footer (`Tools.hs:256`) fires only in
live mode — preloaded snapshots are hardcoded never-stale
(`ensureFresh`, `State.hs:1057`) — and carries only `ldBuiltAt`, no
graph-vs-source comparison.

**Fix — four stages, each independently shippable:**

1. **(I6a) Consult the producer exit code in `runOneEntry`.**
   *Verify first:* does `agda-deps --keep-going` exit non-zero when a module
   fails to parse? (Check in the agda-deps repo / a live probe; if it exits 0
   the exit code is useless and stage 2 becomes the primary fix.)
   Change `runOneEntry` to return a health mark alongside the graph — e.g.
   `Right (path, BuildClean | BuildDirty)` where `BuildDirty` = "graph file
   exists but the producer reported errors". Thread it into `Loaded` as
   `ldPartial :: Bool` (set in `loadedFromGraph`, `State.hs:608-657`).
   `commitOrKeep` (`State.hs:1194-1208`) then treats `ldPartial` like a
   non-empty `ldFailed`: withhold under `--require-well-typed`, else commit
   **flagged**.
2. **(I6b) Surface the flag on every answer.** When the served snapshot has
   `ldPartial` (or non-empty `ldFailed`), `withFresh`/`withFreshIO`
   (`Tools.hs:282`) appends a partial-graph footer — same mechanism as
   `staleFooter`, different text: `# partial: the producer reported errors
   during the last build; definitions may be missing (source may not parse)`.
   `status` prints the same. This converts I6's confident false negative
   into a flagged answer even before the producer-side fix lands.
3. **(R1) Enrich + extend the stale footer.**
   - Content: add "built at T, newest source mtime S" to `staleFooter` so an
     agent can see *how far* behind it is. The newest-source mtime is already
     computed by the live-mode scan (`rebuildWarranted` / `ScanSig`,
     `State.hs:1104-1106`) — cache it on the scan result rather than
     rescanning.
   - Preloaded mode: when include roots are known (project root + includes
     configured), compare the graph file's mtime against the newest source
     mtime on first query, cache with a short TTL (~2 s), and append
     `# stale: graph file predates N source file(s)` when behind. When no
     roots are known (bare `--graph`), keep silent — nothing to compare.
4. **(I6c, cross-repo) Producer records parse failures** in `failedModules`
   (or a distinct `parseFailedModules`) — then the existing
   `--require-well-typed` gate covers the case with no consumer heuristics.
   File in agda-deps (see section P); consumer change is only the
   `AgdaGraph.Schema` decode if a new field is chosen.

R10 needs no separate fix: the *triggering* poll query already gets the stale
footer when auto-rebuild is on (`State.hs:1085-1090`); stages 1–2 cover the
post-commit reads that made poll mode measure worse.

**Files.** `src/AgdaMcp/State.hs` (runOneEntry, commitOrKeep, Loaded,
loadedFromGraph, ensureFresh), `src/AgdaMcp/Tools.hs` (footers, statusText).

**Verify.** Arena A2: `es-live-watch-broken` must stop reporting
`flagged_staleness=False` poisonings (behavior flips from silent-empty to
flagged); `es-live-poll` poisoning rate should drop to the watch rate.
Locally: live daemon over a scratch project, break the file (unterminated
block comment), confirm `search` answers carry the partial footer and recover
after the fix; preloaded mode with a stale `--graph` shows the mtime footer.

---

## 2. Dead mutual-recursion cycles — I5 open half (priority 2)

**Problem.** `A ↔ B` with no external entry: each is the other's
"intra-module caller", so both read as `DefinedInternalOnly` and
`--kinds=dead` misses them — same blind spot as the fixed self-recursion,
one level up.

**Fix.** SCC pass in `src/AgdaUnused/Analysis.hs`:

- Extend the `ingestEdge` fold with per-module intra-edge *lists*
  (`M.Map Text [(Text, Text)]` — the current `intraQ` map loses the source
  structure needed to build a graph).
- Per module, run `Data.Graph.stronglyConnComp` over the short-name nodes
  (containers is already a dependency; the Index-side
  `AgdaOptimization.Condense` is not reusable — agda-unused works on the
  JSON view keyed by `(module, short)` text pairs and never builds an
  `Index`).
- A cycle (SCC of size ≥ 2) is **dead as a unit** iff no member has: a
  cross-module user (`usersClosure`), a re-export widening, or an
  intra-module caller from outside the SCC. Emit one `DefinedDead` finding
  per member with a note naming the cycle
  (`deletion candidate (dead cycle with B, C)`); reuse the self-recursion
  precedent for the source-text fallback — skip the in-file count for cycle
  members (their occurrences are explained by intra-cycle calls), keep the
  cross-file suppression.
- Determinism: sort SCC members and iterate modules in key order (the
  existing folds are already ordered); re-run the `-N1`/`-N4` byte-identity
  check.

**Verify.** Extend `unusedDeadTests` in `test/Spec.hs`: `A ↔ B` no external
caller → both dead with cycle note; `A ↔ B` + one external caller of A →
neither flagged dead (A has a user; B is internal-only via A). Arena A3
gains a case if they add one.

---

## 3. Graph identity hash in `status` — R9 (priority 3)

**Problem.** No canonical hash of (graph content + config) exists for keying
results/regressions; the arena computes its own
(`MCPBenchArena/scripts/identity.py` → `arenalib.graph_config_hash`).

**Fix.** Two hashes computed once in `loadedFromGraph` and stored on
`Loaded`, rendered by `statusText`:

- **`config` hash** (arena-compatible ingredients): sha-style digest over
  sorted-JSON of `{producer (build-date stripped via the arena's
  `,\s*built[^,]*,` → "," rule), nodeKeyVersion, schemaVersion,
  producer flags}` — flags from `buildBaseArgs`'s config in live mode,
  omitted in preloaded mode. Exact arena parity is impossible (their recipe
  includes an arena-side seed-file sha), so print the *ingredients* plus the
  digest and let the arena compose its own; that keeps us honest without a
  cross-repo hash contract.
- **`content` hash**: fold over the sorted definition set
  (`defName`, `defKind`, `defState`) — this is the tripwire that makes I6's
  silent def drops visible (`status` before/after an incident differs even
  when everything else looks fresh).

Use the vendored Murmur64 (`AgdaGraph.GoalCanon.hashString`) over a canonical
rendering — no new dependency; 64-bit is plenty for a tripwire. Emit both in
`status` text and any future `status` JSON.

**Files.** `src/AgdaMcp/State.hs` (Loaded + loadedFromGraph),
`src/AgdaMcp/Tools.hs` (statusText).

**Verify.** Same graph re-loaded → identical hashes; delete one def from a
fixture copy → content hash changes; arena `identity.py` can reproduce the
config digest from the printed ingredients.

---

## 4. Per-answer coverage counts beyond `search` — R2 follow-up (priority 4)

**Problem.** `search` now carries the compact closure-coverage footer +
`unsearched_files` JSON field; the other enumeration/cone tools still answer
silently over a partial closure — `callers`/`impact` are exactly the "is it
safe to change X?" tools where a silent blind spot misleads.

**Fix.** Append `coverageFootnote` (`Query.hs`, exists) to the non-empty
text output of `callers`, `callees`, `impact`, and `roots`, and pass
`[ "unsearched_files" .= n | n > 0 ]` through `listEnvelope`'s extras slot
(added 2026-07-09) for the two that have JSON envelopes. Skip `brief`
(already links `status`) and point-lookup tools (`locate`/`type_of` miss →
`notFound` already appends the full `coverageNote`). Keep it count-only —
the noise budget matters; the leaner-output work (2026-07-08) cut response
bytes 43% and this must not claw them back.

**Files.** `src/AgdaMcp/Query.hs` (edgesQuery, queryImpact, queryRoots).

**Verify.** Over `test/deps.json` (6 orphan files): `callers`/`impact`
answers show the one-line footer; a graph with full closure shows nothing;
JSON envelopes carry the field only when non-zero.

---

## 5. `search mode=text` — ripgrep fallback — R3 (priority 5)

**Problem.** Textual queries (pragmas, comments, `using`-lists, regex,
numeric literals) are invisible to the definition/edge index — the MCP is a
different-shaped subset of grep instead of a superset (I3 cluster 2; X1
literal cases).

**Fix.**

- New `mode` arg on `search`: `name` (default, current behavior) | `text`.
  Explicit only — no query-shape auto-detection (predictability beats
  cleverness); instead, an *empty* name-mode result appends "looks textual?
  try `mode=text`" to the existing miss text.
- `text` mode shells out to `rg`, modeled on `runUnused`
  (`Tools.hs:312-354`): `findBin "rg" cfgRgBin "AGDA_EXPLORE_RG"` (new
  config knob, same precedence convention as the other binaries),
  `readCreateProcessWithExitCode` with `cwd = cfgProjectRoot`, args
  `-n --no-heading -S --glob '*.agda' --glob '*.lagda*' <query> <includes>`.
  Cap at `limit` lines with an "…and N more" tail. Output labeled
  `text mode: ripgrep over source bytes (not the graph — always current)`.
- Preloaded bare-`--graph` mode (no project root): return an actionable
  error ("text mode needs a project root; run with --project / entries").
- Missing `rg`: clean one-line diagnostic naming the knob and env var
  (follow the fiedler helper precedent of distinct, actionable failures; a
  distinct exit code is irrelevant here since it's a tool answer).
- JSON envelope items: `{file, line, text}` rows via the same
  `listEnvelope`.

**Files.** `src/AgdaMcp/Tools.hs` (tool schema + runner),
`src/AgdaMcp/Config.hs` (cfgRgBin), `src/AgdaMcp/State.hs` (findBin reuse —
it's already there).

**Verify.** Arena X1 literal cases (`{-# OPTIONS`, `foldr|foldl`, manifest
files) flip from `mcp_worse` to `tie`; a query for a pragma over the live
scratch project returns file:line rows identical to raw `rg`.

---

## 6. Adopt the arena CI regression gate — R8 (priority 6, staged)

**Problem.** No benchmark/recall gate in CI — the I1 regression class
(2/10 recall) would land silently today. The arena's deliverable
(`MCPBenchArena/ci/agda-explore-regression.yml` + `scripts/ci_gate.py`,
gates G1–G4) is code-complete but its environment contract contradicts this
repo's deliberately Agda-free CI: it needs agda 2.9 + agda-deps + registered
stdlib 2.4 + the arena repo + in-CI stdlib graph builds.

**Fix — split the gate by what it actually needs:**

- **Stage 1 (offline gates G1+G2, cheap).** G1/G2 only need the
  `agda-explore` binary + the two stdlib graph JSONs. Get the graphs without
  an in-CI Agda toolchain by either (a) publishing them as a release asset /
  cache artifact keyed on `(agda-deps sha, stdlib sha, flag set)` and
  downloading in CI, or (b) committing them LFS-style to the arena repo.
  Then a new `arena-gate-offline` job: checkout both repos (pin the arena at
  a ref; fix `conditions.yaml`'s machine paths via env overrides —
  `AGDA_EXPLORE_BIN` is already honored), `cabal build`, run `ci_gate.py
  --suite micro,anti` (needs a small arena-side flag to skip live suites).
  This catches the I1/I4 regression class on every PR at ~zero toolchain
  cost.
- **Stage 2 (live gates G3+G4).** Requires agda 2.9 on the runner (cached
  install) since P3 drives a live `--enable-interact` session with Mimer.
  Add as a separate, initially non-required job — it is the
  environment-fragile half. agda-deps is *still* not needed if Stage 1's
  prebuilt graphs are used and the X1 robustness/scratch cases are excluded
  or given a cached scratch graph.
- **Stage 3 (full fidelity, optional).** The complete `--suite all` with
  agda-deps building graphs in CI — only worth it once Stages 1–2 have run
  green for a while; nightly, not per-PR.

Prerequisite housekeeping (arena side): parameterize `conditions.yaml`'s
`source:`/`repo:` paths by env var; add the suite-subset flag to
`ci_gate.py`; fill the `repository:` placeholder in the workflow.

**Verify.** The gate failing is the verification: revert the I1 fix locally
(`git stash` the GoalCanon changes) and confirm Stage 1 goes red; restore
and confirm green.

---

## 7. VerinaAgda A/B re-run — close the gap (TODO)

**Problem.** The original A/B showed no proof-metric lift; the two root
causes found (I1 find_lemma recall, I2 auto without hints) are fixed, plus
the benchmark-side config issues (tool-mode, prebuilt sig graph — see the
memory notes) — but the headline number was never re-measured.

**Fix.** Re-run the A/B with: the current binary, the `--with-signatures
--with-term-hashes` prebuilt graph shipped to the agent, and the
availability hint from the P1 experiments (R7 evidence: hint took rung-b
from 28 turns/$0.195 to 6 turns/$0.083). Record per-rung deltas, not just
the aggregate — the powered-P1 finding was that the tools are only invoked
where there's no headroom; the interesting number is uptake-when-stuck on
rung-c/e. If lift still ≈ 0, the next lever is ergonomics (item 9 /
"which tool when stuck" advisor), not retrieval quality.

**Where.** VerinaAgda repo (`scripts/micro_bench.py`, agent harness);
nothing to change here unless the re-run files new requests.

---

## 8. Stdlib federation follow-ups (TODO)

Two halves, one here and one producer-side:

- **Consumer: auto-build + auto-register the stdlib overlay on first run.**
  At daemon init (live mode), when the project's `.agda-lib` names
  `standard-library` and no `overlay-graphs:` entry covers it: locate the
  stdlib checkout (via `AGDA_DIR`/library files), run
  `scripts/build-stdlib-graph.sh` in the background (never block the stdio
  loop — same rule as the cold-start path), and hot-register the overlay
  into the next snapshot with a stderr breadcrumb. Cache under
  `cfgOutDir/overlays/<stdlib-sha>.json` so it's a one-time cost. Failure
  degrades to today's behavior (no overlay) with a diagnostic in `status`.
  **Files:** `src/AgdaMcp/State.hs` (init + snapshot swap), `Config.hs`.
- **Producer: keep cross-boundary external edges as dangling refs** so
  `callers`/`impact` can cross into the overlay — belongs in agda-deps
  (file with section P).

**Verify.** Fresh daemon on a stdlib-using project with no config: first
`search` of a stdlib name answers within the session once the overlay lands;
`status` shows the overlay + build provenance.

---

## 9. Tool-catalogue grouping (TODO idea, ergonomics)

**Problem.** 13+ read tools and 20+ interact tools overwhelm agents —
measured as schema misuse and wrong-tool choices (R7 evidence), and the
deeper "0 MCP calls when stuck" gap.

**Fix (cheap first pass).** Don't reduce the tools; group the *presentation*:
prefix each description with a category tag (`[orient]` brief/status,
`[find]` search/locate/type_of, `[trace]` callers/callees/impact/path/roots,
`[reuse]` find_lemma/similar_*, `[prove]` check/goal_*/auto/…,
`[write]` give/…) and put a 3-line "which tool when — especially when your
proof is failing, try `lemmas`/`auto`/`case_split` before writing by hand"
routing note in the `brief` and `check` outputs (the two tools every session
hits). The tool-usage histogram in `status` measures whether routing
improves. Full catalogue reduction only if grouping doesn't move the
uptake-when-stuck number (item 7's re-run provides it).

**Files.** `src/AgdaMcp/Tools.hs`, `src/AgdaInteract/Tools.hs` (description
literals + brief/check footers), plugin skill text.

---

## 10. `format: json` for `unused` (TODO, low)

`unused` shells out to `agda-unused`, so JSON means threading a
stdout-JSON flag through the subprocess: add `--json-out-stdout` to
agda-unused (its `--json-out` currently writes files; `AgdaUnused.Json`
already renders the array), and have `runUnused` pass it plus
`format:json` passthrough. Low priority — do opportunistically when next
touching either side.

---

## 11. Structural goal canonicalisation (TODO, Round-6 P5)

Unblocking `agda-goals`' textual canonicaliser requires one of the two
documented paths (producer Backend hook emitting goal-type `Term`s, or a
surface-AST parse of the rendered string) — both documented in
`AgdaGoals.Canon`'s haddock. **Recommendation: keep parked** until a
concrete consumer (e.g. cross-run goal dedup at scale) shows the textual
canon actually mis-bucketing in practice; neither path is cheap and the
textual canon has not been the bottleneck in any arena/Verina finding.
Revisit trigger: a benchmark case where two alpha-equivalent-but-textually-
different goals split a bucket.

---

## P. Producer-side items to file in agda-deps (per 2026-07-09 decision)

Not tracked in this repo's Issues/TODO; consolidated here so the agda-deps
filing session has everything:

1. **R12 — tag every soundness escape in the graph.** Today only postulates
   get `state: P`; `NON_TERMINATING`, `TERMINATING`, `primTrustMe`/`trustMe`
   bodies, `--type-in-type`/`--no-positivity-check` modules are plain
   `state: D`. Ask: per-def safety flags (or a `pragmas`/`unsafe` field) in
   the v2 schema. Consumer follow-up here once the wire carries it: an
   `unsafe`/`audit` query enumerating escapes by kind + `roots` integration
   (gate: arena A1 recall 2/5 → 5/5).
2. **R14 — emit the `renaming` map on re-exports.** `ReExport` carries
   canonical FQNs only (`rxNames`); `open import M public renaming (foo to
   bar)` loses `bar`. Ask: `renames: [{from, to}]` per re-export row.
   Consumer follow-up here: alias table consulted by `rankedMatches` /
   `locate`/`type_of` resolution (gate: arena X2-v2 `Reexports.combine`).
3. **I6c — record parse failures in `failedModules`** (or a distinct
   `parseFailedModules`) under `--keep-going`, so the consumer's
   `--require-well-typed` gate covers unparseable sources with no
   heuristics (see item 1).
4. **Federation — flag to keep cross-boundary external edges as dangling
   refs** (from the stdlib-federation TODO), letting `callers`/`impact`
   cross into an overlay graph.

Remember the cross-repo invariants when any of these land: `AgdaGraph.Schema`
mirrors the wire in step, and a node-naming change bumps `nodeKeyVersion` in
both repos.
