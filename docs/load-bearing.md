# `load-bearing` — what the project's results rest on

Ranks definitions by how much proof structure flows through them. Edges point
user → usee, so results (exported, tagged or terminal) sit at the top and
critical paths walk down to primitive leaves.

## Why use it

- The refactor-blast-radius signal that in-degree misses.
- Answers "where do I refactor first" — not "what is popular".
- A **flow** measure: how many result-to-leaf witnesses touch a node. Compare
  [`horizon`](horizon.md) (distance) and [`chokepoint`](chokepoint.md) (whether
  a parallel path exists).

## Run

```bash
agda-optimization load-bearing graph.json --results=exported --top-n=20
```

## Reading the report

Header line:

| Field | Meaning |
|---|---|
| `\|V\|` | definitions in the graph. |
| `\|S\|` | seed results the critical paths start from. |
| `\|SCC\|` | strongly-connected components. Cycles (a datatype and its constructors, mutual recursion) are condensed first, so every member of an SCC carries that SCC's scores. |
| `D` | the longest result-to-leaf chain in the project. |

Columns:

| Column | Meaning |
|---|---|
| `dr` | depth rank — how deep beneath a result the node sits. Higher means a longer chain of users above it. |
| `spanBet` | span betweenness — fraction of per-result critical-path witnesses passing through the node. `1.000` = every result's critical path goes through it. |
| `Δ` | perturbation — how much the project's longest chain would shrink if the node were deleted. `0` means a parallel path already carries that depth; `-` means the row fell outside the perturbation cap and was not re-run. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

Sections:

| Section | Meaning |
|---|---|
| `## Advice` | one sentence per top candidate: why it ranked, and the structural consequence of touching it. |

## Act on

High `spanBet` with `Δ > 0` — both widely relied on and irreplaceable. High
`spanBet` with `Δ = 0` is popular but has a parallel route, so changing it is
cheaper than the rank suggests.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--results=tagged\|exported\|terminals` | `exported` | which definitions count as results. |
| `--weight=unit\|loc` | `unit` | weigh each result equally, or by line count. |
| `--exclude-name-regex=PATTERN` | `^[_─═]+$` | POSIX-ERE on the unqualified name. |
| `--top-n=N` | `50` | rows to keep. |

See also: [`chokepoint`](chokepoint.md) (non-redundancy),
[`gravity`](gravity.md) (random-walk centrality), [`horizon`](horizon.md)
(depth).
