# Issues

Reported defects on the graph consumers. For forward-looking work see
[TODO.md](TODO.md); for deferred/refused ideas see [Backlog.md](Backlog.md) and
[Deferred.md](Deferred.md); for shipped work see [Changelog.md](Changelog.md).

---

## Open

### I1 — `find_lemma` free-text (goal) mode has near-zero recall on standard goals

- **Reported:** 2026-07-08 (Martin Ceresa), from the VerinaAgda MCP A/B benchmark.
- **Resolved:** 2026-07-08 — see [Resolution](#resolution-2026-07-08). `find_lemma`
  goal mode now scores **10/10** (median rank 1) on `micro_bench.py` (was 2/10),
  and the interactive `lemmas` front-end inherits the fix (closes I2's lemma
  half). NB: the root-cause analysis below is partly wrong (see Resolution).
- **Component:** `src/AgdaMcp/Query.hs` → `queryFindLemma` / `freeTextMode`
  (live-goal front-end in `src/AgdaInteract/Tools.hs:1893`); token/shape
  machinery in `src-agda-graph/AgdaGraph/GoalCanon.hs`.
- **Severity:** high for the "help an agent prove" use case — this is the one
  read tool that maps a proof obligation to a reusable lemma, and it missed.

#### Summary

Given a concrete goal type, `find_lemma goal=…` finds the lemma that actually
closes it in only **2 of 10** textbook cases, even with a generous
`min_sim=0.05 limit=25`. Naive `ripgrep` of the concrete goal fragment over the
stdlib source does **5/10** at ~10× less output to read. The tool's ranked list
is dominated by irrelevant candidates while the correct lemma is unranked.

#### Environment

- `agda-explore` 1.1 (git afd2a61d), ghc 9.14.
- Graph: agda-stdlib v2.4 closure of a Verina-solver seed module (Data.Nat/Int/
  List/Bool/Maybe/Product/Sum/Fin/Char/String + Properties), built with
  `agda-deps … --json-mode=expanded --with-signatures --with-term-hashes`
  (7185 defs, 7008 typed). Signatures ARE present — this is not the "graph
  carries no type signatures" degradation.

#### Repro

```bash
G=stdlib-graph-sig.json   # expanded graph built WITH --with-signatures
agda-explore query find_lemma goal="∀ n → n + 0 ≡ n" --graph "$G"
#   -> "No lemmas with conclusion-token overlap ≥ 0.3 …
#       (goal conclusion tokens: `+`, `≡`)"
agda-explore query find_lemma goal="∀ n → n + 0 ≡ n" min_sim=0.0 limit=25 --graph "$G"
#   -> 25 candidates, ALL Data.Integer.Properties.* at 28.6% — `+-identityʳ`
#      never appears at any threshold.
```

Ground-truth set (goal → lemma that closes it) and results:

| goal | wanted lemma | find_lemma | grep goal-fragment |
|---|---|---|---|
| `n + 0 ≡ n` | `+-identityʳ` | miss | hit |
| `m + n ≡ n + m` | `+-comm` | miss | miss |
| `(m+n)+p ≡ m+(n+p)` | `+-assoc` | miss | miss |
| `xs ++ [] ≡ xs` | `++-identityʳ` | miss | hit |
| `length (xs++ys) ≡ …` | `length-++` | **hit (rank 1)** | miss |
| `reverse (reverse xs) ≡ xs` | `reverse-involutive` | miss | hit |
| `m * n ≡ n * m` | `*-comm` | miss | miss |
| `n ≤ n` | `≤-refl` | miss | miss |
| `map f (xs++ys) ≡ …` | `map-++` | **hit (rank 7)** | hit |
| `length (map f xs) ≡ …` | `length-map` | miss | hit |

Harness + full data: `VerinaAgda/scripts/micro_bench.py`,
`VerinaAgda/bench/results-micro/`.

#### Root cause

`freeTextMode` (Query.hs:1052) ranks candidates by
`tokenJaccard gtoks ts`, where both token sets are the **identifier tokens of
the canonicalised _conclusion_** (`sigConclTokens`). Two representation
mismatches make the Jaccard ~0 for the common cases:

1. **Abstract combinator forms.** stdlib states most rewrite lemmas via
   `Algebra.Definitions` / `Relation.Binary` combinators, so the *stored
   conclusion is the whole abstract application*, e.g.

   ```
   +-identityʳ        : RightIdentity _≡_ 0 _+_
   +-comm             : Commutative   _≡_ _+_
   +-assoc            : Associative   _≡_ _+_
   reverse-involutive : Involutive    _≡_ reverse
   ≤-refl             : Reflexive     _≤_
   ```

   The goal's conclusion tokens are `{+, ≡}`; the lemma's are
   `{RightIdentity, _≡_, _+_}`. These sets are **disjoint**, so the correct
   lemma is unrankable at *any* `min_sim` (confirmed at `min_sim=0.0`). This is
   not the exotic case — it is how the most-reached-for arithmetic/order lemmas
   are written.

2. **Token normalisation.** Even when both sides are concrete, tokens don't
   line up: infix use yields bare `≡`/`+`/`++` while the stored signature
   carries fully-qualified underscore forms
   (`Relation.Binary.PropositionalEquality._≡_`, `Data.List._++_`). This is why
   `map-++` lands at rank 7 (buried) and `length-map` misses despite being
   stated concretely.

`anchor` mode (WL fingerprint over signatures) is not a workaround: it needs an
existing definition of the same shape as the anchor, which the agent doesn't
have when all it holds is a goal type.

#### Impact

In the VerinaAgda A/B (agent solves Agda tasks with vs without this MCP), the
MCP produced **no pass-rate improvement** on the proof metric. Two contributing
reasons, both about lemma retrieval:
- the benchmark's shipped graph had no signatures, so `find_lemma` was disabled
  outright (a config issue on the consumer side); and
- even correctly configured, `find_lemma` can't map a real goal to its stdlib
  lemma (this issue). So the one capability that could raise proving success is
  ineffective.

#### Suggested fixes (in rough order of value)

1. **Match against the elaborated/unfolded conclusion, not the surface
   combinator application.** Reduce `RightIdentity _≡_ 0 _+_` to its unfolded
   statement `∀ x → x + 0 ≡ x` before tokenising (the elaborator already knows
   this; `--normalise-signatures` may partly help — worth checking whether it
   makes these rankable). Without this, the abstract-form lemmas — the bulk of
   the useful ones — are permanently invisible to goal search.
2. **Normalise tokens before Jaccard:** strip module qualifiers and unify
   infix/underscore operator spellings so `≡` ≡ `_≡_` and `Data.List._++_` ≡
   `++`. Cheap, and fixes the rank-7/miss cases for concretely-stated lemmas.
3. **Rank by more than conclusion tokens:** a type-directed / unification-aware
   match (à la Agsy/Mimer or Haskell's Hoogle type search) would beat bag-of-
   tokens Jaccard. The `--auto-hints` Mimer probe already in `check` suggests
   the machinery is close at hand.
4. **Fail louder on low recall:** when the top score is far below `min_sim`,
   say so and suggest `search`/`grep`, rather than returning an empty/again
   near-empty list that reads as "no such lemma exists."

#### Consumer-side note (not an agda-explore bug)

Ship the read graph built `--with-signatures --with-term-hashes`, else
`find_lemma` / `similar_types` / `similar_bodies` are silently unavailable. The
"rebuild with signatures enabled" message is correct and clear; consider making
the plugin's default prebuilt-graph recipe include these flags so the tools are
never dark by accident.

#### Resolution (2026-07-08)

The reported token-level root cause was **imprecise**. Dumping the real stored
signatures showed the current tokenizer already reduces `_≡_`→`≡` and `_+_`→`+`,
so the abstract forms were *not* disjoint from the goal (`+-identityʳ` scored
0.25, not zero). The real killers, confirmed on the 7185-def graph:

1. **Qualifier noise.** Stored sigs are fully qualified
   (`Data.Nat._+_`, `Relation.Binary.PropositionalEquality._≡_`); the tokenizer
   kept every path component (`Data`, `Nat`, `Relation`, `Binary`, …) as a
   token. The goal is unqualified, so Jaccard clustered lemmas by *module*, not
   math, and the tight wanted lemma lost to noisier candidates.
2. **Lowercase drop.** `keepIdent` dropped bare-lowercase runs as bound vars —
   nuking the head symbols `map`/`length`/`reverse`, so `length (map f xs) ≡ …`
   collapsed to `{≡}`, indistinguishable from every equality lemma.
3. **Unused def name + symmetric Jaccard.** The def's own systematic name
   (`+-comm`, `length-++`) — often the strongest signal — was never consulted,
   and symmetric Jaccard penalised large signatures.
4. **Operator-only ceiling.** `+-comm`/`+-assoc`/`+-identityʳ` goals all reduce
   to `{+, ≡}`; no token metric can separate them.

**Fix** (`GoalCanon.hs` + `freeTextMode`): (1) `matchTokens` reduces a qualified
name to its last component and (2) keeps a lowercase run only when it is a known
definition base-name (graph-backed vocabulary); (3) `nameTokens` folds the
candidate's own name (split on the `-` separator) into the match bag and scoring
switched to operator-weighted **coverage** + Jaccard tiebreak; (4) low-recall
now points at `search`/ripgrep instead of a bare empty list; (5) `shapeTokens`
recognises the goal's algebraic shape (`a⊕b ≡ b⊕a` → `Commutative`, `x⊕e ≡ x` →
`Identity`, `f (f x) ≡ x` → `Involutive`, `R x x` → `Reflexive`, …) and injects
the matching `Algebra.Definitions` combinator token — which the stored sigs
already carry — cracking the operator-only ceiling.

Result on `micro_bench.py` (real agda-stdlib sig graph): find_lemma **2/10 →
10/10** in-top-25, median rank 1; e.g. `reverse-involutive` 633→1, `length-map`
163→1, `+-comm` →1, `+-identityʳ` →2. Unit-tested in `test/Spec.hs`
(`goalCanonTests`).

---

### I2 — interactive proof-completion tools (`auto`, `lemmas`) don't advance the substantive goal

- **Reported:** 2026-07-08 (Martin Ceresa), from the VerinaAgda interactive-tool
  micro-benchmark (live `--enable-interact` server).
- **Resolved:** 2026-07-08 — both halves fixed. The **`lemmas` half** via I1
  (`lemmas` delegates to `queryFindLemma`, now name/shape-aware). The **`auto`
  half** by coupling the two: on a no-solution, `auto`/`auto_all` now seed Mimer
  with the top graph-ranked lemma names for the goal type and retry. See
  [Resolution](#resolution-2026-07-08-1).
- **Component:** `auto` → `src/AgdaInteract/Tools.hs:172` (Mimer bridge;
  no-solution message at `Tools.hs:550`); `auto_all` → `Tools.hs:183` /
  `runAutoAll`; `lemmas` → `Tools.hs:1893` (live front-end to `queryFindLemma`).
- **Severity:** high for the "help an agent prove" use case — with a live Agda
  session, these are the two tools an agent reaches for to *close* a goal, and
  on a real obligation both come up empty.
- **Related:** the `lemmas` half is the interactive manifestation of **I1**;
  fixing I1 fixes it. The `auto` half is independent.

#### Summary

Driving the live server over stdio (no model in the loop) on a two-hole file,
the informational interactive tools work well — `check` enumerates goals *with
types*, `goal_type`/`goal_context`/`infer`/`normalize`/`case_split` all return
useful structured proof-state that batch `agda` cannot give. But the two tools
that would actually *finish* a proof fail on the one non-trivial goal:

- `auto` solves the boilerplate hole (`ℕ` → `zero`) but returns **"found no
  solution"** for `n + zero ≡ n`.
- `lemmas` on the same goal returns **no candidates** (misses `+-identityʳ`).

So an agent that has paid for the live session still gets no help completing the
substantive step — it must fall back to writing the proof by hand.

#### Environment

`agda-explore` 1.1 (git afd2a61d), ghc 9.14, `--enable-interact` with the
`--with-signatures --with-term-hashes` stdlib graph (same as I1). Agda 2.9.0 on
`$PATH` for the interaction session.

#### Repro

`src/Holes.agda`:

```agda
easy : ℕ
easy = {!!}                              -- g0 : ℕ           (trivial)
idr  : ∀ (n : ℕ) → n + zero ≡ n
idr n = {!!}                             -- g1 : n + zero ≡ n (real)
```

Over the MCP session (`check` first to register goals):

```
auto   goal=0  ->  diff: easy = zero                              (PASS — trivial)
auto   goal=1  ->  "auto/Mimer found no solution for this goal
                     — guide it with `refine`, or `give` an explicit term."   (FAIL)
lemmas goal=1  ->  "No lemmas with conclusion-token overlap ≥ 0.3 for goal
                     `n + zero ≡ n`. (goal conclusion tokens: `+`, `≡`)"       (FAIL)
```

`idr` is a one-liner (`idr n = +-identityʳ n`), so both tools miss an
in-scope, single-lemma solution. Harness: `VerinaAgda/scripts/micro_bench_live.py`
(+ `scripts/mcp_client.py`); data in `VerinaAgda/bench/results-micro/live-*`.

#### Root cause

- **`lemmas`** shares `freeTextMode`'s conclusion-token Jaccard with the read-side
  `find_lemma` — same disjoint-token failure as **I1** (goal tokens `{+, ≡}` vs
  the abstract `+-identityʳ : RightIdentity _≡_ 0 _+_`). Fixing I1 fixes this.
- **`auto`** runs Mimer with its default budget and no lemma hints. Mimer here
  neither performs the induction nor discovers/applies `+-identityʳ`, so it
  reports no solution. The two mechanisms are disconnected: the tool that
  *could* name the lemma (`lemmas`) is broken, and Mimer isn't fed candidate
  lemmas to try — so neither path reaches the answer.

#### Impact

Explains the other half of the VerinaAgda A/B proof result (see I1): even with a
live session, the proof-completion tools don't advance real goals, so the agent
gains nothing measurable on the proof metric. `auto` is only useful for holes a
strong model would fill trivially anyway.

#### Suggested fixes

1. **Fix `lemmas` via I1** (unfold combinator forms + normalise tokens). Once
   `lemmas` can name `+-identityʳ`, an agent can `give`/`refine` it directly —
   this alone closes the example without touching Mimer.
2. **Feed Mimer the `find_lemma`/`lemmas` candidates as hints.** Mimer accepts a
   hint set; seeding it with the top goal-relevant lemmas would let `auto` apply
   `+-identityʳ` instead of searching blind. Couples the two tools that are
   currently independent.
3. **Expose / raise Mimer's budget for `auto`.** `auto_all` already takes a
   `timeout` (default 5s); per-goal `auto` (`Tools.hs:172`) does not surface
   depth/timeout knobs. A deeper or hint-guided search would reach one-lemma and
   short-induction goals that the default misses.
4. **On `auto` failure, chain to the next best action.** The no-solution message
   already suggests `refine`/`give`; also surfacing the top `lemmas` candidates
   (once I1 is fixed) and a `case_split` suggestion would turn a dead end into a
   guided next step.

#### Resolution (2026-07-08)

Both halves fixed. `lemmas` inherits the I1 fix (it delegates to
`queryFindLemma`). For `auto`, a live Agda 2.9 probe pinned down the mechanism
and its constraints:

- Plain Mimer returns `"No solution found"` for `n + zero ≡ n` at *any* budget
  (raising `-t` alone, suggested-fix #3, does nothing) — but **`Cmd_autoOne …
  "-t 5 +-identityʳ"`** (the lemma named as a hint) solves it instantly with
  `+-identityʳ n`. So the fix couples the two tools (suggested-fix #2).
- Constraints found live and designed around: an **unknown/out-of-scope hint
  aborts the whole Mimer call**, and **qualified hint names are rejected** — so
  hints must be the in-scope short name, tried **one at a time** (scope
  resolution is instant, so bad hints cost ~nothing). Unicode names round-trip
  through the `Cmd_autoOne` options string unchanged.

`runAuto`/`autoAllLoop` now: try plain Mimer first (trivial holes), then seed
the top graph-ranked lemma base-names (`goalHintNames`, the shared
`rankGoalCandidates` core behind `find_lemma`) as one-at-a-time hints, first
`GiveAction` wins; report which lemma closed it. New `timeout`/`hints` args
expose/raise the budget (suggested-fix #3). On total failure the message lists
the tried hints and points at `case_split`/`refine`/`lemmas`/`give`
(suggested-fix #4).

Verified on the live server (`micro_bench_live.py` file): `auto goal=1` →
`idr n = +-identityʳ n`; `auto_all` → both holes closed in one diff
(`easy = zero`, `idr n = +-identityʳ n`). NB: `micro_bench_live.py`'s
`auto-real`/`lemmas-real` probes still assert the *old* failure strings, so they
now mis-verdict (`unexpected-solve` / a false `LIMIT` from the word "overlap" in
the new weak-match note) — the probes want updating to expect the solve.

---

### I3 — systematic classes where grep+agda beat the MCP (the "anti-benchmark")

- **Reported:** 2026-07-08 (Martin Ceresa), from the VerinaAgda `anti_bench` harness
  (30-agent ideation fan-out: 90 proposals → 35 consolidated failure modes).
- **Component:** whole read/query surface + the graph-build/serve model, not one tool.
- **Severity:** medium — most of these are *inherent trade-offs* of a snapshot graph
  index (documenting "when NOT to use the MCP" is the main value); a few are genuinely
  actionable (called out below and in I1/I2).
- **Nature:** not a single defect. An LLM agent with only `rg` + `agda` + Read is
  **strictly better** than one using the MCP across four systematic clusters. Each case
  below was executed both ways with no model in the loop; the MCP was observed worse in
  **27 of 28 executable cases** (+10 argued live-only cases). The lone tie
  (`type_of` after an upward line-shift) is a genuine non-reproduction kept as a
  falsifiability check.

#### Findings by cluster

**1. Snapshot staleness — freshness 3/3, correctness 1/2, robustness 1/1.**
A fixed `--graph` never reflects the working tree (rebuilds disabled), and even a live
graph lags. Observed: after a rename `search`/`callers` still list the old name; a
newly-added def is invisible; a deleted def is a phantom node; `callers`/`impact` omit a
caller added after the snapshot, yielding a **false "safe to change"**; a parse error
leaves the graph serving stale answers. `rg`/`agda` always read current bytes.
*Actionable:* emit a staleness signal (graph mtime vs source mtime) on every read, and
never report a confident answer from a graph known to be behind the file.

**2. Definition+edge index only — coverage 9/9, completeness 4/4.**
The graph models Agda definitions and their edges — nothing else. Observed misses that
`rg` finds immediately: definitions outside the entry closure (`Data.Tree.AVL`,
`Text.Printf`, `Data.Vec.Functional`, `Data.Nat.Primality`, `Data.Nat.GCD`, and
**`trustMe`** — an axiom/soundness audit via the graph gives false assurance); text in
comments/strings/pragmas (1201 `{-# OPTIONS`), import/`using` lists (7785), non-Agda
manifests (`.agda-lib`/`.cabal`), numeric literals, and any regex/alternation query
(20390 `foldr|foldl`). *Actionable:* the closure blind spot is the big one — a soundness
`postulate`/`trustMe` audit that silently omits out-of-closure hits is worse than no
audit. Widen the closure or warn explicitly that coverage is partial.

**3. Confidently-wrong retrieval — misleading 6/6.**
The MCP doesn't just miss, it returns high-confidence wrong answers that can burn an
agent's turns: `find_lemma` offers 25 confident candidates with the correct lemma absent
(**I1**); `similar_types` rates 10 genuinely different-typed defs at **100%**
(shape-collapse); `auto write:true` can splice a type-correct-but-wrong term (**I2**).
*Actionable:* covered by I1/I2; additionally `similar_types` should not report 100% for
defs whose rendered types differ.

**4. Round-trip + build tax — cost 2/2, overhead 1/1.**
For the single-file, already-located lookups that dominate small tasks: a `type_of`/
`locate` query is ~535 ms / ~250–360 B versus `rg` at ~2 ms / ~30–50 B (~250× latency),
and query mode re-parses the graph each call; the initial graph build was ~10 s for a
3-module toy (seconds-to-minutes on a real repo) — setup `rg`+`agda` never pay.
*Inherent:* this is the amortization trade-off — the MCP wins only when the graph is
reused across many cross-file queries on a large, stable codebase.

#### Takeaway (where NOT to use the MCP)

Small, single-file, fast-changing work (e.g. the Verina tasks) hits all four clusters at
once: nothing to navigate, an edit-query loop that staleness poisons, and a per-query
tax with no amortization. The MCP earns its keep on **large, stable, multi-file**
codebases with **iterative proof development** — the opposite regime.

#### How to reproduce

The harness lives in the VerinaAgda project (a sibling of this repo), which wires this
server against an agda-stdlib graph.

```bash
cd <VerinaAgda>                      # e.g. ~/Repositories/Projects/VerinaAgda
python3 scripts/anti_bench.py        # -> bench/results-anti/{summary.txt,results.json}
```

Prereqs: `rg`, `agda`, `agda-deps`, the `agda-explore` binary (auto-located, or set
`AGDA_EXPLORE_BIN`), and both stdlib graphs in `bench/mcp/` (`stdlib-graph.json` and the
signatures/term-hashes `stdlib-graph-sig.json`). First run builds a 3-module scratch
snapshot under `bench/microbench/anti/` (delete `anti/out/` to force a fresh build).
Cases live in `bench/microbench/anti_cases.json` (`kind: non_executable` = argued only);
design notes in `bench/microbench/ANTI_README.md`. The complementary "where the MCP
*wins*" benchmark is `scripts/micro_bench.py` (read tools) and `scripts/micro_bench_live.py`
(interactive tools). The 30-agent ideation fan-out that generated the cases is the
`anti-bench-ideation` workflow.

---

### I4 — `similar_types` reports 100% for definitions whose rendered types differ

- **Reported:** 2026-07-09 (MCPBenchArena R5, from the X1 anti-benchmark case
  `similar-types-false-100`; also I3 cluster 3).
- **Resolved:** 2026-07-09 — see [Resolution](#resolution-2026-07-09).
- **Component:** `src/AgdaMcp/Query.hs` → `sigSimilarCands` (the shared core:
  `similar_types` **and** `find_lemma` anchor mode).
- **Severity:** medium — a confident false positive that can burn an agent's
  turns (it reads "100%" as "same type").

#### Summary

The score is `weightedJaccard` over WL *signature-topology* fingerprints
(kind/state/out-degree + neighbour-colour multisets — nothing reflects the
rendered type text), so defs whose types merely share a shape collapse to
identical fingerprints and score exactly 1.0. Measured on the arena stdlib sig
graph: `similar_types name=Data.Nat.Properties.+-identityʳ` rated `*-assoc`,
`+-comm`, `*-zeroʳ` — genuinely different types — at **100%**.

#### Resolution (2026-07-09)

`capDifferingSig` (Query.hs, applied inside `sigSimilarCands` so
`find_lemma`'s anchor mode inherits it): when both defs carry a rendered
signature (`defSig`, producer `--with-signatures`) and the
whitespace-normalised strings differ, the score is capped at 0.99 — rendered
as 99.0% (`pctOf` rounds to one decimal, so anything above 0.99 could still
display as 100%). Identical rendered types keep 100%; graphs without
signatures are uncapped (nothing to compare). Verified on the arena case:
`*-assoc`/`+-comm` now 99.0%, while a true identical-type twin
(`Data.Integer.Properties.m≤pred[n]⇒m<n` / `i≤pred[j]⇒i<j`) still reads
100.0%.

---

### I5 — `unused --kinds=dead` misses recursive dead code (self-call counted as a caller)

- **Reported:** 2026-07-09 (MCPBenchArena R13, from the A3 dead-code sweep:
  `Deadwood.deadC` — `deadC (suc n) = deadC n`, no other references — missed;
  tool recall 4/5 vs grep 5/5).
- **Resolved:** 2026-07-09 — self-recursion first, then the mutual-recursion
  cycle half (see [Resolution](#resolution-2026-07-09-1) and
  [Cycle resolution](#cycle-resolution-2026-07-09)). Fully closed.
- **Component:** `src/AgdaUnused/Analysis.hs` → `ingestEdge` /
  `definedButUnused`.
- **Severity:** medium — dead-code sweeps under-report exactly the defs most
  likely to be leftovers (retired recursive helpers).

#### Summary

A self-edge in `definitionEdges` populated `ctxIntraModUsedQ`, so a def whose
only reference is its own recursive call was classified
`DefinedInternalOnly` ("intra-module callers only") and never surfaced under
`--kinds=dead`.

#### Resolution (2026-07-09)

Two coupled changes — the obvious one-line guard alone would have made it
*worse* (the def would flip from internal-only to **no finding at all**):

1. `ingestEdge` no longer counts a self-edge as an intra-module caller; the
   def is recorded in a new `ctxSelfRecursive` set instead.
2. The dead branch's in-file token-count fallback (the elaborator-inlining
   suppression: >2 whole-token occurrences ⇒ assume live) is skipped for
   self-recursive defs — their own RHS calls push the count past the
   sig+LHS allowance, which is precisely what the graph's self-edge already
   explains. The cross-file half of the suppression still applies.

Also, the recursive note takes precedence over the Phase-A trivial-body
confidence downgrade (the elaborator never inlines a recursive def), so the
finding reads `deletion candidate (recursive: its only callers are its own
calls)` at High confidence. A def with a self-edge *plus* a real
intra-module caller stays internal-only. Unit-tested both ways in
`test/Spec.hs` (`unusedDeadTests`); verified end-to-end on the arena midproj
fixture (`deadC` flagged, `deadA`/`deadB` unchanged) and `-N1`/`-N4`
byte-identity holds.

#### Cycle resolution (2026-07-09)

The mutual-recursion half is now fixed too. `ingestEdge` additionally
accumulates a per-module directed intra-edge list (the `ctxIntraModUsedQ`
map loses the source structure a graph needs). `computeDeadCycles` runs
`Data.Graph.stronglyConnComp` per module (nodes/adjacency sorted, so it is
deterministic) over the short-name graph; a `CyclicSCC` of size ≥ 2 is dead
as a unit iff every member has an empty `usersClosure` (no cross-module /
re-export user) **and** no intra-module caller from outside the SCC. Members
land in a new `ctxDeadCycles` map (member → peer short-names), and
`definedButUnused` reports each as `DefinedDead` with note
`deletion candidate (dead cycle with B, C)`, skipping the in-file
token-count fallback (peers' calls explain the occurrences) but keeping the
cross-file suppression. agda-unused works on the JSON view and never builds
the `Index`, so the Index-side `AgdaOptimization.Condense` was not reusable —
this is a self-contained pass. Unit-tested in `test/Spec.hs`
(`unusedDeadTests`): `A ↔ B` with no external caller → both dead with the
cycle note; add one external caller of `A` → neither flagged dead. `-N1`/`-N4`
byte-identity re-checked (with a real source root, `--kinds=all`).

---

### I6 — a parse error under default `--keep-going` silently commits a partial graph served as fresh

- **Reported:** 2026-07-09 (MCPBenchArena R11 + the R10 poll aspect, from the
  A2 edit-storm broken-file variant; specializes I3 cluster 1).
- **Component:** `src/AgdaMcp/State.hs` → `runOneEntry` / `commitOrKeep` /
  `ensureFresh`.
- **Severity:** high — a confident false negative: `search` returns "no
  match" for definitions that still textually exist, with no error and no
  staleness flag, on a transient state (a half-typed edit) every editing
  agent passes through.
- **Resolved (mitigated):** 2026-07-09 — every affected answer is now
  *flagged* rather than silently wrong (see
  [Resolution](#resolution-2026-07-09-2)). The complete producer-side fix
  (I6c) stays open in `agda-deps`.

#### Measured (arena A2)

Live `--entry` watcher; editing the source into an unparseable state (delete
a def **and** open an unterminated block comment) makes `search` for
still-existing defs (`aa`, `cc`) return *no match* — no error, no
`# stale:` footer. 2/6 probes poisoned; the graph recovers ~2.2 s after the
parse error is fixed. grep reads current bytes and is unaffected.

#### Root cause (confirmed in-repo)

1. `buildBaseArgs` passes `--keep-going` by default, so `agda-deps` emits a
   **partial** graph on a parse error rather than nothing.
2. `runOneEntry` decides success by `doesFileExist graphPath` **only** — the
   producer exit code is interpolated into the error message but never
   consulted. A partial graph is a "successful" build.
3. `commitOrKeep`'s `--require-well-typed` guard is off by default, so the
   partial graph is promoted. (Correction to the original filing: a live
   probe of `agda-deps` 1.1 showed the unparseable module **does** land in
   `failedModules` — `--keep-going` still exits 0, and with
   `--require-well-typed` off the guard is not consulted. So `ldFailed` is
   populated; it just wasn't surfaced anywhere.)
4. The partial graph is promoted, `ssDirty` clears, and every downstream
   staleness signal (all inferred from *build scheduling*, never from *graph
   content*) reports fresh — and `ldFailed`, though populated, was surfaced
   only by the `--require-well-typed` gate, never on the answer itself.

Mitigation today: `--strict-producer` drops `--keep-going`; the producer then
writes no graph on error, `runOneEntry` returns `Left`, and the failed-build
path keeps the stale snapshot + re-dirties (serve-stale works as designed).

#### Suggested fix

1. `runOneEntry`: consult the producer exit code — "graph file exists but
   the producer reported errors" should withhold (or at minimum stale-flag)
   rather than commit as fresh.
2. Cheap content tripwire: flag a definition-count drop vs the prior
   snapshot on commit. (A def-set identity hash — the R9/arena
   `graph_config_hash` ask — would make such silent drops first-class.)
3. Fully correct fix is cross-repo: the producer records parse failures in
   `failedModules` (or a distinct field) so the consumer can tell
   "partial-but-trustworthy" from "defs silently dropped".

Related R10 poll finding: in `--no-watch` poll mode the *triggering* query is
already answered from the old snapshot **with** the stale footer when
auto-rebuild is on (`ensureFresh` returns `stale=True` before scheduling the
background rebuild) — the arena's 25% poisoning measurement likely includes
post-commit reads, which this issue covers.

#### Resolution (2026-07-09)

Since `ldFailed` is in fact populated on a parse error (root cause #3), the
mitigation is to *surface* it — and to add the content signal that catches
the rarer case where a partial build drops defs without flagging a failed
module. All consumer-side; the withhold behaviour is intentionally left to
the opt-in `--require-well-typed` (withholding by default would discard the
partial progress of modules that *did* rebuild — the reason it is opt-in).

1. **`healthFooter` (`Tools.hs`)** — every read answer (and `runUnused`)
   whose snapshot has a non-empty `ldFailed` now carries
   `# partial: the last build reported N failed/unparseable module(s) …; a
   "no match" here is not authoritative`. Threaded through `withFreshIO`
   (`snapshotFooters`), so it fires in every mode, independent of the
   rebuilding-stale flag. This converts the confident false negative into a
   flagged one — the R11 ask.
2. **`sourceStaleFooter` (`Tools.hs`, R1)** — a snapshot whose backing graph
   file predates a source edit (`ldStaleVsSource`, computed once at load)
   now flags `# stale: the graph file is older than a source file …`. This
   also fires in **preloaded** mode, which `ensureFresh` otherwise reports as
   never-stale.
3. **Content identity hash (`ldContentHash`, I3/R9)** — `status` shows a
   digest over the sorted def set, so a silent def drop is visible even when
   nothing else looks stale, and `status` lists the failed modules + the
   source-vs-graph flag.

Footers are plain text, so they would corrupt a `format:json` answer;
`appendTextFooters` suppresses them when the payload is JSON-shaped (the
staleness/coverage signal is carried in-band there, e.g. `unsearched_files`,
or via `status`) — this also fixed a latent pre-existing bug where
`staleFooter` could append prose after a JSON envelope. Verified on a
crafted `failedModules` graph (footer fires) and a clean one (silent);
`format:json` answers parse cleanly.

**Still open (cross-repo, I6c):** the producer should distinguish a
parse-dropped def set from a trustworthy partial so the consumer needn't
infer from `ldFailed` + content hash. Filed for `agda-deps`.

---

### I7 — `auto` reports a flat "no solution" when its closing hint lemma is out of import scope

- **Reported:** 2026-07-10 (MCPBenchArena R19, from the powered P1 haiku×5
  run, rung-b).
- **Resolved:** 2026-07-10 — see [Resolution](#resolution-2026-07-10).
- **Component:** `src/AgdaInteract/Tools.hs` → `autoSolve` / `runAuto` /
  `runAutoAll`.
- **Severity:** medium-high — a confident false negative on the write-side
  tool an agent reaches for to close a goal: the graph *names* the closing
  lemma, but the answer reads as "unprovable".

#### Summary

`auto`/`auto_all` seed Mimer with the top graph-ranked lemma base-names,
tried one at a time (an out-of-scope hint aborts the whole `Cmd_autoOne` on
Agda 2.9; a qualified name is rejected — hence bare base-names). When the
winning lemma's module is not imported by the file, the hint probe fails with
a `NotInScope` error — which `autoSolve` **computed and then discarded** (the
hint loop bound `(m, _)`), so the hint was indistinguishable from a genuine
Mimer search miss. The final answer was `noSolution hints` — a flat "found no
solution (tried lemma hints: …)". By contrast `give` on the same term
surfaces the raw `NotInScope` verbatim: the server *could* see the
missing-import fact; `auto` swallowed it.

#### Repro (arena `RungB.agda`, goal `n + zero ≡ n`, imports only `Data.Nat`)

- `auto goal=g0` → `auto/Mimer found no solution … (tried lemma hints:
  `+-identityʳ`, …)` — names the lemma, then fails.
- Add `open import Data.Nat.Properties using (+-identityʳ)` → `auto goal=g0`
  fills `idr n = +-identityʳ n`.
- `give goal=g0 term="+-identityʳ n"` on the un-imported file → a clear
  `[NotInScope] +-identityʳ`.

#### Resolution (2026-07-10)

Arena option (b) — detect and report actionably; auto-import + retry
(option (a)) is deferred (it needs the temp-file revalidation machinery, and
`repair` already adds an import once a term is in the file).

- **`AgdaRepair.Diagnostic.hintOutOfScope`** (pure, exported, golden-tested):
  a hint is out of scope iff it appears in `notInScopeNames err`, or (a
  fallback) the burst carries a `NotInScope` tag and the hint occurs in the
  message. Lenient: any other error stays a plain failure (behaviour
  degrades to today's).
- **`autoSolve`** no longer discards the per-hint error; `AutoResult`'s
  failure case carries the out-of-scope hints in try order. The
  one-at-a-time protocol is untouched.
- **`AgdaMcp.Query.goalHintCands`** returns `(base-name, source Definition)`
  pairs (the same ranking core as `goalHintNames`, reimplemented on top), so
  `runAuto`/`runAutoAll` can render each out-of-scope hint's exact import
  line via `AgdaRepair.Strategy.importLineFor` — no re-resolution.
- **Message:** on a no-solution with out-of-scope hints, `auto`/`auto_all`
  append `Note — N graph-ranked hint(s) are not in the file's import scope …
  add `open import M using (h)` … or run `repair``. Honest phrasing: untried
  candidates, not verified closers.

Verified live on `RungB.agda`: `auto goal=g0` now appends the out-of-scope
note with import lines; after adding the import, `auto goal=g0 write:true`
fills `idr n = +-identityʳ n`. Note: the specific module named for
`+-identityʳ` inherits I8's coverage-level ranking artifact
(`Data.Nat.Binary.Properties.+-identityʳ`, whose unit is literally named
`zero`, outranks the ℕ instance), so the suggested import can be the ℕᵇ one;
the mechanism is correct and the note is actionable regardless. Arena CI gate
G1–G4 still PASS.

---

### I8 — `lemmas`/`find_lemma` goal ranking under-discriminates across carrier types; `goal` id rejects a JSON integer

- **Reported:** 2026-07-10 (MCPBenchArena R20, from the powered P1 haiku×5
  run, rung-b).
- **Resolved:** 2026-07-10 — see [Resolution](#resolution-2026-07-10-1).
- **Component:** ranking core → new `src-agda-graph/AgdaGraph/LemmaRank.hs`
  (factored out of `AgdaMcp.Query`); `withGoal` / `argScalarText` for the
  goal-id half.
- **Severity:** medium — a flat menu of near-identical candidates for a
  trivial goal, a measured contributor to interactive thrashing (the mirror
  of I4: there `similar_types` was over-confident; here `lemmas` is
  under-discriminating).

#### Summary

For a `Data.Nat` goal `n + zero ≡ n`, `lemmas` returned the `+`-identity
family across ℕ / ℤ / Sign all tied at 62.5%, with the correct
`Data.Nat.Properties.+-identityʳ` sorted *below* the `Data.Integer` variants.
`matchTokens` qualifier-strip maps `Data.Nat._+_` and `Data.Integer._+_` both
to `+`, so the ℕ and ℤ candidates' token bags are byte-identical — a complete
`(coverage, jaccard, bag)` tie, resolved by `defName` alphabetically
(`Data.Integer` < `Data.Nat`). The discriminating signal — which carrier type
the goal actually uses — was available (the candidate's `defModule`, and in
the live path the goal context `n : ℕ`) but unused. Separately, `withGoal`
read the goal via string-only `argText`, so a client sending the JSON integer
`{"goal": 0}` got a misleading "requires a `goal` argument" (a schema-misuse
dead-end; the R7 friction axis).

#### Resolution (2026-07-10)

**Ranking (carrier-module affinity, tie-break only).** The free-text ranking
core moved to `AgdaGraph.LemmaRank` (so the offline test-suite can exercise
it; `AgdaMcp.Query` drags in the process-heavy `AgdaMcp.State`). The score is
now `(weightedCoverage, tokenJaccard, carrierAffinity, negate bagSize)` —
coverage and Jaccard are **unchanged and first** (the historically-tuned
find_lemma 10/10 signal), so affinity only reorders otherwise-exact ties and
the displayed percentage never changes. Affinity looks up the modules that
*define* the goal's value/type carrier tokens (`zero`, `ℕ` — from real
constructor/datatype/record defs, plus any `renaming` alias host) and boosts
a candidate whose own module shares a non-generic path segment (`Nat`). The
live `lemmas` path fetches the goal context (`iotcmGoalTypeContext`) and feeds
the binder types into the carrier set; the read-side `find_lemma` stays
context-free. Matched rows carry a `[carrier: …]` marker. Empty carrier set
(no matching def, no alias, a signature-less graph) ⇒ affinity 0 everywhere ⇒
ranking byte-identical to the pre-fix behaviour.

Verified: `find_lemma goal="n + zero ≡ n"` on the stdlib sig graph now ranks
`Data.Nat.Properties.+-identityʳ` (62.5%, `[carrier: Nat]`) above the
byte-identical `Data.Integer.Properties.+-identityʳ` (62.5%, no marker); live
`lemmas` agrees. Unit-tested in `test/Spec.hs` (`lemmaRankTests`), including a
coverage-stays-0.625 tripwire and a no-carrier determinism pin. Arena CI gate
G1–G4 PASS.

**Known limitation (documented, not chased).**
`Data.Nat.Binary.Properties.+-identityʳ` scores 0.75 — its identity element
is literally *named* `zero`, covering the goal's `zero` token — and stays
above the correct ℕ lemma. That is a coverage-level artifact the tie-break
cannot (and must not, per G1) touch; both rows carry `[carrier: Nat]`.

**Goal-id integer (secondary).** New `AgdaMcp.ToolDef.argScalarText` accepts a
JSON string *or* an integral JSON number (rendered in decimal); `withGoal`
uses it, and its error echoes the accepted forms (`g0`, or a bare integer).
Verified live: `auto goal=0` (JSON integer) now runs instead of erroring.

### I9 — `load-bearing` entry-module guess is input-order dependent on a tie

- **Reported:** 2026-07-12 — audit during the behavior-preserving simplification
  pass (not a benchmark run); see [Changelog.md](Changelog.md).
- **Resolved:** 2026-07-12 — `guessEntryModule` now uses the same total-order
  tie-break as `gravity`.
- **Component:** `src/AgdaOptimization/LoadBearing.hs`.
- **Severity:** low — surfaces only when two or more modules tie on public-def
  count *and* equal name length; the winner then depended on the def vector's
  traversal order rather than a stable key.

#### Summary

`LoadBearing.guessEntryModule` ranked candidate modules by
`(Down count, name-length)`. On a tie in both keys the stable sort fell back to
the hand-rolled accumulator's insertion order — i.e. the order defs happen to
appear in the `Index` vector — so the chosen entry module (and the
`results=terminals` fallback banner) was not a function of the graph alone.
`gravity`'s sibling `guessEntryModule` already used the deterministic
`(Down count, name-length, name)` key; `load-bearing` now matches it. No fixture
output changed (`test/deps.json` has no such tie), so the acceptance oracle
stayed byte-identical.

### I10 — `agda-explore` and `agda-unused` disagree on which literate extensions count as Agda sources

- **Reported:** 2026-07-12 — audit during the simplification pass; see
  [Changelog.md](Changelog.md).
- **Resolved:** 2026-07-12 — `isAgdaFile` extended to the full set.
- **Component:** `src/MainMcp.hs` (`isAgdaFile`), mirroring `src/MainUnused.hs`
  (`isAgdaSource`).
- **Severity:** low — `agda-explore`'s file discovery / entry detection silently
  skipped `.lagda.tree` and `.lagda.typ` sources that `agda-unused` accepts.

#### Summary

`agda-unused`'s `isAgdaSource` recognised `.agda`, `.lagda`, `.lagda.md`,
`.lagda.rst`, `.lagda.tex`, `.lagda.org`, `.lagda.tree`, `.lagda.typ`; the
`agda-explore` daemon's `isAgdaFile` omitted the last two, so a project with
those literate modules had them ignored when the daemon walked the tree or
classified a positional CLI argument as an entry file. The two lists are now the
same set. (A single shared constant would prevent future drift — noted, not done,
since the two executables don't currently share a source-discovery module.)
