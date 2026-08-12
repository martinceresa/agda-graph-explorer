# `concept-bundle` — vocabulary that recurs in type signatures

Apriori frequent-itemset mining (k ≤ 4) restricted to **signature-provenance**
edges.

## Why use it

- Finds lemmas whose **statements** converge on the same helper names even when
  their proofs have nothing in common.
- That is the case [`fingerprint`](fingerprint.md) and
  [`term-cluster`](term-cluster.md) miss by construction: the bundle exists in
  the types, never as a body clone.
- Such a bundle usually wants to be a record.
- No extra producer flag needed.

## Run

```bash
agda-optimization concept-bundle graph.json \
  --min-support=5 --min-lift=2.0 --min-span=3 --k-max=2 --top-n=25
```

## Reading the report

Header trailer:

| Field | Meaning |
|---|---|
| `tx` | definitions with a non-empty signature basket. |
| `qualifying` | baskets large enough to contribute a bundle. |
| `L1..L4` | frequent itemsets per size. `L4` only under `--k-max=4`. |
| `top-freq-excluded` | ubiquitous items dropped before mining. |

Columns:

| Column | Meaning |
|---|---|
| `Items` | the bundle — names that keep appearing in signatures together. |
| `Sup` | definitions whose signature contains the whole bundle. An **absolute count**, not a fraction: proof corpora are small. |
| `Lift` | how much more often they co-occur than independence predicts. |
| `Span` | distinct modules contributing. The gate that matters — below ~3 the bundle is one module's private idiom, not a cross-cutting concept. |
| `Spec` | `Sup × Lift × log(Span)`, the sort key. |

## Act on

High `Span` first, then `Lift`.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-span=N` | `3` | min distinct modules a bundle must span. |
| `--min-support=N` | `3` | absolute support count. |
| `--min-lift=F` | `2.0` | lift threshold. |
| `--k-max=N` | `3` | max itemset size (2–4). |
| `--exclude-top-frequency=F` | `5.0` | drop bundles with top-pct% items; `0` disables. |
| `--forced-suppress` / `--no-forced-suppress` | on | drop family-polluted itemsets (same machinery as [`basket`](basket.md)). |
| `--forced-fraction=F` | `0.5` | bundle-fraction gate for that suppressor. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- An empty table usually means the graph carries no signature provenance rather
  than that no bundles exist — check the header's `tx` and `L2` counts before
  concluding anything.

See also: [`basket`](basket.md) (all out-edges),
[`silhouette`](silhouette.md) (signature vs. body shape),
[`entwine`](entwine.md).
