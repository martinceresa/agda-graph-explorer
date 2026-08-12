# `pyre` — graph-only typecheck-cost prediction

Models elaborator cost as a weighted sum of four structural features of the SCC
condensation: how much a definition reaches, how tangled that reachable set is,
what construct kinds it contains, and how deep it sits. No `agda` run.

`C = w1·|reach⁺| + w2·Σ fanIn·fanOut + w3·Σ wKind + w4·depthRank`

## Why use it

- Predicts build hot-spots before profiling.
- `--levers` answers the **dual**, more actionable question: which definition,
  made cheaper, cuts the most aggregate cost.
- `--profile` + `--calibrate` fits the weights to a real profile.

## Run

```bash
agda-optimization pyre graph.json --top-n=20 --levers

# Calibrate against a real agda profile:
agda-optimization pyre graph.json --profile=agda-profile.json --calibrate
```

## Reading the report

Header line:

| Field | Meaning |
|---|---|
| `\|SCC\|` | components after condensation. Each counts once in reach, however many definitions it contains. |
| `D` | maximum depth rank. |
| `weights` | `w1` reach, `w2` fan-in × fan-out, `w3` construct kinds, `w4` depth. |

Columns:

| Column | Meaning |
|---|---|
| `score` | the modelled cost `C(d)`. Compare rows; **do not read seconds**. |
| `reach` | components in the forward transitive closure. |
| `recDeps` | summed per-construct unfolding weight over that closure — records and datatypes heavy, postulates and primitives zero. |
| `depth` | position in the longest-path ranking. |
| `State` | `D` defined, `P` postulate, `H` open hole, `F` failed to typecheck. |

Sections:

| Section | Meaning |
|---|---|
| `## Calibration` | only with `--profile`. Spearman ρ says whether the proxy tracks observed cost at all; the fitted weights are what would track it better. Copy them into the `pyre:` config section to keep them, or pass `--calibrate` to apply them to this run. |
| `## Levers` | `lever = reachers × selfCost`. An attribution, not a counterfactual: it assumes only that the node leaves the reach sets, not whatever it was the sole path to. |

## Act on

The `## Levers` table over the main table when your goal is build time — the top
of the main table is usually a deep result you cannot make cheaper. Without
`--profile`, treat the ordering as a hypothesis.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--levers` | off | emit the lever table. |
| `--profile=PATH` | none | JSON profile `{qname: cost}`; emits the calibration report. |
| `--calibrate` | off | apply ridge-fitted weights to the ranking (needs `--profile`). |
| `--ridge-lambda=F` | `1.0` | L2 regularisation for the fit. |
| `--w1=F` | `1.0` | `\|reach⁺\|` coefficient. |
| `--w2=F` | `0.5` | `Σ fanIn·fanOut` coefficient. |
| `--w3=F` | `2.0` | `Σ wKind` coefficient. |
| `--w4=F` | `10.0` | `depthRank` coefficient. |
| `--exclude-name-regex=PATTERN` | none | POSIX-ERE on the unqualified name. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- `w4` dominates by default: depth in the SCC condensation is the strongest
  predictor of observed `agda --profile` time.

See also: [`load-bearing`](load-bearing.md), [`horizon`](horizon.md) (depth
itself), [`gravity`](gravity.md).
