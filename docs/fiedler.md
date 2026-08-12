# `fiedler` — spectral structure of the whole project

Computes the smallest non-trivial eigenpairs of the normalised Laplacian (via
SciPy, in `scripts/fiedler_helper.py`).

## Why use it

- A global view no local metric gives: where the graph nearly falls into two
  pieces, which modules are stringy chains rather than cohesive units, and which
  groups of definitions vibrate together across declared module boundaries.
- Names candidate seams for splitting a development.
- Shows where the project's real structure and its file structure have come
  apart.

## Run

```bash
agda-optimization fiedler graph.json --eig-k=5 --top-n=20
```

## Reading the report

Stats line:

| Field | Meaning |
|---|---|
| `nodes / component` | nodes in the graph, and in the largest component the spectrum was taken over. A big gap means the rest of the project is disconnected from what is analysed here. |
| `λ₂` | global algebraic connectivity. Near `0` = the graph is already nearly two pieces. |
| `eigvals` | the computed spectrum, ascending. The first is always ~0; a large jump after `λ₂` means the bisection is a genuine split rather than one of many equally good cuts. |

Sections:

| Section | Meaning |
|---|---|
| `## Bridge edges` | edges spanning the spectral bisection, ranked by the gap in the Fiedler vector across them. A large `Gap` means two nearly separate components joined by this one edge — a thin cut. |
| `## Algebraic-connectivity hotspots` | modules ranked **ascending** by λ₂ of their own subgraph. Low λ₂ = stringy: a linear chain rather than a connected unit. Compare against the global λ₂ printed beneath the heading. |
| `## Resonant clusters` | definitions sharing a sign pattern across `v₂..v_k`, kept only when they span ≥2 **declared** modules. Groups the graph treats as one unit while your module tree does not. |

Columns:

| Column | Meaning |
|---|---|
| `Gap` | `\|v₂(U) − v₂(V)\|` across the edge; the bridge sort key. |
| `λ₂` | algebraic connectivity of the module's largest component. |
| `Signature` | the cluster's sign pattern, one character per eigenvector. |
| `#Mods` | declared modules the cluster spans. |

## Act on

The top bridge edge and the lowest-λ₂ module.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--eig-k=N` | `5` | eigenpairs above λ₁. |
| `--helper=PATH` | `scripts/fiedler_helper.py` | helper script. |
| `--python=PATH` | `python3` | interpreter; needs `scipy` + `numpy`. |
| `--top-n=N` | `50` | rows to keep per section. |

## Requires

`pip install scipy numpy`. This is the **only** subcommand that shells out.
Helper precedence: `--helper=PATH` > `$AGDA_OPTIMIZATION_HELPER` > the cabal
`data-files` path. Exit codes are distinct: **2** = helper script not found,
**3** = SciPy/NumPy not importable. Both print a clean stderr diagnostic.

See also: [`chokepoint`](chokepoint.md) (local cuts),
[`strata`](strata.md) (declared-hierarchy cohesion).
