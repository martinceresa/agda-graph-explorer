# `ledger` — per-theorem trust budget

For every public theorem the transitive postulate set is split into a
**foundational** part (`Agda.Builtin.*` / `Agda.Primitive.*`, which you trust
anyway) and a **paper-level** part — every other postulate, i.e. the assumptions
this project introduced itself.

## Why use it

- The paper-level set is the theorem's real trust budget, and the thing a
  reviewer asks about.
- Ranks axioms by leverage: which single assumption, discharged, clears the most
  theorems.
- Cohorts show which theorems become unconditional at the same moment.

## Run

```bash
agda-optimization ledger graph.json --top-n=30 \
  --theorem-prefix=Protocol.Example.Properties \
  --axiom-module-prefix=Protocol.Example.Assumptions
```

## Reading the report

Columns (`## Per-theorem trust footprint`):

| Column | Meaning |
|---|---|
| `axioms` | paper-level axioms the theorem depends on. `0` is the goal. |
| `found` | foundational postulates, counted separately — not project-specific debt. |
| `axiom names` | the first three paper-level axioms, then `...`. |

Sections:

| Section | Meaning |
|---|---|
| `## Axiom leverage` | per axiom, how many public theorems rest on it. The top row is the assumption whose discharge buys the most. |
| `## Cohorts` | theorems sharing an **exact** axiom set — a provable-together group. |
| `## Foundational postulates` | the trusted base surviving `--no-externals`, by module. |

## Act on

The top of `## Axiom leverage`, not the top of the theorem table — one
high-leverage axiom usually clears many theorems at once.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--axiom-source=postulate\|record-field\|both` | `postulate` | what counts as an axiom. |
| `--axiom-module-prefix=PREFIX` | none | repeatable; record-field-axiom module scope. |
| `--theorem-prefix=PREFIX` | none | repeatable; theorem-set scope (else project-only via `externals_summary`). |
| `--min-axioms=N` | `0` | only show theorems with ≥N axioms. |
| `--cohort-min-size=N` | `2` | only show cohorts with ≥N members. |
| `--no-foundational` | shown | suppress the foundational tail section. |
| `--top-n=N` | `50` | theorem rows. |

## Notes

- Pass `--axiom-source=record-field` (or `both`) if this project encodes its
  assumptions as record fields rather than postulates.
- `--theorem-prefix` is essential when the graph includes stdlib.

See also: [`debt`](debt.md) (holes and stubs rather than axioms),
[`chokepoint`](chokepoint.md) (the funnel from theorems down to axioms).
