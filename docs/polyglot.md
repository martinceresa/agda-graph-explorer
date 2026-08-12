# `polyglot` — definitions used across unrelated contexts

Clusters consumers with Louvain on the undirected projection, then scores each
definition by how evenly its consumers spread across those clusters.

## Why use it

- Separates "used a lot" from "used across many *unrelated* parts".
- Broad spread is the empirical case for generalising a lemma — it already
  serves audiences with nothing else in common.
- `★` rows are typeclass / abstraction candidates.

## Run

```bash
agda-optimization polyglot graph.json --min-uses=5 --threshold=0.5
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `nodes considered` | definitions that reached the scoring stage. |
| `dropped (min-uses)` | definitions with too few consumers to judge. |
| `communities found` | clusters Louvain settled on. |
| `modularity Q` | how cleanly the graph splits. Below ~0.3 the clustering is weak and `D` is worth less. |

Columns:

| Column | Meaning |
|---|---|
| `Tag` | `★` = ≥30 consumers and `D ≥ 0.8`, a genuine cross-cutting utility. `◆` = ≥10 consumers and `D ≥ 0.6`. `·` = widely used but concentrated (`D < 0.3`) — popular inside one community rather than polyglot. `[god?]` marks a definition with no line/size signal to rule out its being a god-object. |
| `\|cons\|` | consumers (ancestors in the dependency graph). |
| `\|clu\|` | distinct consumer communities. |
| `D` | diversity — Shannon entropy of the consumer-to-community distribution, normalised to `[0,1]`. A consumer in a re-exporting module counts half, one hop only. |
| `topClusters` | consumer counts in the largest few communities, biggest first. |

The trailing `promote:` / `split:` lines name the concrete move per candidate.

## Act on

`★`-tagged rows: high `|cons|` **and** high `D`. A high `|cons|` with low `D`
is a local workhorse — generalising it buys nothing.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-uses=N` | `5` | minimum consumer count to consider. The real gate. |
| `--threshold=F` | `0.5` | entropy threshold — **currently inert**, see below. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- The `[god?]` tag is suppressed when Louvain `Q < 0.1` — the clustering is too
  weak to make the claim.
- `--min-uses` is the only knob that changes which rows appear. Use it, plus
  `--top-n`, to scope the report.
- **`--threshold` currently filters nothing.** It is echoed in the header and
  the JSON payload (`diversity_threshold`), but never compared against `D`, so
  `--threshold=99` returns the same rows as `--threshold=0`. Read `D` and the
  `Tag` column yourself instead.
- `agda-optimization polyglot --help` misreports both defaults as `2` and `1.5`;
  the values above are what the code actually uses, as echoed in the report
  header line.

See also: [`strata`](strata.md) (module cohesion),
[`load-bearing`](load-bearing.md) (flow rather than spread).
