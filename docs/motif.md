# `motif` — recurring proof shapes

Mines connected subgraphs whose node labels (`Kind:State`) and edge directions
repeat across the project. Each row is a **shape**, not a definition.

## Why use it

- Names the idioms the project open-codes by hand.
- Definition identity is not part of the label, so one row can stand for dozens
  of unrelated sites that are structurally the same.
- A shape that recurs often and is bigger than a single edge is worth a
  combinator or a generic lemma.

## Run

```bash
agda-optimization motif graph.json --min-support=3 --max-size=3 --top-n=20
```

## Reading the report

Columns:

| Column | Meaning |
|---|---|
| `Rank` | position by `Score`, descending. |
| `Score` | `Support × (Size − 2)`. A two-node shape scores 0, so recurrence alone never wins — the shape must be big enough to be worth naming. |
| `Support` | MNI support: per motif node, how many distinct definitions it maps to, minimised over the nodes. Anti-monotone. |
| `Size` | definitions in the shape. |
| `Labels` | the node-label multiset, `Kind:State ×N`. |
| `ExampleSite` | one definition from one occurrence — the handle for grepping the rest. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

Trailer line:

| Field | Meaning |
|---|---|
| `considered` | distinct shapes enumerated. |
| `kept` | survivors of the filters: support, size, ≥2 host modules, label diversity, uniform-path suppression. |
| `hosts` | distinct modules the kept shapes touch. |
| `hub-excluded` | nodes dropped up front by `--exclude-hub-pct`. |

## Act on

Highest `Support` at `Size ≥ 3`. Open `ExampleSite` and judge whether the
repetition deserves a combinator or a generic lemma.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-support=N` | `3` | minimum embedding count. |
| `--min-size=N` | `2` | minimum motif size in nodes. |
| `--max-size=N` | `3` | maximum motif size in nodes. |
| `--min-label-distinct=N` | `2` | require ≥N distinct `(kind, state)` labels. |
| `--exclude-hub-pct=F` | off | drop the top pct% hub nodes by fan-in. |
| `--max-fan-out=N` | `32` | skip seeds whose fan-out exceeds N. |
| `--budget=F` | `0` (unlimited) | wall-clock seconds. |
| `--per-module` | off | currently warns and falls back to global mining. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- `--min-label-distinct=2` is the noise filter — without it, trivial
  `Function:D × N` chains dominate.
- Set `--budget` on large graphs; enumeration is the expensive part.

See also: [`term-cluster`](term-cluster.md) (repetition at the AST level),
[`basket`](basket.md) (repetition as co-usage rules).
