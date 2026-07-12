# Deferred — feature requests we didn't build (yet)

For longer-standing deferred / refused ideas see [Backlog.md](Backlog.md).

---

## #4 — Per-clause source spans for `using (…)` / `hiding (…)`

**Status:** Deferred (no active consumer).

The line-scanner in `AgdaUnused.Source` is regex-grade — enough for the
`using` / `duplicate` / `blanket` checks, which only need *which module* an
`open import` targets and whether a name was textually mentioned. Per-clause
spans need a real parser (literate lists straddle lines, unicode injects false
offsets, mixfix scanning). The right host is the **producer** (`agda-deps`),
whose parser already knows these spans, at the cost of a new per-clause `range`
in the expanded JSON. No consumer needs it today.

**Reopen when**: a second consumer materialises (a refactor mode needing
precise import-clause edit ranges, or an editor plugin wanting per-name
jump-to-definition).

---

## #10 — `agda-unused --wrap-private <name>` — assisted refactor

**Status:** Deferred, behind #6 + #9 reducing the false-positive rate.

The case is real — re-indenting 100+-line proof blocks to add `private` is
error-prone. Why not now:

1. **Risk asymmetry.** A wrong wrap means un-breaking a proof file by hand; a
   skipped wrap means one extra finding next sweep. Until #6 (instance binders)
   and #9 (visibility filter) bed in, the noise floor is too high to tell a real
   candidate from a false positive. Solve the analysis problem first.
2. **Wide parsing surface.** The matcher must handle mixfix, `infix` / `syntax`,
   record fields, RHS comments, with-clauses, copattern lambdas, and nested
   `where` blocks — regex-grade would re-implement a partial Agda parser.
3. **Prereqs:** a known-good wrap corpus under `test/wrap/`; `--dry-run` diff as
   default with explicit `--apply`; refuse-and-explain on any unrecognised
   shape; `agda --type-check` before accepting.

**Belongs in `agda-unused`** — it's a source-rewriter, not a graph analysis.

**Reopen when**: (a) #9's visibility filter has run a sweep cycle so we can
measure remaining wrap-candidates, and (b) someone authors the test corpus
first.
