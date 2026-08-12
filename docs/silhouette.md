# `silhouette` — statement shape vs. proof shape

A definition's out-edges split into a **signature** subgraph (edges from its
type) and a **body** subgraph (everything else). Weisfeiler-Lehman runs on each
independently.

## Why use it

- Separates two questions usually conflated: do these lemmas **state** the same
  thing, and do they **prove** it the same way?
- High signature overlap with low body overlap = the lemma was re-proved rather
  than reused.
- High overlap in both = a shared proof waiting to be factored out.

## Run

```bash
agda-optimization silhouette graph.json \
  --high-overlap=0.5 --low-overlap=0.2 --top-n=30
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `candidates considered` | definitions eligible as cluster seeds. |
| `signature / body edges` | how the provenance split fell out. A small signature count means the producer tagged little, and the clusters rest on thin evidence. |
| `combinator / copy-paste / mixed` | how the structural-twin clusters were classified. |

Per cluster:

| Field | Meaning |
|---|---|
| `body overlap` | weighted Jaccard of the members' body fingerprints. |
| `[combinator]` | same statement, nearly the same proof (above `--high-overlap`). Factor the shared proof out. |
| `[copy-paste]` | same statement, disjoint proofs (below `--low-overlap`). Unify the statements. |
| `[mixed]` | in between; read it before acting. |
| `sig-size` | nodes in the member's signature subgraph — how much shape the twin claim asserts over. |

## Act on

`[copy-paste]` clusters first: they are duplicated work, whereas
`[combinator]` clusters are merely an abstraction you have not named yet.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--high-overlap=F` | `0.5` | combinator-candidate threshold. |
| `--low-overlap=F` | `0.2` | copy-paste-reproof threshold. |
| `--wl-k=N` | `2` | WL refinement depth. |
| `--min-size=N` | `3` | min candidate subtree size. |
| `--min-cluster-size=N` | `2` | min twin-cluster size. |
| `--top-n=N` | `50` | clusters to keep. |

## Requires

`definitionEdgesProvenance` in the graph. Without it the analysis falls back to
plain fingerprint-equivalence with a stderr note, WL runs over all out-edges at
once, and the statement-vs-proof reading **does not apply** — the report's
legend switches accordingly. Regenerate the graph with a producer that emits
provenance to get the real analysis.

See also: [`fingerprint`](fingerprint.md) (what the fallback degenerates to),
[`concept-bundle`](concept-bundle.md) (signature vocabulary).
