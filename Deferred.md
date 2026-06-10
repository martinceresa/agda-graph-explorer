# Deferred — answers to feature requests we didn't build (yet)

Companion to an external feature-request sweep on the graph consumers.
For longer-standing deferred / refused requests see
[Backlog.md](Backlog.md).

---

## #4 — Per-clause source spans for `using (…)` / `hiding (…)`

**Status:** Deferred (author concurs; no active consumer).

An earlier note already flagged this as deferred. Position:

- The line-scanner in `AgdaUnused.Source` is regex-grade — fine for
  the current `using` / `duplicate` / `blanket` checks because they
  only need to know *which module* an `open import` targets and
  whether a name was textually mentioned in the file.
- Per-clause spans (e.g., "the name `x₃` lives at columns 22–24 of
  line 47") need a real parser. Literate multi-line `using` /
  `hiding` lists straddle line boundaries; comments and unicode can
  inject false column offsets; whitespace/operator scanning has to
  understand Agda's mixfix syntax. None of that fits in
  `AgdaUnused.Source`.
- The right host for the data is the **producer** (`agda-deps`):
  Agda's parser already knows these spans. The cost would be threading
  them through the producer's expanded JSON (a new `imports[]` array
  per file, with `range :: Range` per clause).
- No consumer needs that today. The only candidate is `#10
  --wrap-private`, which is itself deferred.

**Reopen when**: a second consumer materialises (e.g. a refactor mode
that needs precise import-clause edit ranges, or an editor plugin
that wants per-name jump-to-definition).

---

## #10 — `agda-unused --wrap-private <name>` — assisted refactor

**Status:** Deferred. Parked behind #6 + #9 landing and reducing the
false-positive rate.

The case for the feature is real: agents repeatedly defer manual
`private`-wrapping because re-indenting 100+-line proof blocks with
nested `where` / `with` chains is error-prone, and several attempts
have already produced syntactic breakage that took longer to fix
than the wrap saved.

Why we're not building it now:

1. **Risk asymmetry.** Cost of a wrong wrap is "manually un-break a
   proof file"; cost of skipping a wrap is "one extra finding in
   the next sweep". Until #6 (instance binders) and #9
   (visibility filter) are bedded in, the noise floor is still too
   high to know how often this feature would *actually* fire on a
   real candidate vs. a false positive that should have been
   suppressed at analysis time. Solve the analysis problem first;
   reconsider the refactor problem after measuring what's left.
2. **Parsing surface is wide.** The matcher has to handle mixfix
   (`_∙_`, `_+_`), `infix` / `syntax` declarations, `record … where`
   blocks whose `field` declarations look like top-level defs,
   comments inside clause RHSs, with-clauses, copattern lambdas,
   `where` blocks at the bottom of a clause, and any of these
   nested arbitrarily. A regex-grade pass is not enough; we'd be
   re-implementing a partial Agda parser.
3. **What we'd want before building it.**
   - A sample-driven test corpus of known-good wraps (e.g. ~20
     real defs from the reference corpus of each shape) checked into `test/wrap/`.
   - `--dry-run` as the **default** mode: emit a unified diff for
     human review; require explicit `--apply` to write.
   - Refuse-and-explain on any def whose surrounding shape the
     matcher doesn't recognise — never guess.
   - End-to-end: after each wrap, `agda --type-check` the modified
     file before accepting the change.

This isn't "won't build"; it's "build later, when (a) we know the
analysis is calling out the right candidates, and (b) we've invested
in the test harness". For now, the analysis suppressions added in #9
already remove the bulk of repeat-flagging pain — agents can wrap by
hand, the tool stops re-asking.

**Belongs in `agda-unused`** — it's a source-rewriter, not a graph
analysis.

**Reopen when**: (a) #9's visibility filter has been deployed for a
sweep cycle and we can measure how many real wrap-candidates remain,
and (b) someone is willing to author the test corpus before any code
lands.
