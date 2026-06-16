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

This project ships an MCP server, **`agda-explore`**, that holds the Agda
library's dependency graph in memory and answers point queries over it. It
is built from `agda-deps` (the Agda compiler backend that elaborates the
project) and its sibling analyses, so its answers come from Agda's real
elaborated graph — not a text scan.

**Prefer these tools over `grep`/`rg`/`Glob` for structural questions.** A
grep over an Agda corpus is slow, misses references that flow through
`with`/instance resolution, and re-reads files every time. The graph is
elaborated once and reused; queries are instant.

## The graph stays live

The server regenerates the graph on the fly: before answering, it checks
whether any source file changed and, if so, re-runs `agda-deps` (reusing
Agda's `.agdai` cache, so only edited modules re-elaborate) and hot-swaps
the in-memory graph. You normally never need to think about this — just
query. After a large edit you can call **`rebuild`** to force it, or
**`status`** to see freshness and graph statistics. `status` also reports
the running binary (path + mtime) and warns with a `⚠` line if a newer
`agda-explore` build is on disk — a live daemon can't swap its own
executable, so reconnect (`/mcp`) to pick it up.

(Operator-facing only: if the server was started with `--inspect`, a human
can watch your tool calls and proposed edits live in a browser. This doesn't
change how you use the tools — just query and edit as normal.)

If a query reports "no entry configured", the project wasn't auto-detected:
set `AGDA_EXPLORE_ENTRY` (the entry module, e.g. `agda-src/Main.lagda.md`)
and `AGDA_EXPLORE_INCLUDE` (the include dir) in the environment, or pass a
fixed graph with `--graph`.

## Which tool for which question

| You want to know…                                   | Use            |
|-----------------------------------------------------|----------------|
| Where is `X` defined? (module, file:line, kind)     | `locate`       |
| Who calls / uses `X`?                                | `callers`      |
| What does `X` depend on?                             | `callees`      |
| What breaks if I change `X`'s type? (blast radius)   | `impact`       |
| *Why* does `X` depend on `Y`? (shortest chain)       | `path`         |
| Which axioms/postulates does `X` rest on?            | `roots`        |
| What's the type of `X`?                              | `type_of`      |
| What else has a type like `X`'s?                     | `similar_types` |
| What else is *implemented* like `X`?                 | `similar_bodies` |
| Is there an existing lemma whose conclusion matches my goal? | `find_lemma` |
| What's the exact name? List all postulates/holes?    | `search`       |
| Which imports are unused / what's dead?              | `unused`       |
| Graph size / freshness / config                     | `status`       |
| Force a fresh rebuild                                | `rebuild`      |

Names are fully-qualified (`Module.Sub.name`), but any *unique dotted suffix*
resolves on its own — `roundLeader`, or `Theorem3.liveness′` when the bare
name is ambiguous; you only need more of the path to disambiguate. If you
don't know the name at all, run `search` first. `search` also takes `kind`
(`function`/`datatype`/`record`/`postulate`/…) and `state`
(`defined`/`postulate`/`hole`/`failed`) filters: pass them with an *empty*
query to **list** every definition of that kind/state (e.g. audit all
postulates or open holes), and a `module_prefix` filter to scope the list to
a module subtree (e.g. every `datatype` under `Pkg.Sub`). Set
`top_level_only: true` to drop where-block / anonymous-module locals that
otherwise crowd out importable definitions.

Each `where`/anonymous helper is its own node, named with its binding-site
line (`Mod._.QED@388`) so distinct same-named helpers don't merge. `locate`
reports their enclosing top-level `owner`, and `callers`/`callees` annotate
helper lines with `(in `owner`)`.

`callers` and `callees` take `transitive: true` to walk the whole cone
rather than one hop. On a large fan-out, narrow with
`module_prefix: "Pkg.Sub"`, pass `by_module: true` for a per-module count
summary, or pass `provenance: body` (vs `signature`/`where`/`with`) to keep
only genuine term-level uses and drop in-scope/type-level mentions — direct
lines are annotated with their provenance either way. With `transitive: true`
the provenance filter applies to the **first hop** (e.g. who *term*-depends
on `X`, then transitively), not type-level reachability. `impact` is the
transitive-callers query phrased as a change-risk summary (counts + affected
modules) — reach for it before editing a widely-used signature. `path
from=A to=B` returns the shortest dependency chain showing *why* A reaches
B, with each hop annotated by its edge provenance (`—{body}→`/`—{where}→`/…);
pass `k: N` for several distinct shortest chains, or `module_prefix` to keep
the chain inside a subtree. `roots name=T` answers the proof-engineering
question "what assumptions does theorem T ultimately rest on?" — its
transitive postulates/primitives (or a given `kind`/`state`), each with a
witnessing chain. When a project's axioms live in **record fields** rather
than postulates, scope them with `roots T kind=projection
module_prefix=<the Assumptions module>`; pass `by_module: true` for a
per-module count or `chains: false` for a bare list when the root set is
large. `locate` also reports a `blast radius` line (transitive caller /
dependency counts), so it often answers the load-bearingness question
without a follow-up call.

`type_of` returns the *elaborated* type by default (reified from the
type-checker — precise; numeric literals are de-sugared back to numerals,
though instance dictionaries may still show). Pass `source=true` for the
signature exactly as written in the file when the elaborated form is too
noisy.

`similar_types` compares the set of names a definition mentions *in its
signature*; `similar_bodies` compares canonical hashes of elaborated
subterms (true structural similarity). They are fast pairwise proxies for
the `agda-optimization` `silhouette` / `term-cluster` analyses — use those
batch tools when you want a whole-project clustering rather than "what
resembles this one definition".

`find_lemma` is the goal-directed sibling: *before* writing a proof, ask it
whether the project already has a lemma whose **conclusion** (result type)
matches your goal. It has **two modes — pass exactly one**:

- `anchor=<existing def>` — true structural matching by the same
  Weisfeiler–Leman signature fingerprint as `similar_types`. Use when the
  goal shape is already named by some definition in the graph (it needs a
  graph node with edges to fingerprint).
- `goal="<rendered goal type>"` — free-text: it canonicalises the goal,
  takes the conclusion (after the last top-level `→`), and ranks candidate
  signatures by identifier/operator-token overlap (Jaccard) over *their*
  conclusions. This is a name-overlap proxy, **not** WL — an out-of-graph
  string has no edges. Free-text mode needs a signatures-enabled graph (the
  daemon's default); against a signature-less `--graph` it returns a rebuild
  note rather than an empty list. Filter candidates with `kind` /
  `module_prefix`; tune the cutoff with `min_sim` (default 0.3).

## Interpreting `unused` (important caveats)

`unused` runs `agda-unused`. Its findings are not all equal:

- **High-signal:** `using` (a name in a `using (…)` list that's never
  referenced) and `duplicate` (the same module opened twice).
- **Best-effort / noisy:** `blanket`, `defined`, `public`. These over-report
  on `open import X public` re-exporters and on record-field projections in
  anonymous modules.
- **Known false positives:** instance methods, and names used *only* through
  `with` / `with ←` chains, can be reported as dead when they are not.

So: treat a `using`/`duplicate` finding as actionable, but **grep-verify any
deletion candidate** (and walk one call-graph hop with `callers`) before
removing it.

Scope and noise control: `scope` accepts a directory, a file, or a *module
name* (e.g. `Prelude.Init`) — a relative path resolves against the project
root, and a scope covering no module is rejected loudly rather than
returning a misleading "0 findings". To silence a known re-export hub
without narrowing scope, pass `exclude` one or more comma-separated globs
matched against the file path or module name (`**/Init.agda`, `Prelude.*`;
`**` spans directories, `*` stops at `/`). The response header echoes the
resolved scope, effective kinds, and any excludes, so a "0 findings" result
is always self-describing — never silently mis-scoped.

## Editing proofs with the interaction bridge (when enabled)

If the server was started with `--enable-interact` (or `enable-interact:
true` in `.agda-explore.yml`) and `agda` is on `$PATH`, a **write** surface
is available. Use it as the validated alternative to a blind `Write` +
`agda File` in a shell: every tool here is Agda-checked, honours the
**zero-axiom contract** (it refuses `postulate` / a termination-or-coverage
or unsafe-`OPTIONS` pragma / an escape hatch — a plain `Write` can smuggle
one past CI; these tools cannot), and returns a diff (and the remaining
goals).

| You want to…                                          | Use            |
|-------------------------------------------------------|----------------|
| Open a module and see its open goals (ids + positions) | `load`         |
| Type-check a file → structured errors + warnings + open goals | `check` |
| Read a goal's type + in-scope context                  | `goal_type` / `goal_context` |
| Infer / normalise an expression in a goal's context    | `infer` / `normalize` |
| Find an existing lemma whose conclusion matches a goal | `lemmas`       |
| Scaffold a NEW validated module (header, imports, holes) | `new_module` |
| Author a whole file / a new definition (validated)     | `give_file`    |
| Case-split a goal on a variable                        | `case_split`   |
| Refine a goal by a head symbol (`f ?`)                 | `refine`       |
| Fill a goal with a complete term (type-checked)        | `give`         |
| Fill SEVERAL independent goals in one load (one diff)  | `give_many`    |
| Run a planned batch of give/refine/case_split/auto steps | `construct`  |
| Run Mimer proof search to solve a goal                 | `auto`         |
| Build a NEW def in isolation, then splice it in        | `stage` → `promote` (or `discard`) |

**Authoring a whole file (the bridge meets `Write`, validated).** You don't
have to construct everything goal-by-goal — author the way you naturally
would, but route it through the bridge so it lands under the contract:

- A **new module** → `new_module path=<file>`: it writes a correct
  `module … where` header matching the path, literate ```` ```agda ````
  fences for a `.lagda.md` path, `open import …` lines **resolved off the
  dependency graph** from the bare names you list in `imports` (e.g.
  `["Fin","_≤_"]`), and a `name : T` / `name = ?` hole per `defs` stub —
  then type-checks the scaffold. With `write:true` it creates and `load`s
  the file (returning its goals); otherwise it returns the validated
  content for you to write.
- A **whole file or one new definition** → `give_file file=<f>` with either
  `content` (the full file text — also creates a new file) or `append` (a
  definition block to splice onto the end). The whole text is guarded and
  type-checked; you get a diff (or, with `write:true`, it's applied and the
  module reloaded). Prefer this over `Write` whenever the file must honour
  `--safe` / 0-postulate.
- **After editing a file as text** (with `Edit`/`Write`) → `check file=<f>`
  instead of `agda <f>` in a shell. It reuses the warm session + `.agdai`
  cache and returns a ✓/✗ verdict, **every** error and warning, and the
  remaining open goals — so you pivot straight to filling them. Pass
  `content` to dry-run proposed text without writing.

**Driving holes.** `load <file>` first — it returns goals as `g0, g1, …`
with their `(line:col)`; pass an id to the goal tools. By default
`case_split` / `refine` / `give` return a **unified diff without writing** —
apply it, then `load` again. **Or pass `write:true`** and the tool applies
the edit and reloads in one step, returning the diff *and* the refreshed
goal list (one round-trip, more information than a shell recompile — the
preferred way once you trust the step). **Don't cache an id across an edit
you applied yourself:** applying a diff can renumber goals, so re-`load` (or
use `write:true`, which hands back the fresh ids) and re-select on
`(line:col)`. A `give` whose term doesn't typecheck comes back as the
localized Agda error with the file untouched. For several *independent*
holes in a slow-to-load module, `give_many` fills them all against one load
(one atomic combined diff). For a *planned heterogeneous* sequence
(`case_split g0`, then `give g1`, then `refine g2`), `construct` runs the
steps against one warm load and accumulates one diff — each step targets a
goal from the initial load (run it again for holes a split introduces).
`auto` runs Mimer; if it finds nothing, guide it with `refine` or a `give`.
When you're stuck on what to write, `lemmas goal=g0` searches the project
for a definition whose conclusion matches the goal's type — then `give` /
`refine` with it. `.lagda.md` files work; edits stay inside the code block.

`stage` → `promote` remains for building a def in an isolated scratch module
(`.agda-explore/scratch/`) when you want each `load` to re-check only the
scratch's tiny closure rather than the target's whole module; `promote`
splices it in and re-validates the whole real target, and `discard` drops a
dead end. For most new definitions `give_file` / `new_module` are more
direct.

## Good habits

- Lead with `locate`/`type_of` to orient, `callers`/`impact` before editing,
  `similar_bodies`/`similar_types` when looking for a lemma to reuse or a
  pattern to factor. When proving, try `find_lemma` (free-text `goal=` or an
  `anchor=` def) *before* hand-deriving — it surfaces an existing lemma whose
  conclusion already matches the goal.
- Only fall back to reading files or grepping when you need the *prose*
  around a definition, or to verify an `unused` finding.
- When the interaction bridge is enabled and you're *writing* (not just
  reading), prefer it over `Write` + `agda File`: `new_module` / `give_file`
  to author a new module or definition under the zero-axiom contract,
  `check` to validate a file you edited as text and read back the remaining
  goals, `case_split`/`refine`/`give`/`auto` (with `write:true` to apply +
  reload in one step) or `construct` to drive the holes, and `lemmas` when
  you're unsure what term a goal needs. Each step is Agda-validated and the
  diffs keep you in sync.
