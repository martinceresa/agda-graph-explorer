# TODO

Forward-looking work. Recipes: [Examples.md](Examples.md); deferred/refused:
[Backlog.md](Backlog.md), [Deferred.md](Deferred.md); shipped:
[Changelog.md](Changelog.md).

---

## Ideas

- [ ] Shrink the interact schema footprint — drop/shrink unused tools.

## Open

- [ ] **Arena CI regression gate** (G1–G4: find_lemma 10/10, misleading-* ties,
  live lemmas/auto). Needs an Agda-in-CI job (agda 2.9 + agda-deps + agda-stdlib
  2.4 graph); offline G1+G2 first, live G3+G4 second.
- [ ] **VerinaAgda benchmark** — re-run the A/B with the sig graph + availability
  hint; record per-rung uptake-when-stuck.
- [ ] **Stdlib federation follow-ups** — auto-build/register a stdlib overlay on
  first run; a producer flag keeping cross-boundary external edges as dangling
  refs (agda-deps), so `callers`/`impact` can cross into the overlay.
- [ ] **File-level option escapes (producer half)** — the consumer half ships
  (`moduleOptionEscapes` decoded, folded into `defUnsafe` by `buildIndex`, taint
  + `unsafe=` audit); needs `agda-deps` to emit the field for real projects.
- [ ] **Structural goal canonicalisation** — `agda-goals` canonicalises goal
  types textually; a `Term`-level version needs a Backend hook or a surface-AST
  parser (see `AgdaGraph.GoalCanon` haddock).
- [ ] **Surface-AST simplifier with typecheck rollback** — mechanical local
  rewrites with per-module typecheck + rollback; highest-risk; defer until
  `term-cluster` surfaces candidates. See [Backlog.md](Backlog.md).
