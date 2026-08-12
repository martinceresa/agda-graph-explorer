# `entwine` — pairs that travel together, by mutual information

Pairwise mutual information over caller baskets, gated by a G-test — frequency
is not the criterion.

## Why use it

- Catches what [`basket`](basket.md) cannot: a pair used by only three callers
  but used by them with perfect determinism. Support thresholds throw that away;
  it is exactly the bundle worth folding into a combinator.
- The same test catches the inverse — pairs systematically kept **apart**.

## Run

```bash
agda-optimization entwine graph.json \
  --min-co-callers=3 --min-iqr=0.5 --top-n=30
```

## Reading the report

Header trailer:

| Field | Meaning |
|---|---|
| `callers` | definitions with a non-empty basket. |
| `avg-basket` | mean basket size. Large baskets make spurious pairs more likely. |
| `excluded` | definitions dropped by `--exclude-name-regex`. |
| `pairs-counted / kept / emitted` | candidates, survivors of the gates, and rows printed. |

Columns:

| Column | Meaning |
|---|---|
| `n_xy` | callers using both. |
| `n_x` / `n_y` | callers using each. |
| `I` | mutual information in bits. Scale-dependent — read `IQR` instead. |
| `IQR` | `I` normalised by joint entropy: `1.000` = perfectly mutual, `0` = independent. The sort key and the real signal. |
| `G` | log-likelihood-ratio statistic, asymptotically χ² with 1 dof. The default gate `6.635` is `p < 0.01`, so a printed row is significant however small `n_xy` looks. |
| `anti` | `yes` = **anti**-coreference. Callers systematically choose one or the other — often two competing idioms rather than one bundle. |

## Act on

`IQR` near `1.000` with `anti=no`, even at small `n_xy` — that is a
deterministic bundle. `anti=yes` rows are worth reading for the opposite
reason: they usually mark a split the codebase never resolved.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-co-callers=N` | `3` | pair must co-occur in ≥N callers. |
| `--min-iqr=F` | `0.5` | min IQR. |
| `--min-g-stat=F` | `6.635` | min G-statistic (≈ `p < 0.01`). |
| `--transitive` | off | use ancestors as the basket instead of direct callers. |
| `--max-basket-size=N` | `0` (off) | drop baskets exceeding N items; auto-bounds under `--transitive`. |
| `--exclude-name-regex=PATTERN` | none | POSIX-ERE on the unqualified name. |
| `--top-n=N` | `100` | rows to keep. |

See also: [`basket`](basket.md) (frequency-driven rules over the same idea),
[`concept-bundle`](concept-bundle.md).
