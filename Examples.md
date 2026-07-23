# Examples

Runnable recipes for all five binaries (`agda-unused`, `agda-optimization`,
`agda-goals`, `agda-explore`, `agda-auto`). Full flag reference:
[README.md](README.md). YAML config: [Configuration.md](Configuration.md).
Design rationale and default-value evidence: [Changelog.md](Changelog.md).

Every tool consumes the **expanded** v2 `graph.json` from `agda-deps` (a
separate repo). Put `agda-deps` on your `$PATH` and produce the graph first.

## Setup

```bash
cabal build all
mkdir -p out

# Produce the input graph with the agda-deps producer:
agda-deps --format=json --json-mode=expanded --no-externals \
  -i src/ -o out/ src/Main.agda
# → out/deps.json
```

Substitute your own include path and entry module for `src/Main.agda`.
Defaults below were tuned on a ~21k-node reference Agda formalisation.

---

## `agda-unused` — flag unused imports / definitions

```bash
cabal run agda-unused -- \
  --graph=out/deps.json --rel-to=src/ src/
```

Reports unused imports / defs / opens as `file:line: name -- kind` rows. A
successful run exits 0 regardless of finding count (a hint, not a build gate);
it exits nonzero only on an operational error (bad config, unreadable graph, or
a run matching no scanned files).

Default `--kinds=using,duplicate` — the lowest-noise combination. The other
kinds (`blanket`, `defined`, `dead`, `public`) need more triage; enable all
with `--kinds=all`. `--format=json` (alias `--json-out`) emits a JSON array (one object per finding);
`--group-by=dir|file|kind` and `--count-only` aggregate the findings;
positional `ROOTS…` accept multiple directories.

---

## `agda-optimization` — 19 subcommands (18 graph analyses + `hint-bench`)

All subcommands take the same expanded JSON. Every one accepts `--json`
(JSON report), `--out FILE` (default stdout), and `--config=PATH`.

---

### `motif` — frequent labeled subgraph motifs

```bash
cabal run agda-optimization -- motif /tmp/opt/deps.json \
  --min-support=3 --max-size=3 --top-n=20
```

Mines recurring labeled subgraphs (`(kind, state)` node labels) — proof
shapes that are candidates for extraction into a lemma or tactic.

Default `--min-label-distinct=2` — the noise filter; without it trivial
`Function:D × N` chains dominate. `--budget=N` caps wall-clock seconds.

### `load-bearing` — span-betweenness + perturbation Δ

```bash
cabal run agda-optimization -- load-bearing /tmp/opt/deps.json \
  --results=exported --top-n=20
```

Surfaces definitions on the longest pole of many results — the
refactor-blast-radius signal that in-degree misses.

Default `--results=exported, --weight=unit` — public theorems are the
results, each weighed equally (`--weight=loc` to weight by line count).

### `polyglot` — cross-context generalization candidates

```bash
cabal run agda-optimization -- polyglot /tmp/opt/deps.json \
  --min-uses=5 --threshold=0.5
```

Scores each def by the Shannon entropy of its consumers' community
distribution; `★` = "promote as a typeclass" candidate.

Default `--threshold=0.5` — the empirical knee from "2-3 contexts" to
"across the project". `[god?]` tag suppressed when Louvain Q < 0.1.

### `fingerprint` — graph-level near-duplicate proofs

```bash
cabal run agda-optimization -- fingerprint /tmp/opt/deps.json \
  --direction=incoming --jaccard=0.8 --wl-k=2 --top-n=20
```

Weisfeiler-Lehman colour refinement on each def's dependency subtree, then
weighted-Jaccard similarity → clusters of near-duplicate proofs.

Default `--direction=incoming` — captures "defs that ANSWER the same
callers" (outgoing conflates "proofs sharing helpers" into a mega-cluster).

### `debt` — proof-debt ledger

```bash
cabal run agda-optimization -- debt /tmp/opt/deps.json --top-n=20
```

For each `Hole` / stub `Postulate`, finds the public theorems transitively
depending on it; greedy-schedules "fill these first".

Default `--include-foundational=false` — foundational `Agda.Builtin.*` /
`Agda.Primitive.*` postulates excluded so stdlib primitives don't dominate.

### `basket` — co-usage association rules (Apriori)

```bash
cabal run agda-optimization -- basket /tmp/opt/deps.json \
  --min-support=0.05 --min-confidence=0.6 --min-lift=1.5
```

Apriori (k≤3) co-usage rule mining over direct out-edges — bundles that
should probably be a single combinator.

Default `--min-lift=1.5` — the "not a coincidence" floor. The
forced-by-elaborator suppressor (default on) drops per-clause-unfold
families (`VoteBlock-{0,1,2}`); disable with `--no-forced-suppress`.
`--budget=N` is essential on big projects (L₃ can be 5M+ triples).

### `ledger` — per-theorem trust budget

```bash
cabal run agda-optimization -- ledger /tmp/opt/deps.json \
  --top-n=30 \
  --axiom-module-prefix=Protocol.Example.Assumptions \
  --theorem-prefix=Protocol.Example.Properties
```

Per public theorem: which axioms / postulates it transitively depends on;
clusters theorems by shared axiom set and ranks axioms by leverage.

Default `--axiom-source=postulate` — switch to `record-field`/`both` for
field-encoded axioms. `--theorem-prefix=PREFIX` is essential with stdlib.

### `echo` — reverse-direction `fingerprint`

```bash
cabal run agda-optimization -- echo /tmp/opt/deps.json \
  --max-cluster-spread=0.3 --top-n=20
```

Same WL + Ruzicka pipeline as `fingerprint` but on `idxReverse` — surfaces
"defs that ANSWER the same callers" duplicates.

Default `--max-cluster-spread=0.3` — rejects sink-funnel pollution (giant
reverse-clusters at a project-wide consumer); `0` disables the filter.

### `gravity` — PageRank / PPR / HITS centrality

```bash
cabal run agda-optimization -- gravity /tmp/opt/deps.json \
  --top-theorems=64 --top-n=30
```

Reverse-PageRank + Personalized PageRank from the heaviest theorems + HITS;
ranks blast-radius hot spots (high mass spread across many theorems).

Default `--top-theorems=64` — the sweet spot (fewer makes entropy noisy,
more dilutes per-theorem PPR mass). `--damping=0.85`, `--iters=50`.

### `pyre` — graph-only typecheck-cost prediction

```bash
cabal run agda-optimization -- pyre /tmp/opt/deps.json --top-n=20
```

Predicts elaborator hot-spots via
`C = w1·|reach⁺| + w2·Σ fanIn·fanOut + w3·Σ wKind + w4·depthRank`.

Default `--w4=10.0` dominates — depth in the SCC condensation is the
strongest predictor of `agda --profile` time. Calibrate against a real
profile and apply the fit:

```bash
cabal run agda-optimization -- pyre /tmp/opt/deps.json \
  --profile=/tmp/agda-profile.json --calibrate
```

`--levers` ranks the dual — defs where one optimisation cuts the most
aggregate cost (`lever = reachers × selfCost`).

### `chokepoint` — node-capacitated max-flow + articulation points

```bash
cabal run agda-optimization -- chokepoint /tmp/opt/deps.json \
  --sources=exported --top-n=20
```

Max-flow (Edmonds–Karp, node-split) from theorems to axioms plus Tarjan
articulation points — funnels that `load-bearing`'s betweenness smooths over.

Default `--sources=exported, --sinks=postulates-axioms` — falls back to
`terminal-leaves` (stderr note) if the postulate-axiom set is empty.

### `silhouette` — signature-vs-body topology twins

```bash
cabal run agda-optimization -- silhouette /tmp/opt/deps.json \
  --high-overlap=0.5 --low-overlap=0.2 --top-n=30
```

Two WL fingerprints per def (signature edges vs body edges); a high-sig,
low-body pair is a candidate for a shared interface with diverging impls.

Default `--high-overlap=0.5, --low-overlap=0.2` — the asymmetry is the
point. Needs the `definitionEdgesProvenance` field (clean stderr fallback
on legacy JSON without it).

### `entwine` — pairwise MI / IQR over caller baskets

```bash
cabal run agda-optimization -- entwine /tmp/opt/deps.json \
  --min-co-callers=3 --min-iqr=0.5 --top-n=30
```

Pairwise mutual information over caller baskets, G-test gated — catches
low-frequency high-determinism pairs that `basket`'s thresholds miss.

Default `--min-g-stat=6.635` — the standard 99%-confidence cutoff (≈ p <
0.01); IQR + co-callers floors filter small-basket false positives.

### `fiedler` — spectral bisection (needs SciPy)

```bash
cabal run agda-optimization -- fiedler /tmp/opt/deps.json \
  --eig-k=5 --top-n=20
```

Shells out to `scripts/fiedler_helper.py` (the only subcommand that shells
out); emits bridge edges, per-module λ₂ hotspots, sign-cluster crossers.

Default `--eig-k=5` — λ₁..λ₅ above the trivial zero eigenvalue. **Requires
SciPy**: missing → clean stderr diagnostic + exit 3.

### `horizon` — eccentricity / proof geometry

```bash
cabal run agda-optimization -- horizon /tmp/opt/deps.json --top-n=20
```

Per def: `ε⁺` (depth to leaves) + `ε⁻` (depth from theorems); reports
diameter, radius, periphery, center, and a per-module `ε⁺` histogram.

Default `--leaves=postulates-axioms, --roots=public-theorems` — switch to
`terminal-leaves` / `terminals` for projects without those conventions.

### `strata` — per-module classical SE metrics

```bash
cabal run agda-optimization -- strata /tmp/opt/deps.json \
  --min-size=3 --top-n=30
```

LCOM' (cohesion), instability (`out/(in+out)`), abstractness
(`postulate/total`) per declared module.

Default `--min-size=3` — smaller modules lack the internal structure for
cohesion metrics. `--exclude-module-regex=PATTERN` scopes the report.

### `term-cluster` — AST-level subterm fingerprint clusters

```bash
# 1. Producer (notice the extra producer flags).
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

Buckets subterm occurrences by canonical-form hash; ranks by `size ×
meanDepth × (1 + diversity)`.

`--min-diversity` (default `0.0`) is the single most discriminating knob —
`0.7` is the recommended cross-cutting filter. **Needs producer
`--with-term-hashes`** (the producer's `--min-term-depth=N` trims hash volume).
`--span-modules=N` (default `1`) requires a cluster's defs to span ≥N distinct
declared modules.

### `concept-bundle` — signature-vocabulary itemsets

```bash
cabal run agda-optimization -- concept-bundle /tmp/opt/deps.json \
  --min-support=5 --min-lift=2.0 --min-span=3 --k-max=2 --top-n=25
```

Apriori (k≤4) frequent-itemset mining over each def's signature-provenance
edges — vocabulary recurring across module-spanning type signatures (the
"shared-record candidate" signal). No producer flag needed.

Default `--min-span=3` — the cross-module gate (an itemset must span ≥3
modules). The forced-by-elaborator suppressor (same machinery as `basket`,
default on) drops family-polluted itemsets; `--no-forced-suppress` disables.

### `hint-bench` — offline lemma-ranker eval (leave-one-out)

```bash
cabal run agda-optimization -- hint-bench /tmp/opt/deps.json \
  --strategy=all --k=3,6,10
```

Not a graph analysis — a leave-one-out eval harness for the shared lemma
ranker. Each proved theorem is a query: its signature is the goal, its
body-provenance edges are the ground-truth premises, so a ranking change is
scored (recall@k / any-hit@k / MRR) with no live `agda` run.

Default `--strategy=baseline` (`all` scores every registered strategy);
`--k=3,6,10` sets the cutoffs, `--min-sim=0.4` the ranker floor,
`--knn-k=32` / `--knn-alpha=0.5` tune the k-NN strategies, `--keep-ctors`
keeps constructor premises (dropped by default). A graph without edge
provenance or signatures yields an empty corpus and exits clean.

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
| Which signature-vocabulary clusters suggest a missing record? | `concept-bundle` |
| Where does the typecheck spend its time? | `pyre` (`--profile` to calibrate) |
| Which one def, if optimised, cuts the most aggregate cost? | `pyre --levers` |
| Where are the bottlenecks from theorems to axioms? | `chokepoint`, `fiedler` |
| Which functions share a signature but diverge in body? | `silhouette` |
| Which two functions ANSWER the same callers? | `echo` |
| What's the proof geometry — diameter, radius, periphery? | `horizon` |
| Which modules have poor cohesion? | `strata`, `polyglot` |
| What are the centrality hotspots? | `gravity` |
| Cross-file CSE candidates at the AST level? | `term-cluster` |

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

---

## `agda-goals` — bucket open goal states

Needs `agda` on `$PATH`. Drives `agda --interaction-json` over the roots via a
pool of persistent processes, canonicalises each open goal type, and buckets by
hash to surface recurring missing lemmas.

```bash
cabal run agda-goals -- -i src/ src/                       # human report
cabal run agda-goals -- -i src/ --format=json --top-n=20 src/ | jq
```

One process per RTS capability; cap the pool with `+RTS -NK -RTS`. Output is
reassembled in input order, so it is byte-identical between `-N1` and `-NK`.
Config: [`.agda-goals.yml`](Configuration.md#agda-goalsyml).

---

## `agda-explore` — interactive graph server for agents

Needs `agda-deps` on `$PATH` for live regeneration (preloaded mode does not).
Three ways to run it:

```bash
# 1. Daemon (stdio MCP server) — regenerates the graph on the fly via agda-deps:
cabal run agda-explore -- --project . --entry src/Everything.agda -i src/

# 1b. Preloaded from an existing graph (no agda-deps needed):
cabal run agda-explore -- --graph out/deps.json

# 2. One-shot read query (no daemon) — for scripting / CI:
cabal run agda-explore -- query brief  name=Data.Nat._+_ --graph out/deps.json
cabal run agda-explore -- query search query=toWitness   --graph out/deps.json --json \
  | jq '.items[].name'

# 3. Web inspector (opt-in localhost page over SSE):
cabal run agda-explore -- --project . --inspect            # → http://127.0.0.1:7000
```

Read-side tools: `brief`, `locate`, `callers`, `callees`, `impact`, `path`,
`roots`, `type_of`, `similar_types`, `similar_bodies`, `find_lemma`, `search`,
`unused`, `rebuild`, `status`. `brief name=X` is a one-call orientation bundle
(location + type + callers/callees + body-twins); `search` / `callers` /
`callees` accept `format:json`.

Add `--enable-interact` (needs `agda` on `$PATH`) for the Agda-validated
write-side bridge — every mutator returns a unified diff and only writes under
`write:true`, under a hard zero-axiom contract:

```bash
cabal run agda-explore -- --project . --enable-interact
```

Write-side tools: `load`, `goal_brief`, `inspect`, `auto`, `construct`,
`scratch`, `check`, `give_file`, `new_module`, `lemmas`, `repair`. Full detail
(and the Claude Code plugin bundling this server): [`plugin/`](plugin/README.md).
Config: [`.agda-explore.yml`](Configuration.md#agda-exploreyml).

---

## `agda-auto` — batch hole-filling

Needs `agda` on `$PATH` (or `--agda-bin`). Runs the same Mimer + graph-hint
ladder as `agda-explore`'s `auto` over every open hole. A graph (`--graph`, else
a discovered `./deps.json` / `./.agda-explore/deps.json`) supplies lemma hints;
without one it runs plain Mimer.

```bash
cabal run agda-auto -- File.agda                       # diff + per-hole report
cabal run agda-auto -- --write File.agda               # apply, annotate the rest
cabal run agda-auto -- --graph out/deps.json src/      # project sweep (dep order)
cabal run agda-auto -- --json File.agda | jq           # structured report
```

Exit codes: `0` = no hole left open, `1` = holes remain, `2` = operational
error. A directory (or more than one file) is **project mode** — swept serially
in dependency order (imports first). Useful flags: `--timeout N` / `--hints K`
(per-goal Mimer budget / graph-hint count), `--no-annotate`, `--repair` (add
missing imports before probing), `--fixpoint` (with `--write`, re-sweep until a
pass fills nothing new), `--ledger FILE`. Config:
[`.agda-auto.yml`](Configuration.md#agda-autoyml).

---

For YAML configuration of every tool, see [Configuration.md](Configuration.md).
