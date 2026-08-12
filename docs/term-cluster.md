# `term-cluster` — repeated syntax below the dependency graph

Reads the per-definition subterm hashes `agda-deps --with-term-hashes` emits and
buckets occurrences by canonical-form hash.

## Why use it

- Sees the same canonical AST fragment recurring in unrelated proofs —
  common-subexpression candidates a graph-only analysis cannot reach.
- Cross-file CSE: a deep fragment repeated across several modules is an
  abstraction worth extracting.
- Complements [`fingerprint`](fingerprint.md), which matches dependency shape
  rather than syntax.

## Run

```bash
# 1. Producer — note the extra flags.
agda-deps --format=json --json-mode=expanded \
  --with-term-hashes --min-term-depth=3 --no-externals \
  -i src/ -o out/ src/Main.agda

# 2. Consumer.
agda-optimization term-cluster out/deps.json \
  --span-modules=3 --min-diversity=0.7 \
  --exclude-module-regex='^(Data|Function|Relation|Algebra|Agda)\.' \
  --top-n=10
```

## Reading the report

Columns:

| Column | Meaning |
|---|---|
| `Hash` | opaque 16-hex fingerprint of the canonical subterm. The source term does not cross the JSON boundary, so this is the only handle you get — stable enough to grep across runs. |
| `Size` | total occurrences project-wide. |
| `\|defs\| / \|mods\|` | distinct definitions and modules it occurs in. |
| `MeanD` | mean AST depth of the occurrences. Deep fragments are real structure; shallow ones are usually a variable or a constructor. `1.00` means the producer emitted no depths. |
| `Div` | diversity — normalised entropy of the per-module distribution. `0` = confined to one module; `1` = spread evenly across many. |
| `Score` | `Size × MeanD × (1 + Div)`. Ranking by `Size` alone is dominated by trivial shapes, which is what the other two factors correct. |
| `TopDefs` | the definitions carrying the most occurrences, with counts. |

## Act on

High `MeanD` and high `Div` before high `Size` — a deep fragment repeated across
several modules is the abstraction worth extracting. A huge `Size` at
`MeanD ≈ 1` is noise.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-diversity=F` | `0.0` (try `0.7`) | minimum module-distribution entropy. The single most discriminating knob. |
| `--span-modules=N` | `1` | minimum distinct modules a cluster's defs must span. |
| `--min-cluster=N` | `2` | minimum occurrences to report a cluster. |
| `--min-mean-depth=N` | `0` | minimum mean AST subterm depth. |
| `--sort=score\|log-score\|size` | `score` | `log-score` replaces `size` with `log(size)` to dampen size dominance. |
| `--exclude-module-regex=PATTERN` | none | POSIX-ERE on the declared module; drops matching defs before counting. |
| `--max-defs=N` | `3` | top-defs shown per cluster row. |
| `--top-n=N` | `50` | rows to keep. |

## Requires

Producer flag `--with-term-hashes` (tune volume with the producer's
`--min-term-depth=N`). Without those hashes the subcommand says so rather than
reporting an empty result.

## Notes

- Use `--sort=log-score` when shallow high-count noise still wins.

See also: [`fingerprint`](fingerprint.md), [`motif`](motif.md),
[`concept-bundle`](concept-bundle.md).
