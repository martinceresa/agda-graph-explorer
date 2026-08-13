# `agda-optimization` subcommand reference

One page per subcommand: what the analysis does, how to read its report, why it
makes sense to use, and its flags.

Runnable recipes: [../Examples.md](../Examples.md). Flag reference:
[../README.md](../README.md). YAML config:
[../Configuration.md](../Configuration.md).

## Which one answers my question?

| Question | Subcommand |
|---|---|
| Where should I refactor first, to maximise blast radius? | [`load-bearing`](load-bearing.md) |
| What is used widely across disparate contexts? | [`polyglot`](polyglot.md) |
| What proofs are structural near-duplicates? | [`fingerprint`](fingerprint.md) (graph) / [`term-cluster`](term-cluster.md) (AST) |
| Which two definitions **answer** the same callers? | [`echo`](echo.md) |
| Which functions share a signature but diverge in body? | [`silhouette`](silhouette.md) |
| What recurring shapes does the project open-code by hand? | [`motif`](motif.md) |
| Which co-usage patterns suggest a missing combinator? | [`basket`](basket.md), [`entwine`](entwine.md) |
| Which signature vocabulary suggests a missing record? | [`concept-bundle`](concept-bundle.md) |
| What is my proof debt — which holes block exports, in what order? | [`debt`](debt.md) |
| What is my trust budget — which axioms support what? | [`ledger`](ledger.md) |
| Where are the bottlenecks from theorems to axioms? | [`chokepoint`](chokepoint.md), [`fiedler`](fiedler.md) |
| What are the centrality hot spots? | [`gravity`](gravity.md) |
| Where does the typecheck spend its time? | [`pyre`](pyre.md) (`--profile` to calibrate) |
| Which one definition, optimised, cuts the most aggregate cost? | [`pyre --levers`](pyre.md) |
| What is the proof geometry — diameter, radius, periphery? | [`horizon`](horizon.md) |
| Which modules have poor cohesion? | [`strata`](strata.md), [`polyglot`](polyglot.md) |
| Did my lemma-ranker change actually help? | [`hint-bench`](hint-bench.md) |

## By theme

- **Refactor leverage** — [`load-bearing`](load-bearing.md),
  [`gravity`](gravity.md), [`chokepoint`](chokepoint.md),
  [`polyglot`](polyglot.md)
- **Duplication** — [`fingerprint`](fingerprint.md), [`echo`](echo.md),
  [`silhouette`](silhouette.md), [`term-cluster`](term-cluster.md),
  [`motif`](motif.md)
- **Missing abstractions** — [`basket`](basket.md), [`entwine`](entwine.md),
  [`concept-bundle`](concept-bundle.md)
- **Trust and debt** — [`debt`](debt.md), [`ledger`](ledger.md)
- **Structure and geometry** — [`horizon`](horizon.md), [`strata`](strata.md),
  [`fiedler`](fiedler.md)
- **Build cost** — [`pyre`](pyre.md)
- **Tooling eval** (not a graph analysis) — [`hint-bench`](hint-bench.md)

## Common to every subcommand

All take the same expanded v2 `graph.json` from `agda-deps`.

| Flag | Effect |
|---|---|
| `--graph FILE` | input graph; usable in any position, wins over the positional. |
| `--json` / `--format=json` | JSON report instead of the human table. |
| `--out FILE` | write the report to a file (default stdout). |
| `--no-explain` | suppress the trailing `## How to read this` legend. |
| `--config FILE` | load defaults from a YAML file. |

Every human report ends with a `## How to read this` legend covering that
analysis' sections and columns — these pages are the same material, plus the
flags and the rationale, available before you run anything. JSON reports are
self-describing and carry no legend.

Precedence for the graph path: `--graph` > positional > `graph:` under
`global:` in the config. Merge order for everything else: **defaults → config →
CLI**.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success. |
| `1` | bad flags/subcommand, unreadable or mismatched graph, config failure. |
| `2` | [`fiedler`](fiedler.md) only: helper unavailable — script not found, or the interpreter could not be invoked. |
| `3` | [`fiedler`](fiedler.md) only: SciPy/NumPy not importable. |
| `4` | [`fiedler`](fiedler.md) only: any other helper fault (non-zero exit, unparseable output). |

## Extra inputs

Most subcommands need nothing beyond a default graph. These want more:

| Subcommand | Needs |
|---|---|
| [`term-cluster`](term-cluster.md) | producer `--with-term-hashes`. |
| [`silhouette`](silhouette.md) | `definitionEdgesProvenance` (else falls back to plain fingerprint twins). |
| [`concept-bundle`](concept-bundle.md) | signature-provenance edges. |
| [`hint-bench`](hint-bench.md) | edge provenance **and** signatures (`--with-signatures`). |
| [`fiedler`](fiedler.md) | `pip install scipy numpy`. |
| [`pyre --profile`](pyre.md) | a JSON `{qname: cost}` profile to calibrate against. |
