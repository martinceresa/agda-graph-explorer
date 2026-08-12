# `gravity` — random-walk centrality and blast radius

Combines three signals: reverse PageRank (demand flowing into a definition from
everywhere), one personalised PageRank per theorem, and HITS authority/hub. The
rank multiplies mass by spread.

## Why use it

- Surfaces the silent connective tissue that critical-path counting misses.
- A definition needs **both** heavy structural load and a broad audience to
  reach the top.
- Complements [`load-bearing`](load-bearing.md), which counts witnesses rather
  than diffusing mass.

## Run

```bash
agda-optimization gravity graph.json --top-theorems=64 --top-n=30
```

## Reading the report

Header line:

| Field | Meaning |
|---|---|
| `revPR iters / delta` | power-iteration sweeps used and the final L1 change. A delta near the tolerance means it converged; hitting the iteration cap with a large delta means the ranking is not settled. |

Columns:

| Column | Meaning |
|---|---|
| `Gravity` | `Mass × H(theorems)`, the sort key. |
| `Mass` | reverse PageRank — total demand flowing into this node. |
| `H(theorems)` | Shannon entropy (bits) of its PPR mass across theorems. High = many theorems reach it; near `0` = one theorem's private helper, however heavy. |
| `nzTh` | theorems with non-zero PPR mass here, out of those seeded. |
| `Auth` | HITS authority — pointed at by many hubs. Skews toward primitive sinks. |
| `Hub` | HITS hub — points at many authorities. Skews toward orchestration lemmas. |
| `Role` | whichever of `Auth` / `Hub` is larger; ties go to authority. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

## Act on

High `Gravity` with high `H` — load-bearing for the whole project rather than
for one theorem. If the header warns that `H` collapsed, the ranking fell back
to `mass × theorem count` and the spread signal is not available.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--top-theorems=N` | `64` | run PPR over the N heaviest theorems. |
| `--results=public\|tagged\|terminals` | `public` | theorem-set source. |
| `--damping=F` | `0.85` | PageRank damping. |
| `--iters=N` | `50` | max power-iteration steps. |
| `--tolerance=F` | `1e-6` | L1-delta convergence. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- `--top-theorems=64` is the sweet spot: fewer makes the entropy noisy, more
  dilutes per-theorem PPR mass.

See also: [`load-bearing`](load-bearing.md), [`chokepoint`](chokepoint.md),
[`pyre`](pyre.md).
