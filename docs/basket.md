# `basket` — co-usage association rules

Each definition is a transaction and its **direct** dependencies are the basket
(no transitive closure — universal primitives would drown the signal). Apriori
mines itemsets up to size 3 and turns them into rules `LHS ⇒ RHS`.

## Why use it

- A surviving rule says: when a proof uses the LHS it nearly always uses the
  RHS too — the two want to travel together as one abstraction.
- `## Near-miss bundles` names the sites that break the pattern: either a
  genuine exception, or a place that forgot the missing piece.

## Run

```bash
agda-optimization basket graph.json \
  --min-support=0.05 --min-confidence=0.6 --min-lift=1.5
```

## Reading the report

Header trailer:

| Field | Meaning |
|---|---|
| `tx` | transactions (definitions with a non-empty basket). |
| `qualifying` | baskets of size ≥2 — the only ones that can carry a rule. |
| `L1/L2/L3` | frequent itemsets found at size 1, 2 and 3. |
| `rules-considered` | candidate rules — the Bonferroni denominator. |
| `passed / kept` | rules surviving the statistical and threshold gates. |

Columns:

| Column | Meaning |
|---|---|
| `Support` | fraction of all transactions containing the whole bundle. |
| `Conf` | `P(RHS \| LHS)` — how reliably the LHS drags the RHS along. |
| `Lift` | `Conf` divided by the RHS's own base rate. `1.0` means the rule merely describes a popular definition; `> 1` is real association. |
| `Spec` | specificity = `Support × Lift`, the sort key. Rewards rules that are both frequent and non-obvious. |
| `p_corr` | Bonferroni-corrected upper bound on the Fisher p-value, over `rules-considered`. Rows above `0.01` were already rejected, so a printed row has survived multiple-testing control. |

Sections:

| Section | Meaning |
|---|---|
| `## Near-miss bundles` | definitions using k−1 of a k-item bundle — the actionable outliers. |

## Act on

High `Lift` before high `Support` — a lift near `1.0` tells you nothing however
frequent it is. Then read `## Near-miss bundles`.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-support=F` | `0.05` | min support. |
| `--min-confidence=F` | `0.6` | min confidence. |
| `--min-lift=F` | `1.5` | the "not a coincidence" floor. |
| `--exclude-top-frequency=F` | `5.0` | drop rules containing top-pct% items; `0` disables. |
| `--forced-suppress` / `--no-forced-suppress` | on | drop per-clause-unfold families (`VoteBlock-{0,1,2}`). |
| `--forced-fraction=F` | `0.5` | bundle-fraction gate for that suppressor. |
| `--max-basket-size=N` | `64` | drop baskets exceeding N items before counting; `0` disables. |
| `--budget=F` | `0` (unlimited) | wall-clock seconds. |
| `--top-n=N` | `100` | rules to keep after sort. |

## Notes

- `--budget` is essential on big projects — L₃ can reach 5M+ triples.

See also: [`entwine`](entwine.md) (low-frequency, high-determinism pairs that
support thresholds throw away), [`concept-bundle`](concept-bundle.md) (the same
mining restricted to type signatures).
