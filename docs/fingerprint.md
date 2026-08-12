# `fingerprint` — near-duplicate proofs, structurally

Refines each definition's rooted dependency subtree with Weisfeiler-Lehman
colouring, summarises it as a colour histogram, and clusters definitions whose
histograms are close (weighted Jaccard above the threshold).

## Why use it

- Finds duplicates that no textual search can: the match is structural, not
  lexical.
- Default `--direction=incoming` groups definitions that **answer the same
  callers**; `--direction=outgoing` groups by callees.
- Candidates for unification into one lemma.

## Run

```bash
agda-optimization fingerprint graph.json \
  --direction=incoming --jaccard=0.8 --wl-k=2 --top-n=20
```

## Reading the report

Header block:

| Field | Meaning |
|---|---|
| `candidates considered` | definitions eligible as cluster seeds. Synthetic and unknown-shape nodes are skipped as seeds, though they still appear inside other candidates' subtrees. |
| `pairs evaluated` | similarity comparisons actually made. |
| `pairs above threshold` | those that became cluster edges. |
| `pairs skipped (same owner)` | pairs from one parent definition. A datatype and its own constructors are trivially similar and say nothing. |

Per cluster:

| Field | Meaning |
|---|---|
| `avg sim` | mean pairwise similarity inside the cluster. `1.000` means the fingerprints are identical, not that the source text is. |
| `size` | nodes in that member's subtree — how much structure the match asserts over. Size 2 subtrees are weak evidence; size 20 is strong. |
| `[D]` / `[P]` / `[H]` | the definition's state: defined, postulate, open hole. |

## Act on

Large clusters of large subtrees first. WL is a heuristic and false positives
are expected — read two members before unifying anything.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--direction=outgoing\|incoming\|both` | `incoming` | which graph drives WL. |
| `--jaccard=F` | `0.8` | weighted-Jaccard threshold. |
| `--wl-k=N` | `2` | WL refinement depth. |
| `--wl-depth=N` | `0` (unbounded) | per-candidate subtree hop bound. |
| `--min-size=N` | `3` | min candidate subtree size. |
| `--top-n=N` | `20` | clusters to keep. |

## Notes

- `outgoing` conflates "proofs sharing helpers" into a mega-cluster — prefer
  the default unless you specifically want callee-shape matching.

See also: [`echo`](echo.md) (the reverse-direction dual),
[`silhouette`](silhouette.md) (statement vs. proof shape),
[`term-cluster`](term-cluster.md) (AST fragments).
