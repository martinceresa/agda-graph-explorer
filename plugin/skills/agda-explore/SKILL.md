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
  file and get structured errors + remaining goals (check), drive holes
  goal-by-goal (case_split / refine / give / auto, optionally writing +
  reloading in one step), batch several fills (construct), and find a
  reusable lemma for a goal (lemmas) — all Agda-validated. Backed by the
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
| Is there a lemma whose conclusion matches my goal?   | `find_lemma`   |
| What's the exact name? List all postulates/holes?    | `search`       |
| Which imports are unused / what's dead?              | `unused`       |
| Graph size / freshness / config                     | `status`       |
| Force a fresh rebuild                                | `rebuild`      |

- Names: any *unique dotted suffix* resolves (`roundLeader`); add more path
  to disambiguate. Don't know the name? `search` first.
- `search` filters by `kind` / `state`; pass an empty query to **list** all
  of a kind/state (audit postulates or holes), `module_prefix` to scope,
  `top_level_only: true` to drop where/anonymous locals.
- `search` / `callers` / `callees` take `format: json` for a structured
  `{tool, query, total, shown, items}` envelope (scripting); default is prose.
- A result tagged `[external: <lib>]` comes from a federated overlay graph
  (e.g. stdlib): it needs an `open import` before use, and edge queries
  (`callers`/`impact`/`path`) don't cross into it.
- `where`/anonymous helpers are own nodes (`Mod.QED@388`); `locate` reports
  their `owner`, `callers`/`callees` annotate them with `(in owner)`.
- `callers`/`callees`: `transitive: true` walks the whole cone;
  `module_prefix` narrows; `by_module: true` gives per-module counts;
  `provenance: body` (vs `signature`/`where`/`with`) keeps genuine term uses.
  With `transitive`, the provenance filter applies to the first hop.
- `impact` = transitive-callers as a change-risk summary — run before editing
  a widely-used signature. `locate` also prints a `blast radius` line.
- `path from=A to=B`: shortest chain showing why A reaches B (hops annotated
  by provenance); `k: N` for several, `module_prefix` to stay in a subtree.
- `roots name=T`: T's transitive postulates/primitives, each with a witness
  chain. For record-field axioms use `kind=projection module_prefix=<mod>`;
  `by_module: true` for counts, `chains: false` for a bare list.
- `type_of`: elaborated type by default; `source=true` for the written
  signature when the elaborated form is noisy.
- `similar_types` compares signature names; `similar_bodies` compares
  elaborated-subterm hashes (true structural). For whole-project clustering
  use `agda-optimization`'s `silhouette` / `term-cluster`.

`find_lemma` — does a lemma's **conclusion** already match my goal? Pass
exactly one mode:
- `anchor=<def>` — WL structural match (needs a graph node with edges).
- `goal="<type>"` — free-text: ranks signatures by token overlap (Jaccard)
  over their conclusions; needs a signatures-enabled graph (daemon default).
  Filter with `kind` / `module_prefix`; tune `min_sim` (default 0.3).

## Interpreting `unused` (caveats)

`unused` runs `agda-unused`; findings vary in reliability:
- **High-signal (actionable):** `using` (name in `using (…)` never used),
  `duplicate` (same module opened twice).
- **Noisy / best-effort:** `blanket`, `defined`, `public` — over-report on
  `open import X public` re-exporters and anonymous-module projections.
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
| Read a goal's type + in-scope context                  | `goal_type` / `goal_context` |
| Infer / normalise an expression in a goal's context    | `infer` / `normalize` |
| Find an existing lemma whose conclusion matches a goal | `lemmas`       |
| Scaffold a NEW validated module (header, imports, holes) | `new_module` |
| Author a whole file / a new definition (validated)     | `give_file`    |
| Case-split a goal on a variable                        | `case_split`   |
| Refine a goal by a head symbol (`f ?`)                 | `refine`       |
| Fill a goal with a complete term (type-checked)        | `give`         |
| Fill SEVERAL independent goals in one load (one diff)  | `give_many`    |
| Run a planned batch of give/refine/case_split/auto     | `construct`    |
| Run Mimer proof search to solve a goal                 | `auto`         |
| Run Mimer over EVERY open goal in one call             | `auto_all`     |
| Build a NEW def in isolation, then splice it in        | `stage` → `promote` (or `discard`) |

**Authoring files (validated):**
- New module → `new_module path=<file>`: writes the `module … where` header,
  `.lagda.md` fences if literate, `open import` lines resolved off the graph
  from bare `imports` names, and a `name = ?` hole per `defs` stub.
- Whole file / one new def → `give_file file=<f>` with `content` (full text,
  also creates new files) or `append` (a block spliced onto the end).
- After editing as text → `check file=<f>` (not `agda <f>`): reuses the warm
  session, returns ✓/✗ + every error/warning + open goals — and probes the
  remaining goals with Mimer, reporting any ready-made solutions inline
  (accept one with `auto goal=gN write:true`, or all with `auto_all
  write:true`). `content` dry-runs proposed text without writing.

**Driving holes:**
- `load <file>` first → goals as `g0, g1, …` with `(line:col)`; pass an id.
- Then lead with `goal_brief goal=g0`: its type + context + the top reusable
  lemmas in one call. Reach for `goal_type` / `lemmas` individually to go deeper.
- Default `case_split`/`refine`/`give` return a diff without writing; **pass
  `write:true`** to apply + reload in one step and get the refreshed goals.
- Ids renumber after an edit — re-`load` (or use `write:true`) and re-select
  on `(line:col)`; never cache an id across an edit you applied yourself.
- A `give` that doesn't typecheck returns the localized error, file untouched.
- `give_many` fills several independent holes against one load (one atomic
  diff). `construct` runs a planned heterogeneous sequence against one warm
  load (re-run for holes a split introduces).
- `auto` runs Mimer on one goal; `auto_all` tries EVERY open goal in one
  call (per-goal `timeout`, default 5s) and returns one combined diff for
  the solved ones plus the survivors — the cheapest first move whenever a
  `check`/`load` leaves goals open. If Mimer finds nothing, guide it with
  `refine`/`give`.
- Stuck? `lemmas goal=g0` finds a def whose conclusion matches the goal, then
  `give`/`refine` with it.
- `.lagda.md` works; edits stay inside the code fence.
- `stage` → `promote` builds a def in an isolated scratch module (faster
  re-check) then splices + re-validates the target; `discard` drops a dead
  end. For most new defs, `give_file` / `new_module` are more direct.

## Good habits

- Lead with `brief name=X` to orient on a definition (one call ≈ `locate` +
  `type_of` + `callers` + `callees` + `similar_bodies`); drill in with the
  individual tools only when a section warrants it. `impact` before editing a
  widely-used signature. When proving, try `find_lemma` *before* hand-deriving.
- Fall back to reading/grepping only for the *prose* around a definition or to
  verify an `unused` finding.
- When writing, prefer the bridge over `Write` + `agda File`: `new_module` /
  `give_file` to author, `check` to validate text edits, `case_split` /
  `refine` / `give` / `auto` (`write:true` to apply + reload) or `construct`
  to drive holes, `lemmas` when unsure what a goal needs.
