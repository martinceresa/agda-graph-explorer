# `echo` — the reverse-direction dual of `fingerprint`

The same Weisfeiler-Lehman machinery runs over the **reverse** edges, so two
definitions cluster when they answer the same callers.

## Why use it

- On its own that mostly re-derives the forward clustering. The signal here is
  the **delta**.
- A reverse cluster whose members come from many different forward clusters is
  the interesting case: definitions that look unrelated by what they call, yet
  converge on the same audience.

## Run

```bash
agda-optimization echo graph.json --max-cluster-spread=0.3 --top-n=20
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `candidates considered` | definitions eligible as cluster seeds. |
| `forward / reverse clusters` | cluster counts in each direction. |
| `reverse-cluster pairs` | similarity comparisons that became reverse cluster edges. |
| `delta-actionable clusters` | reverse clusters spanning several forward clusters — the rows worth reading. |
| `rejected by --max-cluster-spread` | reverse clusters that collapsed to one or two forward clusters and were dropped as redundant. |

Per cluster:

| Field | Meaning |
|---|---|
| `reverse-Jaccard` | caller-set similarity floor holding the cluster together. |
| `forward-cluster-spread` | distinct forward clusters its members come from. `1` means `fingerprint` already told you this; high means it did not. |
| `(fwd-cluster N)` | which forward cluster each member belongs to. |

## Act on

Clusters with the highest `forward-cluster-spread`. A spread of `1` is noise
here — read it in [`fingerprint`](fingerprint.md) instead.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--max-cluster-spread=F` | `0.3` | reject clusters with spread/size below this; `0` disables. |
| `--delta-only` | off | show only reverse clusters with forward-spread > 1. |
| `--jaccard=F` | `0.8` | weighted-Jaccard threshold. |
| `--wl-k=N` | `2` | WL refinement depth. |
| `--wl-depth=N` | `0` (unbounded) | per-candidate subtree hop bound. |
| `--min-size=N` | `3` | min candidate subtree size. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- `--max-cluster-spread` rejects sink-funnel pollution — giant reverse-clusters
  forming at a project-wide consumer.

See also: [`fingerprint`](fingerprint.md) (the forward analysis this is read
against).
