# Examples

Runnable recipes for the consumer binaries in this repo (`agda-unused`,
`agda-optimization`). For full flag reference see [README.md](README.md);
for design rationale and the empirical evidence behind the default values
see [Changelog.md](Changelog.md).

Every tool consumes the **expanded** v2 `graph.json` produced by
`agda-deps` (the Agda backend; a separate repo). Put `agda-deps` on your
`$PATH` (or invoke it from its own checkout) and produce the input graph
first — the recipes below assume `out/deps.json` exists.

## Setup

```bash
cabal build all
mkdir -p out

# Produce the input graph with the agda-deps producer:
agda-deps --format=json --json-mode=expanded --no-externals \
  -i src/ -o out/ src/Main.agda
# → out/deps.json
```

Throughout, substitute your own project's include path and entry module
wherever you see `src/Main.agda` or `path/to/your-project/…`. The defaults
documented below were tuned on a ~21k-node reference Agda formalisation.

---

## `agda-unused` — flag unused imports / definitions

Consumes the expanded JSON. Reports findings as `file:line: name
-- kind` rows; exit-code 0 always (it's a hint, not a build gate).

### Default flow

```bash
# 1. produce the JSON (with the agda-deps producer)
agda-deps --format=json --json-mode=expanded \
  --no-externals \
  -i src/ -o out/ src/Main.agda

# 2. analyse
cabal run agda-unused -- \
  --json=out/deps.json --rel-to=src/ src/
```

**Default kinds: `using,duplicate`.** Empirically the lowest-noise
combination — these two are almost always real findings. The other
three (`blanket`, `defined`, `public`) require more careful triage:

- `blanket` reports `open import M` lines with no symbol from `M`
  referenced. Credits re-export chains via the JSON's `reexports[]`
  so `Prelude`-style hubs don't false-positive.
- `defined` is a *hint*: a def with no cross-module user. Often a
  helper that's still useful as an intermediate step.
- `public` flags `open import M using (n) public` where `(M, n)` has
  no cross-module user. Re-exports look dead but the convention may
  be deliberate.

### All findings, JSON output

```bash
cabal run agda-unused -- --kinds=all --json-out \
  --json=out/deps.json --rel-to=src/ src/ > findings.json
```

`--json-out` emits a JSON array (one object per finding) instead
of human-readable lines. The applied-config breadcrumb is suppressed
under `--json-out` to keep stdout clean for piping.

### Multiple source roots

```bash
cabal run agda-unused -- \
  --json=out/deps.json --rel-to=. \
  src/ lib/
```

Positional `ROOTS…` accept multiple directories. Useful for
monorepos where source lives under several top-level dirs.

---

## `agda-optimization` — 18 graph-level analyses

All subcommands take the **same** expanded JSON as input:

```bash
agda-deps --format=json --json-mode=expanded --no-externals \
  -o /tmp/opt /path/to/Main.lagda.md
```

Then point `agda-optimization <subcommand>` at `/tmp/opt/deps.json`.
The defaults below have been tuned on the reference corpus (~13k defs); on
smaller corpora the noise floor is lower and the defaults still
work; on much larger corpora consider tightening thresholds via
`--top-n` / `--min-support` etc.

Every subcommand accepts:

- `--json` — emit a JSON report.
- `--out FILE` — write to FILE (default stdout).
- `--config=PATH` — load a YAML config file.

---

### `motif` — frequent labeled subgraph motifs

```bash
cabal run agda-optimization -- motif /tmp/opt/deps.json \
  --min-support=3 --max-size=3 --top-n=20
```

Mines subgraphs of size 2–`--max-size` that appear ≥ `--min-support`
times. Node labels are `(kind, state)` pairs — recurring proof shapes
that are candidates for extraction into a lemma or tactic.

**Default `--min-support=3, --max-size=3, --min-label-distinct=2`.**
The `min-label-distinct=2` floor is the noise filter that matters:
without it, pure `Function:D × N` chains dominate the report —
they're "frequent subgraphs" but trivial. The label-distinct
requirement ensures motifs have structural variety (e.g. a
`Datatype` consumed by a `Function` consumed by another `Function`).

Tune `--min-support` up on a project with strong repetition;
`--max-size=4` if your tooling can handle the (sometimes much)
slower enumeration. `--budget=N` (wall-clock seconds) caps long
runs and emits partial output via stderr progress lines.

### `load-bearing` — span-betweenness + perturbation Δ

```bash
cabal run agda-optimization -- load-bearing /tmp/opt/deps.json \
  --results=exported --top-n=20
```

Surfaces the definitions that sit on the longest pole of many
results — the refactor-blast-radius signal that simple in-degree
misses. Computed over the SCC-condensed DAG with span-betweenness +
perturbation Δ.

**Default `--results=exported, --weight=unit`.** `exported` =
publicly-visible theorems are the "results" to weigh paths through;
`unit` = every result counts equally. Switch `--weight=loc` to
weight by line-of-code if your theorems vary wildly in size.
`--exclude-name-regex` defaults to `^[_─═]+$` to drop textbook-
style horizontal-bar separator operators that otherwise pollute the
report.

### `polyglot` — cross-context generalization candidates

```bash
cabal run agda-optimization -- polyglot /tmp/opt/deps.json \
  --min-uses=5 --threshold=0.5
```

For each definition `v` with ≥ `--min-uses` consumers, classifies
consumers into Louvain communities and computes the Shannon entropy
of the consumer→community distribution. `★` = high-entropy "promote
this as a typeclass" candidate; `·` = "parochial — used a lot but in
one tight cluster".

**Default `--min-uses=5, --threshold=0.5`.** Below 5 consumers
there isn't enough signal for community-membership to be
informative. The 0.5 entropy threshold is the empirical knee where
"useful in 2-3 contexts" becomes "useful across the project". A
stderr warning fires and the `[god?]` tag is suppressed when
Louvain modularity Q < 0.1 (community structure too weak to trust).

### `fingerprint` — graph-level near-duplicate proofs

```bash
cabal run agda-optimization -- fingerprint /tmp/opt/deps.json \
  --direction=incoming --jaccard=0.8 --wl-k=2 --top-n=20
```

Weisfeiler-Lehman colour refinement on each definition's rooted
dependency subtree, then weighted-Jaccard similarity. Clusters of
structurally near-duplicate proofs.

**Default `--direction=incoming` (round 5 flipped this).** Outgoing
WL conflates "two proofs that share helpers" — usually a
mega-cluster on real corpora. Incoming captures "two defs that
ANSWER the same callers" — the actionable signal. Pass
`--direction=outgoing` for the round-4 default; `--direction=both`
for the union (slower).

**Default `--jaccard=0.8`** — empirical. Below 0.7 the cluster set
explodes; above 0.9 alpha-variants stop collapsing. **Default
`--wl-k=2`** — sufficient for the "same-rooted-subtree" signal;
`--wl-k=3` is for very deep graphs.

### `debt` — proof-debt ledger

```bash
cabal run agda-optimization -- debt /tmp/opt/deps.json --top-n=20
```

For each `Hole` / stub `Postulate`, computes the set of public
theorems that transitively depend on it; runs a submodular-greedy
schedule ("fill these first to discharge the most exports").

**Default `--include-postulates=true, --include-foundational=false`.**
User-written postulates count as debt; foundational `Agda.Builtin.*`
/ `Agda.Primitive.*` postulates don't (otherwise the report is
dominated by stdlib primitives every project depends on). On a
project with zero holes/stub-postulates, the subcommand emits a
foundational-postulate inventory grouped by module — disable with
`--no-foundational-inventory` if it's noise.

### `basket` — co-usage association rules (Apriori)

```bash
cabal run agda-optimization -- basket /tmp/opt/deps.json \
  --min-support=0.05 --min-confidence=0.6 --min-lift=1.5
```

Apriori (k≤3) co-usage rule mining over direct out-edges. "When
def A is used, def B is used 80% of the time, AND that pairing
happens 3× more often than random" — those rules surface bundles
that should probably be a single combinator.

**Default `--min-support=0.05`** (rules must cover 5%+ of
transactions), **`--min-confidence=0.6`** (conditional probability),
**`--min-lift=1.5`** (vs. random). Lift > 1.5 is the empirical
"this isn't a coincidence" floor. **Default
`--exclude-top-frequency=5.0`** drops rules whose LHS or RHS is in
the top 5% by support — those are usually `refl`, `_` ,
`prelude/_++_` etc. that participate in every basket trivially.

`--budget=N` (wall-clock cap) is essential on big projects — L₃
generation can be 5M+ triples; the per-level reaper keeps memory
bounded.

**Round-7 forced-by-elaborator suppressor (default on).** Drops
rules whose bundle is dominated by a per-case-unfold family — items
matching `^(stem)-(\d+)$` (e.g. `VoteBlock-0`, `VoteBlock-1`,
`VoteBlock-2`, or stdlib's `_—→⟨_⟩_-{0..4}`) plus the bare-stem
pair (`{mk, mk-1}`). These are Agda's per-clause unfolds of
state-update functions or equational-reasoning operators; the
syntactic co-firing is forced by the elaborator, and prior
analysis on the reference corpus confirmed the bundles are
not refactor-actionable. Stats line reports `forced-suppressed=N`
when the filter fires.

```bash
# Disable to compare against pre-round-7 behaviour:
cabal run agda-optimization -- basket /tmp/opt/deps.json \
  --no-forced-suppress

# Tighter gate — only suppress when the family covers the ENTIRE bundle:
cabal run agda-optimization -- basket /tmp/opt/deps.json \
  --forced-fraction=1.0
```

On the reference corpus (13k defs) this catches ~20 high-confidence
(lift > 100) `_—→⟨_⟩_-N` pairs that would otherwise dominate the
top of the kept-rule table.

### `ledger` — per-theorem trust budget

```bash
cabal run agda-optimization -- ledger /tmp/opt/deps.json \
  --top-n=30 \
  --axiom-module-prefix=Protocol.Example.Assumptions \
  --theorem-prefix=Protocol.Example.Properties
```

Per public theorem: which axioms / postulates does it transitively
depend on? Clusters theorems sharing the same axiom set (cohorts).
Ranks axioms by leverage (how many theorems depend on them).

**Default `--axiom-source=postulate`.** Switch to
`record-field` or `both` for projects that encode axioms as record
fields (like the reference corpus's `Assumptions.{roundLeader, GST, …}`); pair
with `--axiom-module-prefix=PREFIX` to scope what counts.
**`--theorem-prefix=PREFIX`** (repeatable) is essential on projects
that pull in agda-stdlib — without it the table is dominated by
stdlib lemmas.

### `echo` — reverse-direction `fingerprint`

```bash
cabal run agda-optimization -- echo /tmp/opt/deps.json \
  --max-cluster-spread=0.3 --top-n=20
```

Same WL + Ruzicka pipeline as `fingerprint`, but on `idxReverse`.
Surfaces "two defs that ANSWER the same callers" near-duplicates
that `fingerprint --direction=outgoing` drowns.

**Default `--max-cluster-spread=0.3`.** Rejects clusters whose
`forward-cluster-spread / size` ratio falls below the threshold —
the signature of sink-funnel pollution (a giant reverse-cluster
aggregating at a project-wide consumer). Set `--max-cluster-spread=0`
to disable; raise to `0.5` for stricter cluster sets.

### `gravity` — PageRank / PPR / HITS centrality

```bash
cabal run agda-optimization -- gravity /tmp/opt/deps.json \
  --top-theorems=64 --top-n=30
```

Reverse-PageRank + Personalized PageRank from each of the top
`--top-theorems` heaviest theorems + HITS. Final ranking is
`revPR × H(theorems)` where H is the Shannon entropy of the PPR
distribution across the theorem sample — "high mass + spreads
across many theorems" = blast-radius hot spot.

**Default `--damping=0.85`** (classical PageRank value),
**`--iters=50, --tolerance=1e-6`** (converges on the reference corpus in ~30
iterations). **`--top-theorems=64`** is the empirical sweet spot:
fewer makes the entropy noisy, more dilutes the per-theorem PPR
mass and slows convergence.

### `pyre` — graph-only typecheck-cost prediction

```bash
cabal run agda-optimization -- pyre /tmp/opt/deps.json --top-n=20
```

Predicts elaborator hot-spots via
`C = w1·|reach⁺| + w2·Σ fanIn·fanOut + w3·Σ wKind + w4·depthRank`.

**Default weights `--w1=1.0, --w2=0.5, --w3=2.0, --w4=10.0`.**
The depth-rank dominance (`w4=10`) is intentional: empirically the
strongest predictor of `agda --profile` time is "how deep is this in
the SCC condensation". Per-kind weights are not flag-tunable yet
(`KRecord=6, KDatatype=4, KProjection=3, KFunction=2, …`).

**Calibrate against a real profile.** Feed observed per-definition
cost (a JSON `{qname: cost}` map, or `[{name, cost}]` array, derived
from `agda --profile=*`) and `pyre` reports how well the graph proxy
tracks reality and fits new weights:

```bash
# report-only: coverage + Spearman ρ + ridge-fitted weights
cabal run agda-optimization -- pyre /tmp/opt/deps.json \
  --profile=/tmp/agda-profile.json

# apply the fitted weights to the ranking
cabal run agda-optimization -- pyre /tmp/opt/deps.json \
  --profile=/tmp/agda-profile.json --calibrate
```

Cache the fit by copying the printed `w1..w4` into the `pyre:`
section of `.agda-optimization.yml` — no separate calibration store.

**Find the levers.** The cost table ranks *deep results*; `--levers`
ranks the dual — definitions where one optimisation cuts the most
aggregate cost across everything that depends on them
(`lever = reachers × selfCost`):

```bash
cabal run agda-optimization -- pyre /tmp/opt/deps.json --levers
```

With `--profile` the lever's `selfCost` is the observed self-time;
without it, the modeled `w1 + w2·fanProd + w3·kindSum`.

### `chokepoint` — node-capacitated max-flow + articulation points

```bash
cabal run agda-optimization -- chokepoint /tmp/opt/deps.json \
  --sources=exported --top-n=20
```

Max-flow (Edmonds–Karp with node splitting + super-source /
super-sink) from theorems to axioms / postulates, plus Tarjan
articulation points over the same subgraph. Catches funnels —
single defs that every theorem flows through — that
`load-bearing`'s betweenness smooths over.

**Default `--sources=exported, --sinks=postulates-axioms`** (or
falls back to `terminal-leaves` with a stderr note if the
postulate-axiom set resolves empty under `--no-externals`).

### `silhouette` — signature-vs-body topology twins

```bash
cabal run agda-optimization -- silhouette /tmp/opt/deps.json \
  --high-overlap=0.5 --low-overlap=0.2 --top-n=30
```

Builds two WL fingerprints per def: one over `defType` refs
(`signature`-tagged edges), one over `theDef` refs (`body`,
`with`, `where` edges). A pair with **high** signature-similarity
AND **low** body-similarity is a candidate for a shared interface
with diverging implementations.

**Default `--high-overlap=0.5, --low-overlap=0.2`.** The asymmetric
thresholds are deliberate — "signatures look the same, bodies look
different" is what makes the pair interesting. Set both to the same
value to fall back to fingerprint-equivalent behaviour.

Requires the `definitionEdgesProvenance` field (always emitted by
post-round-4 `agda-deps`). Legacy JSON without it triggers a clean
fallback notice on stderr.

### `entwine` — pairwise MI / IQR over caller baskets

```bash
cabal run agda-optimization -- entwine /tmp/opt/deps.json \
  --min-co-callers=3 --min-iqr=0.5 --top-n=30
```

Pairwise mutual information over caller baskets, gated by a G-test
(χ²) cutoff at `--min-g-stat=6.635` (≈ p < 0.01). Catches the
low-frequency, high-determinism pairs that `basket`'s
support/confidence thresholds miss — two helpers that nearly always
co-occur but only in three baskets total.

**Default `--min-co-callers=3, --min-iqr=0.5, --min-g-stat=6.635`.**
The G-stat threshold is the standard statistical 99%-confidence
cutoff; the IQR + co-callers floors filter the false positives that
two-point statistical tests are prone to on small baskets.

### `fiedler` — spectral bisection (needs SciPy)

```bash
cabal run agda-optimization -- fiedler /tmp/opt/deps.json \
  --eig-k=5 --top-n=20
```

Shells out to `scripts/fiedler_helper.py` (the only subcommand that
shells out). Emits bridge edges ranked by Fiedler-vector gap,
per-module λ₂ hotspots, and sign-cluster boundary-crossers.

**Default `--eig-k=5`** — computes λ₁..λ₅ above the trivial zero
eigenvalue. Five is the empirical knee where you've seen the main
spectral structure; raise to `--eig-k=10` for very large multi-
cluster corpora.

**Requires SciPy.** A missing SciPy install produces a clean stderr
diagnostic `[fiedler] scipy not found: pip install scipy numpy`
and exits 3 (distinct from exit 2 for "helper script not found");
the rest of the toolchain doesn't need Python at all.

### `horizon` — eccentricity / proof geometry

```bash
cabal run agda-optimization -- horizon /tmp/opt/deps.json --top-n=20
```

For each def: `ε⁺` (forward depth to leaves) + `ε⁻` (backward depth
from theorems). Reports diameter, radius, periphery (defs at
`ε⁺ = diameter`), center (`ε⁺ = radius`), plus a per-module `ε⁺`
histogram surfacing modules whose proofs sit unusually deep.

**Default `--leaves=postulates-axioms, --roots=public-theorems`.**
Switch `--leaves=terminal-leaves` if your project doesn't use
postulates (e.g. constructive-only); `--roots=terminals` if there's
no public-theorem convention.

### `strata` — per-module classical SE metrics

```bash
cabal run agda-optimization -- strata /tmp/opt/deps.json \
  --min-size=3 --top-n=30
```

LCOM' (lack of cohesion of methods), instability (`out / (in +
out)`), abstractness (`postulate / total`) per declared module.

**Default `--min-size=3`.** Modules with fewer than 3 defs don't
have enough internal structure for cohesion metrics to be
meaningful — including them just adds noise. Tune
`--exclude-module-regex=PATTERN` to scope the report
(e.g. `^(Data|Function|Relation|Algebra)\.` to drop stdlib).

### `term-cluster` — AST-level subterm fingerprint clusters (round 6 P3)

```bash
# 1. Producer (notice the extra producer flag).
agda-deps --format=json --json-mode=expanded \
  --with-term-hashes --min-term-depth=3 --no-externals \
  -i path/to/your-project/ \
  -o /tmp/p3 \
  path/to/your-project/Main.lagda.md

# 2. Consumer.
cabal run agda-optimization -- term-cluster /tmp/p3/deps.json \
  --span-modules=3 --min-diversity=0.7 \
  --exclude-module-regex='^(Data|Function|Relation|Algebra|Agda)\.' \
  --top-n=10
```

Buckets occurrences by canonical-form hash; ranks by `size ×
meanDepth × (1 + diversity)` where `diversity` is the Shannon
entropy of the per-declared-module distribution.

**Empirical defaults established on the reference corpus pre-Wave-2A (13,813
defs):**

- `--min-cluster=2` — singletons are never interesting.
- `--sort=score` (vs `size` / `log-score`) — composite ranking
  (`size × meanDepth × (1 + diversity)`). Without it, the top is
  dominated by trivial high-frequency shapes (Var, Sort, Level
  applications). `--sort=size` reproduces the round-6-launch ranking;
  `--sort=log-score` uses `log(1+size) × meanDepth × (1 + diversity)`,
  dampening sheer frequency so a moderately-sized but deep/cross-cutting
  pattern isn't buried under a huge shallow one.
- `--min-mean-depth=N` — drop clusters whose mean AST depth is below
  `N` (filters shallow boilerplate shapes before ranking).
- `--span-modules=3` — minimum 3 distinct declared modules.
  Cross-file duplication is the proposal's motivation. The
  declared-module collapse strips Agda's anonymous where-helper
  segments (`Foo.Bar._._.`) before counting, so deeply-nested
  where-helpers within one source file don't count as "spanning
  many modules".
- `--min-diversity=0.7` — the single most discriminating knob.
  The proposal's target cluster has diversity 0.899; the dominant
  Lemma5/PostGSTAnchor internal noise has diversity ≤ 0.05. The
  0.7 floor cuts ~84% of the surviving clusters without affecting
  the cross-cutting candidates.
- `--exclude-module-regex='^(Data|Function|Relation|Algebra|Agda)\.'` —
  drops 9,378 stdlib defs and ~5,000 stdlib clusters on the reference corpus.
  Use the prefix list appropriate to your project (the agda-stdlib
  package's top-level names).

**Producer-side `--min-term-depth=3`** is the matching empirical
default: cuts hash volume ~3× and wire-format size ~43%.
Increase to `5` to focus on very-deep subterms only; decrease to
`1` for the unfiltered launch behaviour.

### `concept-bundle` — signature-vocabulary itemsets (round 7)

```bash
cabal run agda-optimization -- concept-bundle /tmp/opt/deps.json \
  --min-support=5 --min-lift=2.0 --min-span=3 --k-max=2 --top-n=25
```

Apriori (k ≤ 4) frequent-itemset mining over each definition's
**signature-provenance** edges (the subset tagged `signature` in
`definitionEdgesProvenance`). Where `basket` mines all out-edges
and `fingerprint` clusters by AST shape, `concept-bundle` clusters
by the **vocabulary** that recurs across module-spanning type
*signatures*. Designed to catch the `DeliveryGuarantee`-class
"shared-record candidate" signal where the same 3–4 tokens (e.g.
`{honest, receives, GST, Δ}`) co-occur across dozens of lemma
statements without any AST clone.

No producer flag required — uses the `definitionEdgesProvenance`
field that `agda-deps` emits on every expanded-mode JSON since
round 4. On legacy JSON without the field, the subcommand prints a
one-line stderr note and falls back to all-edges (results then
match `basket`'s feature space).

**Defaults tuned on the reference corpus (13,853 defs / 919k edges):**

- `--min-support=3` — absolute count, not fraction. Proof corpora
  are small; 3-5 is typical.
- `--min-lift=2.0` — same role as in `basket`: 2× expected vs.
  random co-occurrence.
- `--min-span=3` — the cross-module gate. An itemset must span
  ≥ 3 distinct modules to count as a cross-cutting bundle;
  raise to 5+ on big projects to focus on widely-shared
  vocabulary, lower to 2 to surface module-pair idioms.
- `--k-max=4` — maximum itemset size. On a 13k-def corpus,
  `--k-max=2` already completes in seconds; `--k-max=3` and
  `--k-max=4` can be slow with many L1 items — use the time
  budget on `basket` as a guide.
- `--exclude-top-frequency=5.0` — same role as in `basket`:
  drops itemsets touching the top 5% by support
  (`Set`, `ℕ`, `_≡_`, etc.).

**Forced-by-elaborator suppressor (default on, same machinery as
`basket`)**. On the reference corpus this drops 656+ family-polluted itemsets
(`mk-{0..3}`, `isHighest-{0..3}`, …) that would otherwise dominate
the top of the bundle list, exposing real BFT vocabulary clusters
like `{rqcPayload, rqcPayload-inj, Digestable-Timeoutᴾ,
recordTimeout, qcPayload}` (appears as 9 pairwise rules in the
kept top-25 — the round's intended deliverable). Disable with
`--no-forced-suppress`; tighten with `--forced-fraction=1.0`.

Output ranks bundles by `support × lift × log(span+1)`. High
support × high span = a vocabulary shared across many lemmas in
many modules — almost always worth a named record / module
parameter. Low span / high support = a single module's private
idiom; the `--min-span` gate filters those.

---

## Heuristic cheat-sheet

Which subcommand answers which question?

| Question | Subcommand |
|---|---|
| Where should I refactor first to maximise blast radius? | `load-bearing` |
| What's used widely across disparate contexts? | `polyglot` |
| What proofs are structural near-duplicates? | `fingerprint` (graph) or `term-cluster` (AST) |
| What's my trust budget — which axioms support what? | `ledger` |
| What's my proof debt — which holes / stubs block exports? | `debt` |
| Which co-usage patterns suggest a missing combinator? | `basket`, `entwine` |
| Which signature-vocabulary clusters suggest a missing record? | `concept-bundle` (round 7) |
| Where does the typecheck spend its time? | `pyre` (relative; `--profile` to calibrate against `agda --profile`) |
| Which one def, if optimised, cuts the most aggregate cost? | `pyre --levers` |
| Where are the bottlenecks from theorems to axioms? | `chokepoint`, `fiedler` |
| Which functions share a signature but diverge in body? | `silhouette` |
| Which two functions ANSWER the same callers (vs. share helpers)? | `echo` |
| What's the proof geometry — diameter, radius, periphery? | `horizon` |
| Which modules have poor cohesion? | `strata`, `polyglot` |
| What are the centrality hotspots? | `gravity` |
| Cross-file CSE candidates at the AST level? | `term-cluster` (round 6 P3) |

For full pipelines combining several:

```bash
# 0. produce JSON once (with the agda-deps producer)
agda-deps --format=json --json-mode=expanded --no-externals \
  --with-term-hashes --min-term-depth=3 \
  -o /tmp/opt /path/to/Main.lagda.md

# 1. find structural near-duplicates three ways
agda-optimization fingerprint    /tmp/opt/deps.json --top-n=20
agda-optimization term-cluster   /tmp/opt/deps.json --span-modules=3 --min-diversity=0.7 --top-n=20
agda-optimization concept-bundle /tmp/opt/deps.json --min-span=3 --k-max=2 --top-n=20

# 2. assess refactor leverage
agda-optimization load-bearing  /tmp/opt/deps.json --top-n=20
agda-optimization polyglot      /tmp/opt/deps.json --top-n=20

# 3. inventory the trust base
agda-optimization debt          /tmp/opt/deps.json
agda-optimization ledger        /tmp/opt/deps.json
```

For full configuration of any of the above via YAML, see
[README.md § Configuration (YAML)](README.md#configuration-yaml).
