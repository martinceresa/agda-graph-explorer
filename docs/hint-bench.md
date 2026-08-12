# `hint-bench` — offline eval of the lemma ranker

**Not a graph analysis.** A leave-one-out eval harness for the shared lemma
ranker that feeds `agda-explore`'s and `agda-auto`'s `auto` hints.

Every proved theorem is a self-labelled retrieval query: its signature is the
goal, its body-provenance dependencies are the ground-truth premises. Hide it,
rank the rest of the library against its statement, and measure how often the
real premises land inside the hint budget.

## Why use it

- Scores a ranking change with **no live `agda` run**.
- No ranking change should land without moving these numbers.
- `A@k` at the `k` you actually seed predicts whether Mimer closes the goal.

## Run

```bash
agda-optimization hint-bench graph.json --strategy=all --k=3,6,10
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `corpus rows` | scorable theorems. `0` means the graph has no signatures or no edge provenance — the note line says which. That is a producer-flag problem, not a result. |
| `premise set` | whether constructors and records count as premises. |

Columns:

| Column | Meaning |
|---|---|
| `Strategy` | the ranking variant. `baseline` is what ships; the others are the Phase-1/2 experiments. |
| `R@k` | mean recall@k — the share of a row's real premises appearing in the top k. |
| `A@k` | any-hit@k — the share of rows with **at least one** real premise in the top k. This predicts whether seeding k hints lets Mimer close the goal, because one good hint often suffices. `R@k` is the stricter, less operational measure. |
| `MRR` | mean reciprocal rank of the first real premise. |
| `\|cand\|` | mean candidate-pool size per row. A ranking that improves while this grows has not necessarily got better. |

## Act on

`A@k` at the `k` you actually seed as hints (`agda-explore
--auto-hints-lemmas`). Compare strategies **against `baseline` within one run**:
absolute numbers are corpus-dependent and not comparable across projects.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--strategy=NAME` | `baseline` | ranking strategy to score, or `all`. |
| `--k=N[,N...]` | `3,6,10` | recall / any-hit cutoffs. |
| `--min-sim=F` | `0.4` | ranker coverage floor (the auto hint path). |
| `--keep-ctors` | dropped | keep constructor/record premises in the ground truth. |
| `--knn-k=N` | `32` | Phase-2 k-NN neighbourhood size. |
| `--knn-alpha=F` | `0.5` | Phase-2 blend weight `α·knn + (1−α)·lexical`. |

## Requires

Edge provenance **and** signatures in the graph. Without either the corpus is
empty and the run exits clean, saying which is missing.

See also: `AgdaGraph.PremiseBench` (the eval core),
`AgdaGraph.LemmaRank` / `AgdaGraph.PremiseSelect` (the rankers under test).
