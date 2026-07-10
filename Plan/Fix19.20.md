# Fix plan — arena R19 + R20 (2026-07-10)

The two fresh requests from MCPBenchArena's 2026-07-09 powered P1 haiku×5 run
(`MCPBenchArena/Requests.md`), both **Owner: agda-explore** (consumer), both
on the interactive write-side exercised for the first time under a
model-in-loop ladder. This plan covers their fixes end-to-end: design, files,
tests, verification, and the doc/filing updates. Load-bearing claims below
were verified against a real cached stdlib graph
(`~/.cache/agda-explore/stdlib-jolteon/deps.json`).

Triage context for the other four new entries (not in this plan):

- **R15** (file-level `OPTIONS` soundness escapes) — producer-owned; the
  consumer half is already tracked in TODO.md, blocked on agda-deps Phase 2.
- **R16** (live-watch "how far behind" flag) / **R17** (`brief`/`path`
  closure coverage) — open consumer follow-ups, already tracked in TODO.md;
  designs sketched in the session plan, a separate batch.
- **R18** (mutually-recursive dead cycles) — **already shipped** here
  (I5 cycle resolution, commit `9b69b48`, `computeDeadCycles` SCC pass,
  unit-tested in `test/Spec.hs`). The arena entry predates that batch (the
  R1–R14 plan now in [FixRLess.md](FixRLess.md)); report back so they re-run
  with a planted mutual pair.

---

## R19 — `auto` reports "no solution" when its own hint lemma is out of import scope

### Problem

`auto`/`auto_all` seed Mimer with top graph-ranked lemma base-names, tried
one at a time (an out-of-scope hint aborts the whole `Cmd_autoOne` on
Agda 2.9; qualified names are rejected — hence bare base-names). When the
winning lemma's module isn't imported by the file, the hint probe fails with
a `NotInScope` error — which the code **computes and then discards**:

- `autoSolve` (`src/AgdaInteract/Tools.hs:581-601`): each `probe` returns
  `(Maybe solution, Maybe errorText)`; the hint loop binds `(m, _)` —
  the error is dropped, and the hint is indistinguishable from a genuine
  Mimer search failure.
- The final answer is `noSolution hints` (`Tools.hs:562-568`) — a flat
  "found no solution (tried lemma hints: …)" that reads as "unprovable".
- Contrast: `give term="+-identityʳ n"` on the same file surfaces the raw
  `NotInScope` error verbatim (`mutateFromGive`, `Tools.hs:909-917`). The
  server *can* see the missing-import fact; `auto` swallows it.

### Fix (arena option (b): detect + report actionably; no auto-import)

Auto-importing + retrying (option (a)) needs the temp-file revalidation
machinery (`loadRenamedTemp`/`validateText`) and changes file semantics
beyond the hole — deferred as a follow-up; `repair` already covers the
import-adding half once a term is in the file. The one-at-a-time hint
protocol is untouched (scope resolution is instant, so an out-of-scope hint
still costs ~nothing).

1. **Capture and classify the per-hint error.** `autoSolve`'s result type
   carries the partition:

   ```haskell
   data AutoResult
     = AutoGive (Maybe Text) Text
     | AutoNone (Maybe Text) [Text]
         -- ^ plain-probe error (as before) + the hints whose probe Agda
         --   rejected as out of scope, in try order
   ```

   `tryHints` accumulates: on a failed hint probe, keep the error and test
   `hintOutOfScope h err`.
2. **Classifier in `AgdaRepair.Diagnostic`** (exported there, not in
   Tools.hs, so the existing test suite covers it directly):

   ```haskell
   hintOutOfScope :: Text -> Text -> Bool
   hintOutOfScope h err =
        h `elem` notInScopeNames err
     || ("NotInScope" `elem` errorTags err && h `T.isInfixOf` err)
   ```

   Precise path first (the structured NotInScope name list; hint names are
   dot-free base names, so the dot-splitting tokenizer is safe), substring
   fallback hedges wire-shape drift. Lenient: anything else stays a plain
   failure — behavior degrades to today's.
3. **Hint→Definition provenance.** `goalHintNames`
   (`src/AgdaMcp/Query.hs:1295-1309`) strips candidates to bare base-names,
   discarding the `Definition`. Add
   `goalHintCands :: Loaded -> Int -> Text -> [(Text, Definition)]`
   (rank-ordered, deduped on name keeping first) and reimplement
   `goalHintNames = map fst . goalHintCands`. `runAuto` fetches the
   snapshot itself (`ensureFresh`, mirroring `runAutoAll`) and keeps the
   pairs; `collectHints` (`Tools.hs:606-611`) becomes dead — delete it.
   Using the ranked candidate's own `Definition` is exact by construction
   (the hint *came from* that def) — no `resolveModuleFor` re-vote.
4. **Message.** On `AutoNone` with a non-empty out-of-scope list, append
   (new helper `oosNote`), with the import line rendered by
   `AgdaRepair.Strategy.importLineFor` (add it to Strategy's export list —
   it already handles the constructor-parent-module nuance):

   > Note — 1 graph-ranked hint(s) for this goal are not in the file's
   > import scope, so Mimer could not try them:
   >   - `+-identityʳ` — add `open import Data.Nat.Properties using (+-identityʳ)`
   > Add the import(s) and re-run `auto`, or run `repair file=…` to add
   > them for you.

   Honest phrasing: untried candidates, not verified closers.
5. **`auto_all`**: `autoAllLoop` returns a fourth component — the
   order-preserving dedup union of out-of-scope hints across `AutoNone`
   goals — appended after the survivors block via the same `oosNote`-style
   rendering (one `Map Text Definition` over the concatenated per-goal
   candidate lists). No change to session-dirty semantics (a scope-aborted
   probe solves no meta).

### Files

- `src/AgdaRepair/Diagnostic.hs` — `hintOutOfScope` (exported).
- `src/AgdaRepair/Strategy.hs` — export `importLineFor`.
- `src/AgdaInteract/Tools.hs` — `AutoResult`, `autoSolve`, `runAuto` +
  `oosNote`, `runAutoAll`/`autoAllLoop`; delete `collectHints`.
- `src/AgdaMcp/Query.hs` — `goalHintCands` (shared with R20).

---

## R20 — `lemmas`/`find_lemma` flat ranking; `goal` arg rejects JSON integer

### Problem (ranking half)

`rankGoalCandidates` (`src/AgdaMcp/Query.hs:1272-1287`) scores
`(weightedCoverage, tokenJaccard, negate bagSize)` and finally tiebreaks on
`defName` **alphabetically**. For goal `n + zero ≡ n` (verified on the real
stdlib graph):

- goal tokens `{+, zero, ≡, Identity, RightIdentity, LeftIdentity}`
  (weighted denominator 8); the `+`-identity family covers 5 → flat 62.5%.
- `matchTokens` qualifier-strip (`GoalCanon.hs:314-343`) maps
  `Data.Nat._+_` and `Data.Integer._+_` both to `+`, so the ℕ and ℤ
  variants' token bags are **byte-identical** — a complete tuple tie,
  resolved alphabetically (`Data.Integer` < `Data.Nat`). The correct
  instance loses to every ℤ variant. (`Data.Sign.Properties.*-identityʳ`
  also hits 62.5% — its sign literal `+` tokenizes — but already sorts
  below on Jaccard; the head-of-list bug is exactly Nat-vs-Integer.)
- The discriminating signals exist but are unused: the candidate's
  `defModule` (in hand at rank time), and — in the live `lemmas` path —
  the goal *context* (`n : ℕ`), one `iotcmGoalTypeContext` call away
  (`runLemmas`, `src/AgdaInteract/Tools.hs:1952-1964`, binds and discards
  `_sess _file _iid`; `runGoalBrief` at `Tools.hs:1970-1986` shows the
  fetch pattern).

### Fix (carrier-module affinity as a tie-breaker, in a new testable core)

`AgdaMcp.Query` imports `AgdaMcp.State` (fsnotify/process-heavy), so the
test suite can't compile it. Move the free-text ranking core into the
shared library where the suite already reaches.

1. **New module `src-agda-graph/AgdaGraph/LemmaRank.hs`** (added to the
   `agda-graph` library's `exposed-modules`). Pure, `Loaded`-free:

   ```haskell
   data RankEnv = RankEnv
     { reDefs    :: ![Definition]        -- realDefs of the snapshot
     , reAliases :: !(Map Text Text) }   -- ldAliases (may be empty)

   -- (weightedCoverage, tokenJaccard, carrierAffinity, negate bagSize)
   type LemmaScore = (Double, Double, Int, Int)

   rankLemmaCandidates :: RankEnv -> (Definition -> Bool) -> Double
                       -> Text -> [Text] -> [(LemmaScore, Definition)]
   goalCarrierSegments :: RankEnv -> Text -> [Text] -> Set Text
   moduleSegments      :: Text -> Set Text   -- stoplist-filtered
   genericSegments     :: Set Text
   ```

   - Coverage/Jaccard/bag: verbatim move of today's `rankGoalCandidates`
     body. **Affinity sits third** — after Jaccard — so only exact
     `(coverage, jaccard)` ties reorder (maximally G1-safe; the verified
     Nat/Integer tie is on both components). `defName` ASC stays the final
     tiebreak. The `[Text]` argument is the live context types;
     **it feeds affinity only, never `gtoks`/coverage**.
   - Carrier map: base-name → defining modules over `reDefs` restricted to
     constructors/datatypes/records (keeps `zero`'s module set principled),
     plus alias entries from `reAliases`. Verified degradation: the real
     stdlib graph carries **zero** renames — the alias source is a bonus,
     not a dependency (real-def lookup of `ℕ`/`zero` already yields a
     `Nat` segment).
   - Goal-side carrier tokens: non-operator, vocab-kept `matchTokens` of
     the goal conclusion (**without** `shapeTokens` — `RightIdentity` must
     never drive carriers), unioned with the same extraction over each
     context type.
   - Affinity: `Set.size` of the intersection between the goal's carrier
     segments and `moduleSegments (defModule d)`; stoplist
     (`Data`, `Agda`, `Builtin`, `Base`, `Properties`, `Core`, `Relation`,
     `Binary`, `Algebra`, `Function`, `Level`, …) keeps generic path
     segments from matching. `Data.Nat.Properties` → `{Nat}` → 1;
     `Data.Integer.Properties` → 0.
2. **Rewire `Query.hs`**: `rankGoalCandidates` becomes a thin wrapper over
   `rankLemmaCandidates (RankEnv (realDefs ld) (ldAliases ld))` with a new
   trailing `ctxTypes` parameter; `queryFindLemma` threads it (read side
   passes `[]`). `lemmaList` appends a marker on rows with affinity > 0 —
   `[carrier: Nat]` (the matched segments, comma-joined) — so the flat
   menu is visually differentiated; the displayed percentage (`pctOf` of
   coverage) is unchanged.
3. **Live `lemmas` enrichment**: `runLemmas` fetches the context via
   `iotcmGoalTypeContext` (pattern from `runGoalBrief`), extracts
   `[ceType c | c <- ces, ceInScope c]`, degrades to `[]` on any
   non-`GiGoalType` reply. `runGoalBrief` restructured to fetch once and
   share. `find_lemma` (read side) stays context-free by design.
4. Synergy: `goalHintNames`/`goalHintCands` inherit the affinity tiebreak,
   so R19's `auto` tries the ℕ instance before the ℤ one — fewer wasted
   hint probes.

Degradation: empty carrier set (no matching defs, no aliases, overlay-less
graphs) → affinity 0 everywhere → ranking byte-identical to today. Graphs
without signatures are already excluded by the ranking core.

**Known non-fix (document, don't chase):**
`Data.Nat.Binary.Properties.+-identityʳ` scores 0.75 (its identity element
is literally *named* `zero`, covering the goal's `zero` token) and stays
above the correct lemma — a coverage-level artifact the tiebreak can't and
mustn't touch (G1 safety). The `[carrier: Nat]` marker at least flags both
Nat-family rows.

### Problem + fix (goal-id half)

`withGoal` (`Tools.hs:1167-1170`) reads the goal via `argText`
(`src/AgdaMcp/ToolDef.hs:72-73`), which decodes only JSON **strings** — a
client sending `{"goal": 0}` gets "this tool requires a `goal` argument…"
even though `parseStableId` (`src/AgdaInteract/GoalId.hs:111-116`) already
accepts `"0"`. Fix: a scalar-tolerant accessor in `ToolDef.hs`
(reusable; keeps `withGoal` one line):

```haskell
argScalarText :: Value -> Text -> Maybe Text
argScalarText v k = case argLookup v k of
  Just (String t)   -> Just t
  Just n@(Number _) -> T.pack . show <$> (parseMaybe parseJSON n :: Maybe Int)
  _                 -> Nothing
```

(integral-only via aeson's `Int` instance — no new dependency). `withGoal`
switches to it and the error message echoes the accepted forms
("a stable id like `g0` (a bare integer such as 0 also works)").
`resolveLoaded`'s `argText a "file"` stays string-only (correct).

### Files

- `src-agda-graph/AgdaGraph/LemmaRank.hs` (new) +
  `agda-graph-explorer.cabal` (`exposed-modules` line).
- `src/AgdaMcp/Query.hs` — wrapper `rankGoalCandidates`, `queryFindLemma`
  ctx param, marker in `lemmaList`, `goalHintCands`.
- `src/AgdaInteract/Tools.hs` — `runLemmas`/`runGoalBrief` context fetch;
  `withGoal`.
- `src/AgdaMcp/ToolDef.hs` — `argScalarText`.

---

## Tests + verification (both)

New `lemmaRankTests` in `test/Spec.hs` (registered next to
`goalCanonTests`; the suite already depends on `agda-graph` and compiles
`AgdaRepair.Diagnostic`), using the **verified real stdlib signatures** as
fixtures:

1. *Arena repro*: `Data.Nat.Properties.+-identityʳ` vs
   `Data.Integer.Properties.+-identityʳ` vs `Data.Sign.Properties.*-identityʳ`
   (+ carrier def `zero` as a constructor) — for goal `n + zero ≡ n`:
   Nat strictly above Integer; **both coverage components equal 0.625**
   (pins that coverage did not change — the G1 tripwire); Sign last (Jaccard).
2. *Carrier extraction*: `goalCarrierSegments` contains `Nat`, excludes
   stoplist segments; empty env → empty set.
3. *Context enrichment*: affinity flows from `ctxTypes = ["ℕ"]` only;
   coverage identical with/without context.
4. *Alias path* + *no-renames determinism pin*: alias-only env still finds
   `Nat`; empty-alias env → affinity 0 → today's `defName` ASC order.
5. *R19 classifier*: `hintOutOfScope "+-identityʳ"` true on a
   `[NotInScope]`-shaped message naming it (extend the existing
   `notInScopeMsg` golden), false on an `UnequalTypes` message.
6. `argScalarText`: string / integral number / non-integral number.

End-to-end:

- Read side: `agda-explore query find_lemma goal="n + zero ≡ n"
  --graph <stdlib sig graph>` → ℕ instance above the ℤ variants,
  `[carrier: Nat]` visible.
- Live (`RungB.agda`: goal `n + zero ≡ n`, imports only `Data.Nat`):
  `auto goal=g0` → out-of-scope note naming
  `open import Data.Nat.Properties using (+-identityʳ)`; after adding the
  import, `auto` still solves (regression). `lemmas goal=g0` → ℕ instance
  first (context feeds the carrier).
- Gates: `cabal test interaction-spec`; VerinaAgda `micro_bench.py` stays
  10/10; arena `ci_gate.py` G1–G4; determinism untouched (no change to
  agda-unused/agda-optimization).

## Sequencing

1. `AgdaGraph.LemmaRank` + cabal line (compiles alone).
2. `Query.hs` rewire (wrapper, ctx param, marker, `goalHintCands`).
3. Call sites: read-side `find_lemma` (`[]`), `runLemmas`/`runGoalBrief`.
4. R19: `Diagnostic.hs` `hintOutOfScope`, `Strategy.hs` export,
   `AutoResult`/`autoSolve`/`runAuto`/`runAutoAll`.
5. R20.3: `ToolDef.hs` `argScalarText` + `withGoal`.
6. `Spec.hs` tests; suites + arena gate re-run.

## Risks

- **G1 gate**: affinity sits after Jaccard — only exact
  `(coverage, jaccard)` ties reorder; the coverage-equality test assertion
  pins the primary metric. Re-run the gate regardless.
- **Agda error-text drift (R19)**: classifier is lenient (unknown → plain
  failure = today's behavior); golden fixtures pin the wire shape; the
  substring fallback hedges.
- **Stoplist judgement**: small, documented, unit-tested; a missed generic
  segment would boost wrong candidates.
- **Over-claiming (R19)**: message says "could not be tried", never "would
  close the goal".

## Docs + filing

- `Issues.md`: file **I7** (R19, bug: discarded scope error → confident
  false negative) and **I8** (R20, calibration: under-discriminating
  ranking + the goal-id integer dead-end), each with resolution notes,
  including the `Data.Nat.Binary` known limitation.
- `Changelog.md`: one "Arena-feedback round 3 (R19 + R20)" entry.
- `TODO.md`: no new entries (R19/R20 close on ship).
- `MCPBenchArena/Requests.md`: record the upstream IDs (I7/I8) on R19/R20,
  and correct R18's status (shipped in `9b69b48`, pre-dates their
  verification build — re-run with a planted mutual pair).
