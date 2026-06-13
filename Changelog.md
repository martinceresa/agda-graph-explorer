# Changelog

## Unreleased

### Bridge batching, cold-start fallback, parallel goals (2026-06-13)

- **`agda-explore`: `give_many`** (bridge) — fill several open goals in one
  shot against a single live session, so the (possibly minutes-long) module
  load is paid ONCE instead of reloaded between gives. Each term is
  Agda-validated + guarded; returns one combined unified diff; atomic — if
  any term is rejected, nothing is applied and the error names the goal.
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
  left untouched. `auto` (Mimer) is wired but degrades on Agda 2.9.0,
  whose IOTCM reader rejects `Cmd_autoOne` — use `refine`/`give`.
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
