---
name: agda-explore
description: >-
  Explore an Agda library by querying its dependency graph instead of
  grepping. Use when working in an Agda project (.agda / .lagda.md) and you
  need to locate a definition, find who calls or uses it, see what it
  depends on, gauge the blast radius of changing it, read its type, find
  structurally or type-similar definitions, or hunt unused imports / dead
  code. If the server is started with --enable-interact, also use it to
  WRITE Agda under a zero-axiom contract: scaffold a new validated module
  (new_module), author a whole file or definition (give_file), type-check a
  file and get structured errors + remaining goals (check), drive holes with
  a batch of steps (construct: give / refine / case_split / auto, optionally
  writing + reloading in one step), run Mimer proof search on a goal (auto),
  inspect a live goal's type or context (inspect), repair an almost-correct
  file so it typechecks (repair), and find a reusable lemma for a goal
  (lemmas) — all Agda-validated. Backed by the
  `agda-explore` MCP server (from the agda-explore plugin).
---

# Exploring an Agda library with agda-explore

`agda-explore` is an MCP server holding the project's Agda dependency graph
(built by `agda-deps` from Agda's real elaborated graph) in memory.

**Prefer these tools over `grep`/`rg`/`Glob` for structural questions** —
grep is slow, misses `with`/instance references, and re-reads every time;
the graph is elaborated once and queries are instant.

The graph stays live: the server re-runs `agda-deps` (reusing `.agdai`) and
hot-swaps it before answering, so just query. `rebuild` forces a refresh;
`status` shows freshness, graph stats, and warns (`⚠`) if a newer binary is
on disk — reconnect (`/mcp`) to pick it up.

If a query reports "no entry configured", set `AGDA_EXPLORE_ENTRY` (entry
module) and `AGDA_EXPLORE_INCLUDE` (include dir), or pass `--graph`.

**Tool tiers.** The plugin advertises the **full** tool set by default
(`--tool-tier full` in its `.mcp.json` args). Under `--tool-tier core` the
catalogue narrows to the read tools plus the validate/diagnose loop (`load`,
`goal_brief`, `inspect`, `check`, `repair`, `lemmas`); the extra structural
reads (`path`, `roots`, `similar_types`, `similar_bodies`) and the
**authoring** tools (`auto`, `construct`, `scratch`, `give_file`,
`new_module`) then stay documented here but absent from `tools/list`. So if a
tool below isn't listed, you're on `core` — the core loop (query → edit →
`check` → `repair`) covers most work regardless.

## Which tool for which question

| You want to know…                                   | Use            |
|-----------------------------------------------------|----------------|
| **Orient on `X` in one call** (location + type + callers + callees + twins) | **`brief`** |
| Where is `X` defined? (module, file:line, kind)     | `locate`       |
| Who calls / uses `X`?                                | `callers`      |
| What does `X` depend on?                             | `callees`      |
| What breaks if I change `X`'s type? (blast radius)   | `impact`       |
| *Why* does `X` depend on `Y`? (shortest chain)       | `path`         |
| Which axioms/postulates does `X` rest on?            | `roots`        |
| What's the type of `X`?                              | `type_of`      |
| What else has a type like `X`'s?                     | `similar_types` |
| What else is *implemented* like `X`?                 | `similar_bodies` |
| Is there a library lemma that matches my goal?       | `find_lemma`   |
| What's the exact name? List all postulates/holes?    | `search`       |
| Which imports are unused / what's dead?              | `unused`       |
| Graph size / freshness / config                     | `status`       |
| Force a fresh rebuild                                | `rebuild`      |

- Names: any *unique dotted suffix* resolves (`roundLeader`); add more path
  to disambiguate. Don't know the name? `search` first.
- `search` filters by `kind` / `state`; pass an empty query to **list** all
  of a kind/state (audit postulates or holes), `module_prefix` to scope,
  `top_level_only: true` to drop where/anonymous locals.
- `search mode=text` ripgreps the source bytes instead of the graph — use it
  for pragmas, comments, `using`-lists and regexes the graph doesn't index.
  Those hits are always current, independent of the graph snapshot.
- `search unsafe=any` is an `agda --safe`-style audit: every definition
  carrying a soundness escape. Name one instead of `any` to narrow — a
  declaration kind (`non-terminating` / `trustme`) or a module OPTIONS flag
  (`--type-in-type`, `--no-positivity-check`, …). Combine with an empty
  `query` to enumerate.
- `search` / `callers` / `callees` take `format: json` for a structured
  `{tool, query, total, shown, items}` envelope (scripting); default is prose.
- A result tagged `[external: <lib>]` comes from a federated overlay graph
  (e.g. stdlib): it needs an `open import` before use, and edge queries
  (`callers`/`impact`/`path`) don't cross into it.
- `where`/anonymous helpers are own nodes (`Mod.QED@388`); `locate` reports
  their `owner`, `callers`/`callees` annotate them with `(in owner)`.
- `callers`/`callees`: `transitive: true` walks the whole cone;
  `module_prefix` narrows; `by_module: true` gives per-module counts;
  `provenance: body` (vs `signature`/`module-local`/`unknown`, with
  `where` accepted as a legacy spelling of `module-local`) keeps genuine term uses.
  With `transitive`, the provenance filter applies to the first hop.
- `impact` = transitive-callers as a change-risk summary — run before editing
  a widely-used signature. `locate` also prints a `blast radius` line.
- `path from=A to=B`: shortest chain showing why A reaches B (hops annotated
  by provenance); `k: N` for several, `module_prefix` to stay in a subtree.
- `roots name=T`: T's transitive postulates/primitives, each with a witness
  chain. For record-field axioms use `kind=projection module_prefix=<mod>`;
  `by_module: true` for counts, `chains: false` for a bare list.
  `unsafe=any` turns it into a *transitive* soundness audit — every escape
  reachable through T's dependency cone, each witnessed by its chain.
- `type_of`: elaborated type by default; `source=true` for the written
  signature when the elaborated form is noisy.
- `similar_types` compares signature names; `similar_bodies` compares
  elaborated-subterm hashes (true structural). For whole-project clustering
  use `agda-optimization`'s `silhouette` / `term-cluster`.

`find_lemma` — does a library lemma already match my goal? Pass exactly one
mode:
- `anchor=<def>` — WL structural match (needs a graph node with edges).
- `goal="<type>"` — free-text: ranks by operator-weighted coverage of the
  goal's tokens against each lemma's **name + conclusion + algebraic shape**
  (`a⊕b ≡ b⊕a` matches `Commutative`, `x⊕e ≡ x` an identity, …), so a
  combinator-stated lemma like `+-comm` is found. Needs a signatures-enabled
  graph (daemon default). Filter with `kind` / `module_prefix`; tune
  `min_sim` (default 0.3).

## Interpreting `unused` (caveats)

`unused` runs `agda-unused`; findings vary in reliability:
- **High-signal (actionable):** `using` (name in `using (…)` never used),
  `duplicate` (same module opened twice).
- **Noisy / best-effort:** `blanket`, `defined`, `public` — over-report on
  `open import X public` re-exporters and anonymous-module projections.
- **Always low-confidence:** `field` (a record field whose projection is never
  applied; included in `dead`). The edit is to the *record*, not to the
  projection — and a no-eta record matched positionally uses its fields
  without ever applying one, which the graph cannot see.
- **Certain, but a spec change:** `arg-removable` / `arg-erasable` (kinds
  `args`) — arguments a definition never uses. The verdict is Agda's own
  occurrence/polarity analysis, so it is not a heuristic; the confidence
  grades whether the *deletion* is contained (private or no cross-module
  user), because removing a binder changes the definition's type. Two rules:
  a position listed as `(with …)` must be deleted **together** with that set,
  and the indices count **implicits** and refer to the definition's own
  signature line — not to what `type_of` prints, which for a `where` helper
  or a parametrised-module definition still shows inherited binders. The
  report spells each binder the way the signature does (`0 {a}`, `3 ⦃d⦄`,
  `0 m`); a position flagged *inserted by a `variable`* has no binder on the
  line at all — delete the whole set and it goes away with it.
  Needs a graph whose producer emits `argUsage`. These are the one class of
  finding a `check` can never raise — Agda warns about no argument a
  definition fails to use — so when the daemon serves its control endpoint,
  the post-edit hook reports them for you after a `✓`; a spare binder you
  just wrote will surface there without your asking.
- **Known false positives:** instance methods, and names used only through
  `with` / `with ←` chains.

So: grep-verify any deletion candidate (and check one `callers` hop) before
removing it.

Scope: `scope` accepts a dir, file, or module name (relative paths resolve
against project root; a no-module scope is rejected loudly). `exclude` takes
comma-separated globs vs file path or module name (`**/Init.agda`, `Prelude.*`).
The response header echoes resolved scope, kinds, and excludes.

## Editing proofs with the interaction bridge (when enabled)

Under `--enable-interact` (or `enable-interact: true`) with `agda` on
`$PATH`, a **write** surface is available. Use it instead of blind `Write` +
`agda File`: every tool is Agda-checked, honours the **zero-axiom contract**
(refuses `postulate` / termination-coverage / unsafe-`OPTIONS` / escape
hatches), and returns a diff plus remaining goals.

| You want to…                                          | Use            |
|-------------------------------------------------------|----------------|
| Open a module and see its open goals (ids + positions) | `load`         |
| **Orient on a goal in one call** (type + context + candidate lemmas) | **`goal_brief`** |
| Type-check a file → errors + warnings + open goals     | `check`        |
| Read a goal's type / context, or infer / normalise an expr | `inspect` (`op=type`/`context`/`infer`/`normalize`) |
| Find an existing lemma matching a goal                 | `lemmas`       |
| Scaffold a NEW validated module (header, imports, holes) | `new_module` |
| Author a whole file / a new definition (validated)     | `give_file`    |
| Drive holes: a SEQUENCE of give/refine/case_split/auto steps in one load (one diff) | `construct` |
| Run Mimer proof search to solve a goal                 | `auto`         |
| Run Mimer over EVERY open goal in one call             | `construct steps=[{op:auto, goal:"*"}]` |
| Build a NEW def in isolation, then splice it in        | `scratch` (`op:open` → `op:promote`, or `op:discard`) |
| Fix an almost-correct file (missing imports / typos) so it typechecks | `repair` |

**Authoring files (validated):**
- New module → `new_module path=<file>`: writes the `module … where` header,
  `.lagda.md` fences if literate, `open import` lines resolved off the graph
  from bare `imports` names, and a `name = ?` hole per `defs` stub.
- Whole file / one new def → `give_file file=<f>` with `content` (full text,
  also creates new files) or `append` (a block spliced onto the end).
- After editing as text → `check file=<f>` (not `agda <f>`): reuses the warm
  session, returns ✓/✗ + every error/warning + open goals — and probes the
  remaining goals with Mimer, reporting any ready-made solutions inline
  (accept one with `auto goal=gN write:true`, or all with `construct
  steps=[{op:auto, goal:"*"}] write:true`). `content` dry-runs proposed text
  without writing.
- Almost-correct file (unresolved names / typos, not a wrong proof) →
  `repair file=<f>`: interprets the diagnostics to add missing imports
  (resolved off the graph, operators/constructors included) and fix
  misspelled references, driving it to typecheck. Spec-preserving (never
  edits a signature) and zero-axiom; semantic errors are refused, not faked.
  Returns a report + diff (`write:true` applies + reloads). Import repair
  needs a graph covering the file's deps (e.g. `--overlay-graph` for stdlib).

**Driving holes:**
- `load <file>` first → goals as `g0, g1, …` with `(line:col)`; pass an id.
- Then lead with `goal_brief goal=g0`: its type + context + the top reusable
  lemmas in one call. Reach for `inspect op=type` / `lemmas` individually to
  go deeper.
- `construct` is the primary hole-filling interface: a SEQUENCE of
  `{op, goal, …}` steps against one warm load — `give` (needs `term`) /
  `refine` (needs `expr`) / `case_split` (needs `var`) / `auto` → one combined
  diff. Each step targets an ORIGINAL-load goal; a rejected step aborts naming
  the offender (re-run for holes a split introduces).
- By default `construct` returns a diff without writing; **pass `write:true`**
  to apply + reload in one step and get the refreshed goals.
- Ids renumber after an edit — re-`load` (or use `write:true`) and re-select
  on `(line:col)`; never cache an id across an edit you applied yourself.
- A step whose term doesn't typecheck aborts the batch, file untouched.
- `auto` runs Mimer on one goal (`timeout` / `hints` tune);
  `construct steps=[{op:auto, goal:"*"}]` tries EVERY open goal in one call
  (default Mimer budget) and returns one combined diff for the solved ones
  plus the survivors — the cheapest first move whenever a `check`/`load`
  leaves goals open. On a no-solution `auto` retries seeded with the top
  `find_lemma` lemmas for the goal (so one-lemma goals close); if it still
  fails, guide it with a `construct` `case_split`/`refine`/`give` step.
- Stuck? `lemmas goal=g0` finds a lemma matching the goal, then a `construct`
  `give`/`refine` step uses it.
- `.lagda.md` works; edits stay inside the code fence.
- `scratch op:open` (optionally `target=<file>` to seed imports) builds a def
  in an isolated scratch module (faster re-check), then `scratch op:promote`
  splices + re-validates the target; `scratch op:discard` drops a dead end.
  For most new defs, `give_file` / `new_module` are more direct.

## Good habits

- Lead with `brief name=X` to orient on a definition (one call ≈ `locate` +
  `type_of` + `callers` + `callees` + `similar_bodies`); drill in with the
  individual tools only when a section warrants it. `impact` before editing a
  widely-used signature. When proving, try `find_lemma` *before* hand-deriving.
- Fall back to reading/grepping only for the *prose* around a definition or to
  verify an `unused` finding.
- When writing, prefer the bridge over `Write` + `agda File`: `new_module` /
  `give_file` to author, `check` to validate text edits, `construct`
  (give / refine / case_split / auto steps, `write:true` to apply + reload) or
  `auto` to drive holes, `lemmas` when unsure what a goal needs.
