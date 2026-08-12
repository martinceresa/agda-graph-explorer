# `chokepoint` — non-redundancy, not popularity

A node-capacitated min-cut (Edmonds–Karp, node-split) runs from the exported
theorems down to the axiom/leaf set, plus Tarjan articulation points. This finds
definitions sitting on a funnel of width 1 — the sole connector between the top
of the project and its foundations.

## Why use it

- Such a node may lie on very few critical paths and rank low in
  [`load-bearing`](load-bearing.md), yet nothing can be proved through it if it
  breaks.
- Betweenness smooths over funnels; min-cut does not.
- If the chokepoint is a postulate, it is the single assumption the whole
  project funnels through.

## Run

```bash
agda-optimization chokepoint graph.json --sources=exported --top-n=20
```

## Reading the report

Header line:

| Field | Meaning |
|---|---|
| `\|S\| / \|T\|` | source (exported) and sink (axiom/leaf) components. |
| `max-flow` | the cut's total capacity. Capacity is `1/(line+1)` per node: a unitless bias toward shallow, cheap-to-change nodes, **not** a line count. A small max-flow means a genuinely thin funnel. |
| `\|cut\| / \|art\|` | components in the min-cut and the articulation set. |

Columns:

| Column | Meaning |
|---|---|
| `Role` | `cut` = on the min-cut; `art` = an articulation point of the symmetrised graph; `cut+art` = both, the strongest signal and the only one carrying the 1.5× score bonus. |
| `Score` | cut multiplicity × `\|ancestors\|` × `\|descendants\|` — how much sits on each side of the funnel. |
| `up(S)` | definitions upstream, toward the theorems. |
| `down(T)` | definitions downstream, toward the axioms. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

## Act on

`cut+art` rows with large `up(S)` and `down(T)` — that node is the whole bridge.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--sources=exported\|public\|terminals` | `exported` | source-set selector. |
| `--sinks=postulates-axioms\|terminal-leaves` | `postulates-axioms` | sink-set selector. |
| `--exclude-name-regex=PATTERN` | none | POSIX-ERE on the unqualified name. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- The sink set falls back to `terminal-leaves` (with a stderr note) when the
  postulate-axiom set is empty.

See also: [`load-bearing`](load-bearing.md) (flow),
[`fiedler`](fiedler.md) (global spectral cuts), [`ledger`](ledger.md).
