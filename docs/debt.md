# `debt` — proof-debt ledger and payoff order

Every exported definition reaching a hole is conditional on that hole, so each
hole "covers" a set of exports. The schedule is the submodular greedy for
maximum coverage: each step picks the hole unlocking the most exports **not
already unlocked** by an earlier step.

## Why use it

- Turns "we have holes" into "fill these, in this order".
- Quantifies what is unconditional today vs. what rests on a stub.
- The greedy answers the real question — marginal gain, not hole size.

## Run

```bash
agda-optimization debt graph.json --top-n=20
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `Exp size` | the exported set coverage is measured against. |
| `Open holes` | definitions in the `Hole` state. |
| `Stub postulates` | postulates counted as debt, when included. |
| `Currently fully provable` | exports reaching no debt at all — the unconditional part of the project today. |

Columns (`## Greedy schedule`):

| Column | Meaning |
|---|---|
| `Step` | position in the payoff order, not a ranking of size. |
| `cov` | exports this hole covers in total. |
| `Δ` | **marginal** gain: exports it unlocks that no earlier step already did. This is the sort key, and why a big-`cov` hole can appear late with a small `Δ`. |
| `cum %` | cumulative share of `Exp` unlocked through this step. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

Sections:

| Section | Meaning |
|---|---|
| Gain bar | one cell per scheduled hole, scaled to the largest `Δ`. A long flat tail means the remaining debt is diffuse. |
| `## Hole-prereq edges` | holes depending on other holes. The prerequisite must be filled first regardless of what the schedule says. |
| `## Failed modules` | modules that did not typecheck. Their debt is **unknown** and folded into no number above. |

## Act on

Step 1 downwards — but read `## Hole-prereq edges` first, since a prerequisite
hole outranks the schedule. A non-empty `## Failed modules` means every
percentage here is optimistic.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--include-foundational` | off | treat `Agda.Builtin.*` / `Agda.Primitive.*` postulates as debt. |
| `--no-include-postulates` | included | exclude stub postulates from debt. |
| `--no-foundational-inventory` | shown | suppress the trusted-base table on clean projects. |
| `--top-n=N` | `50` | schedule rows. |

## Notes

- Foundational postulates are excluded by default so stdlib primitives don't
  dominate the schedule.

See also: [`ledger`](ledger.md) (which axioms each theorem rests on),
[`chokepoint`](chokepoint.md) (funnels down to those axioms).
