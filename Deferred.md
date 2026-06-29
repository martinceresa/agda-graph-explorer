# Deferred — feature requests we didn't build (yet)

For longer-standing deferred / refused ideas see [Backlog.md](Backlog.md).

---

## #4 — Per-clause source spans for `using (…)` / `hiding (…)`

**Status:** Deferred (no active consumer).

The line-scanner in `AgdaUnused.Source` is regex-grade — enough for the
`using` / `duplicate` / `blanket` checks, which only need *which module* an
`open import` targets and whether a name was textually mentioned. Per-clause
spans (e.g. "`x₃` at columns 22–24 of line 47") need a real parser: literate
multi-line lists straddle lines, comments and unicode inject false offsets,
and operator scanning has to understand mixfix. The right host is the
**producer** (`agda-deps`) — Agda's parser already knows these spans — at the
cost of a new per-clause `range` in the expanded JSON. No consumer needs it
today.

**Reopen when**: a second consumer materialises (a refactor mode needing
precise import-clause edit ranges, or an editor plugin wanting per-name
jump-to-definition).

---

## #10 — `agda-unused --wrap-private <name>` — assisted refactor

**Status:** Deferred, behind #6 + #9 reducing the false-positive rate.

The case is real — re-indenting 100+-line proof blocks with nested
`where` / `with` chains to add `private` is error-prone. Why not now:

1. **Risk asymmetry.** A wrong wrap means manually un-breaking a proof file;
   a skipped wrap means one extra finding next sweep. Until #6 (instance
   binders) and #9 (visibility filter) bed in, the noise floor is too high to
   know how often this would fire on a real candidate vs. a false positive
   that should have been suppressed at analysis time. Solve the analysis
   problem first.
2. **Wide parsing surface.** The matcher must handle mixfix, `infix` /
   `syntax`, `record … where` fields, comments in RHSs, with-clauses,
   copattern lambdas, and `where` blocks — nested arbitrarily. Regex-grade is
   not enough; it would re-implement a partial Agda parser.
3. **Prereqs before building:** a known-good wrap test corpus under
   `test/wrap/`; `--dry-run` (diff) as the default with explicit `--apply`;
   refuse-and-explain on any unrecognised shape; `agda --type-check` the
   modified file before accepting.

**Belongs in `agda-unused`** — it's a source-rewriter, not a graph analysis.

**Reopen when**: (a) #9's visibility filter has run a sweep cycle so we can
measure remaining wrap-candidates, and (b) someone authors the test corpus
first.
