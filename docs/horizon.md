# `horizon` — proof geometry

How **far** things are, where [`load-bearing`](load-bearing.md) measures how
much flows. Forward eccentricity is the longest distance down to an axiom/leaf;
backward eccentricity the longest distance from a root theorem.

## Why use it

- Names the project's deepest results — the most expensive to re-prove.
- The per-module histogram shows which modules mix abstraction levels.
- A lemma can be high-flow yet shallow, or peripheral yet load-bearing. The two
  analyses disagree by design, and the disagreement is usually the informative
  part.

## Run

```bash
agda-optimization horizon graph.json --top-n=20
```

## Reading the report

Header line:

| Field | Meaning |
|---|---|
| `diameter` | the longest axiom-to-result chain: the depth of the deepest thing the project proves. |
| `radius` | the shallowest such chain over the root theorems. |
| `periphery / center` | how many nodes sit at the diameter and at the radius. |

Columns:

| Column | Meaning |
|---|---|
| `ε⁺` | forward eccentricity — distance down to the furthest leaf. |
| `ε⁻` | backward eccentricity — distance from the furthest root. |
| `ε⁺+ε⁻` | the sort key: deepest balanced results first. |
| `tag` | `periphery` = at the diameter; `center` = at the radius (both when it hits each); `root` = it **is** one of the header's roots (`ε⁻ = 0`); `leaf` = it **is** one of the leaves (`ε⁺ = 0`). |
| `-` | unreachable in that direction (reaches no leaf, or no root reaches it). Sorts to the bottom. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

Sections:

| Section | Meaning |
|---|---|
| `## Per-module ε⁺ histogram` | every definition's forward eccentricity, bucketed by module. A sharp peak means the module is a natural seam — everything sits at one depth. Buckets that fan out mean the module mixes abstraction levels and is a candidate for splitting. |

## Act on

The `periphery` rows, then the fanned-out modules in the histogram.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--leaves=postulates-axioms\|terminal-leaves` | `postulates-axioms` | forward-leaf set. |
| `--roots=public-theorems\|terminals` | `public-theorems` | backward-root set. |
| `--no-module-hist` | shown | suppress the per-module ε⁺ histogram. |
| `--exclude-name-regex=PATTERN` | none | POSIX-ERE on the unqualified name. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- Switch to `terminal-leaves` / `terminals` for projects without postulate-axiom
  or public-theorem conventions.

See also: [`load-bearing`](load-bearing.md) (flow), [`pyre`](pyre.md) (depth as
a cost predictor), [`strata`](strata.md).
