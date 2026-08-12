# `strata` — does the declared module tree match the real one?

Classifies each module's out-edges as internal (same module), parent-internal
(an ancestor in the dotted tree — ordinary hierarchy traffic, neither rewarded
nor punished) or external. From that: Henderson-Sellers LCOM' and Martin's
instability and abstractness, folded into one incoherence score.

## Why use it

- Tests the module tree you **declared** against the dependencies you actually
  have.
- `## Top out-of-place external` names the concrete move — where the definitions
  want to live.
- Classical SE metrics, adapted: Agda has no interface concept, so datatypes
  proxy for the structural-shape role.

## Run

```bash
agda-optimization strata graph.json --min-size=3 --top-n=30
```

## Reading the report

Columns:

| Column | Meaning |
|---|---|
| `\|m\|` | definitions in the module. |
| `LCOM'` | `1 − internal/(internal + external)`. `0` = self-contained; `1` = every dependency leaves the module. |
| `spread` | distinct sibling-disjoint module prefixes the externals reach. High spread with high LCOM' means the module is not just outward-facing but scattered. |
| `I` | instability, `Ce/(Ca+Ce)` over distinct external modules. `1` = it depends on others and nothing depends on it; `0` = the reverse. |
| `A` | abstractness — the share of records, datatypes, postulates and holes. |
| `D` | `\|A + I − 1\|`, distance from Martin's main sequence. Near `0` is healthy (abstract-and-stable, or concrete-and-unstable). Near `1` is either a rigid abstraction nobody can change or a concrete module everything depends on. |
| `inc` | incoherence = `LCOM' × log(1 + spread) × \|D − (1 − I)\|`, the sort key. |

Sections:

| Section | Meaning |
|---|---|
| `## Top out-of-place external` | the modal sibling subtree each module leaks into — a child of its parent that is not its own subtree. Those definitions probably belong there, or that module belongs here. |

## Act on

The top `inc` rows, then their `## Top out-of-place external` line.

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--min-size=N` | `3` | skip modules with fewer than N defs. |
| `--exclude-module-regex=PATTERN` | none | POSIX-ERE on the full module name. |
| `--top-n=N` | `50` | rows to keep. |

## Notes

- Modules below `--min-size` are skipped entirely, so a small messy module will
  not appear at all. Smaller modules lack the internal structure for cohesion
  metrics.

See also: [`fiedler`](fiedler.md) (spectral seams),
[`polyglot`](polyglot.md) (cross-community usage),
[`horizon`](horizon.md) (per-module depth spread).
