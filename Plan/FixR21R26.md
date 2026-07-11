# Fix plan: arena requests R21–R26

## Context

`../MCPBenchArena/Requests.md` R21–R26 (found 2026-07-10, Phase-4 W-family
probes against agda-explore `7e35e70`/`c3b4c4c`) report six defects in the
write-side interaction bridge and the `repair`/`new_module` resolvers. All six
were verified against the current source — each report's mechanism is visible
in the code:

| Req | Defect | Mechanism (verified) | Severity |
|-----|--------|----------------------|----------|
| R21 | Guard refuses pragmas/keywords in comments & literate prose | `checkGiveInput`/`checkFileInput` pragma scans run on **raw** text (Guard.hs:54, 94); only the identifier scan comment-strips; no `.lagda.md` awareness | Blocks legit literate files |
| R22 | Mutators splice against stale disk state | Goal ids keyed purely by char offset (GoalId.hs); `SessionEntry` stamps no content identity; `--no-watch` never flips `seDirty` | **Silent corruption** |
| R23 | `auto`/`check` Mimer non-preemptible; `timeout` cosmetic | `-t` bounds only Mimer's search, not goal normalization; session budget is a fixed 60 s **inactivity** timeout (Tools.hs:934), not wall-clock | Session wedge / DoS-on-self |
| R24 | Write-side resolvers ignore the `renaming` alias index | `Strategy.buildEnv` uses only `ldRealDefs`; `resolveModuleFor` likewise; read side has `ldAliases` (R14) | Aliases unauthorable |
| R25 | `repair` renames `ℕ` → `_#_` (spec corruption) | ℕ not a graph node (alias) → rename fallback; `lev` over **underscore-stripped** keys (`strip "_#_" = "#"`, distance 1); `isSigLine` protects only column-0 lines | **Spec-preservation violation** |
| R26 | `repair` can't fix parse-level missing imports | `parseErrorNames`' `pick` keeps only tokens with `_`/non-alphanumeric chars (drops `just`, `nothing`); tokenizer delimiter set contains `,` (drops `_,_`) | Predicted-win cases lost |

**Maintainer decision (R25):** remove the rename path entirely (arena's ask),
keeping the near-match machinery only as a *suggestion* in the failure
message. `repair` becomes import-only → structurally spec-preserving.

Arena gates to re-verify after landing: W1 + W8 (R21), W7 (R22, R23),
W4 (R24, R25, R26) — `../MCPBenchArena/runners/followup_gates.py`.

---

## Cross-cutting facts

- Test suite: single offline `interaction-spec` (`test/Spec.hs`, hand-rolled
  harness — `check :: String -> Bool -> Check`, `checkEq`; groups are
  `[Check]` lists registered in `main`). CI never runs `agda`.
  `AgdaRepair.Strategy` is currently **not** in the suite (blocked by its
  `AgdaMcp.State` import) — R24 fixes that.
- Live harness: `test/interaction/convergence.py` drives a real daemon
  (`--enable-interact`) through load/give/apply/reload loops. Not CI.
- Content hashing: reuse the vendored Murmur64
  (`AgdaGraph.GoalCanon.hashString`) per the CLAUDE.md gotcha — no new dep.
- `ldAliases :: Map Text Text` (State.hs:270, built 711–713): key =
  `<rxFrom>.<alias>` host-qualified (`"Reexports.combine"`), value = canonical
  node-key (`"Core.Base.merge"`). Source: `ReExport.rxRenames`
  (Schema.hs:162–172, wire key `"renames"`, decodes `mempty` on old graphs).
  Overlay re-exports are federated (`AgdaGraph/Union.hs:90`).
- `AgdaGraph.LemmaRank` (`RankEnv { reDefs, reAliases }`,
  `goalCarrierSegments`, `moduleSegments`) is State-free and tested
  (`lemmaRankTests`) — the reusable carrier-affinity core.

### Invariants that must survive (CLAUDE.md)

1. Zero-axiom contract: every current guard **rejection** still rejects; only
   false positives flip. Repair candidates still pass `checkFileInput` first.
2. Spec preservation: strengthened — with renames removed, repair edits are
   import-line insertions only; the `signatures`-set equality assertion in
   `firstWorking` stays as belt-and-braces.
3. Monotone termination (`accepts`): each accepted candidate adds a new
   distinct import line; text strictly grows in a finite universe; `max_iter`
   caps the loop.
4. `parseErrorNames` reads the expression on the line(s) *after*
   `Could not parse …` — only the tokenizer/filters over those lines change.
5. Burst protocol: `JSON> ` prompt delimiting, reader thread, byte-level
   prompt handling untouched. `agda-goals` shares `AgdaInteract.Session` —
   plain `sendIotcm` semantics must not change; re-run the `-N1`/`-NK`
   byte-identity check after touching Session.hs.
6. Positions are 1-based **char** offsets; all new slicing uses `Data.Text`
   char indexing.
7. Anything running `Cmd_autoOne` without writing keeps `markSessionDirty`.
8. Read-side alias behavior (locate tier-2.5, search aliasHits) untouched.

---

## R21 — make the guard source-region aware

**Files:** `src/AgdaInteract/Guard.hs`, `src/AgdaInteract/Literate.hs`,
`src/AgdaInteract/Tools.hs` (call sites), `test/Spec.hs`.

### Design: one "guard view" scanner + a literate-aware entry point

The root asymmetry exists because `stripComments` treats `{-#` as a `{-`
opener and would delete pragmas, so the pragma scan *couldn't* run
post-strip. Replace it with a single left-to-right scanner (modeled on
`AgdaRepair.Edit.renameInBody`'s `walk`, which already does comment+string
scanning):

```haskell
-- Guard.hs
guardScrub :: Text -> Text
```

Scanner cases at comment-depth 0, in match order:
- `{-#` → copy **verbatim** through the matching `#-}` (or to EOF if
  unterminated — preserving pragmaContents' unterminated-still-checked
  behavior). A `--` inside a preserved pragma (`{-# OPTIONS --safe #-}`) must
  not start a comment — handled by the verbatim copy.
- `--` → drop to `\n` (keep the newline).
- `{-` → drop the nested block (reuse existing `dropBlock`; a commented-out
  pragma `{- {-# TERMINATING #-} -}` is removed with its comment because its
  `{-`/`-}` pairs balance).
- `"` → emit the quote, **blank** contents to the closing unescaped `"` or end
  of line (Agda strings are single-line; bounding at `\n` limits damage from a
  stray quote such as the char literal `'"'`), emit the closing quote. This
  also closes a latent **bypass**: today `s = "{- "` opens a phantom block
  comment that can swallow real code containing `postulate`.

Then:
- `checkGiveInput`: compute `v = guardScrub input` once; pragma test becomes
  `"{-#" \`T.isInfixOf\` v`; `hits = … (tokens v)`. Messages unchanged.
- `checkFileInput`: `badPragmas = filter isBadPragma (pragmaContents v)`;
  `hits` likewise over `v`.
- New literate-aware entry point (Guard may import Literate — Literate
  imports only `Data.Text`, no cycle):

```haskell
checkFileInputFor :: FilePath -> Text -> GuardVerdict
checkFileInputFor fp txt =
  checkFileInput (T.intercalate "\n" (codeSlices (codeBlocksFor fp txt) txt))
```

- `Literate.hs` gains and exports the span extractor (`CodeBlocks` is
  abstract, so it must live there):

```haskell
codeSlices :: CodeBlocks -> Text -> [Text]
codeSlices (CodeBlocks spans) txt = [ T.take (e - s) (T.drop (s - 1) txt) | (s, e) <- spans ]
```

  (`scanCodeBlocks` emits one span per code line; rejoining with `"\n"`
  reconstructs multi-line pragmas faithfully.)
- Exports: add `checkFileInputFor`, `guardScrub`; **drop** `stripComments`
  (update its one Spec test) — don't leave two subtly-different scrubbers.

### Call-site switches (Tools.hs)

- `firstWorking` (1486): `checkFileInputFor file text'`.
- `proceedGiveFile` (1569): `checkFileInputFor file candidate`.
- `runNewModule` (1630): `checkFileInputFor file content` (scaffold is fenced
  for a literate path by `buildModuleContent`).
- `runPromote` (729): **keep** plain `checkFileInput` — the guarded text is a
  scratch-module body, always plain Agda; it gets comment/string symmetry via
  `guardScrub` for free.
- `checkGiveInput` sites (395, 1770): unchanged call shape; bare hole terms
  gain the same scrub symmetry.

### Edge cases

- Every fence in a `.lagda.md` is treated as code (`scanCodeBlocks`'s
  documented behavior) — a ```` ```text ```` block quoting `postulate` is
  still refused. Deliberately unchanged: `CodeBlocks` is shared with the
  splice guard (`isInsideCode`); tightening to ```` ```agda ```` would change
  splice behavior. Note in Haddock.
- Char literal `'"'` mis-opens a string and blanks the rest of that line —
  could *hide* a forbidden token there; contrived, and the session's `--safe`
  is the backstop (same limitation as `renameInBody`). Document.
- Prose pragma spanning a fence boundary: slices joined with `\n`, scan still
  sees it — fails closed.

### Tests (Spec.hs)

`guardTests`: allow `"f -- note: {-# TERMINATING #-}\n"`,
`"f {- {-# OPTIONS --type-in-type #-} -}"`, `"show \"postulate\""`; still
reject `{-# TERMINATING #-} f`, `postulate bad : A`, `primTrustMe`; reject
`"g = \"{-\"\npostulate x : A"` (blanking must not hide following code).
`fileGuardTests`: pragma in line/block comment → Allowed; string-quoted
pragma → Allowed; `checkFileInputFor "Doc.lagda.md"` with pragma/`postulate`
in prose → Allowed, same tokens inside the fence → Rejected,
`{-# OPTIONS --safe #-}` in fence → Allowed; `checkFileInputFor "M.agda"` ≡
`checkFileInput` (regression). `literateTests`: `codeSlices` on a two-fence
sample. `checkEq` pins on `guardScrub` (pragma preserved, comment removed,
string blanked).

---

## R22 — content-stamp the loaded state; refuse stale mutations

**Files:** `src/AgdaInteract/Registry.hs`, `src/AgdaInteract/GoalId.hs`,
`src/AgdaInteract/Tools.hs`, `test/Spec.hs`. (`Session.hs` untouched.)

### Design: three layers + external-change id reset

**1. Load-time stamp.** `SessionEntry` gains
`seLoadHash :: !(Maybe Word64)` — `Nothing` = unknown (file unreadable, or it
changed mid-load) and mutators refuse until a clean reload restamps.
`Registry.hs` also gains:

```haskell
contentStamp :: Text -> Word64          -- hashString . T.unpack (vendored Murmur64)

shouldKeepGoalIds :: Maybe Word64 -> Maybe Word64 -> Maybe Word64 -> Bool
-- (expected bridge-write hash) (previous stamp) (new stamp)
shouldKeepGoalIds mExpect mPrev mNew = case (mNew, mExpect, mPrev) of
  (Just h, Just w, _)       -> h == w     -- bridge write: keep iff disk is what we wrote
  (Just h, Nothing, Just p) -> h == p     -- plain reload: keep iff content unchanged
  _                         -> False      -- unknown stamp / first load: reset
```

`loadAndSync` (Tools.hs:949) gains a `Maybe Word64` expected-write-hash
parameter and **brackets** `Cmd_load` with two reads:

```haskell
preH  <- stampOf file            -- BEFORE sendIotcm iotcmLoad
out   <- sendIotcm …
postH <- stampOf file            -- AFTER
let stamp  = if preH == postH then preH else Nothing   -- unstable bracket → unknown
    gmBase = if shouldKeepGoalIds mExpect (seLoadHash =<< mPrev) stamp
               then gm0 else dropEntriesKeepNext gm0
-- SessionEntry sess gm1 (isNothing stamp) luRef stamp   (dirty when unknown)
```

Rationale: read-before alone is fail-safe but read-after alone is unsound (an
edit between Agda's read and ours would make the stamp match disk while goals
came from old content). The bracket closes the mid-load window; residual risk
(edit-and-revert to byte-identical content inside the bracket) documented and
accepted.

**2. Mutate-time check.** New helper:

```haskell
readSourceStamped :: ServerState -> FilePath -> IO (Either Text Text)
```

Reads the file; if a registry entry exists: stamp match → `Right txt`;
mismatch → `Left "the file changed on disk since this session's last load — \
re-run \`load file=…\` and pick goals from the fresh list (ids may have been \
renumbered); nothing was changed."`; `seLoadHash = Nothing` → `Left` (file was
changing during load). No entry (e.g. `give_file` on an unloaded file) →
`Right txt`. Replaces `readFileSafe` at the offset-splicing sites:
`runGiveMany` (402), `runAutoAll` (564), `constructMany` (1777), and
`withSourceGuarded` (895 — gains a `ServerState` parameter; sole caller
`applyHoleEdit` has it). **Not** `proceedGiveFile` — `give_file` is
whole-content authoring with no offset splicing (covered by layer 3).

`constructLoop` (1797) reloads per step; edits splice into the **original**
text — after each per-step `doLoad`, compare the fresh stamp against
`contentStamp orig` (small `currentStamp :: ServerState -> FilePath -> IO
(Maybe Word64)` over `readMVar ssSessions`); mismatch aborts the batch:
`"construct: the file changed on disk mid-batch — nothing applied; re-run load."`

**3. Write-time recheck.** `applyOrDiff` (867), immediately before
`TIO.writeFile`: re-read; if readable and `contentStamp now /= contentStamp
old` → refuse (`"changed on disk while the edit was being prepared — nothing
written"`). Unreadable + `old` non-empty → refuse; unreadable + `old == ""` →
proceed (give_file new-file creation). This single gate also protects
`runPromote`/`runRepair`, whose validation runs minutes between read and write.

**Bridge-write continuity.** New:

```haskell
doLoadAfterWrite :: ServerState -> Word64 -> FilePath -> IO (Either Text (Session, GoalMap, [GoalEntry], FilePath))
```

= `loadAndSync ss (Just h) file`. Callers: `applyOrDiff`'s write branch
(`doLoadAfterWrite ss (contentStamp new) file`) and `runNewModule` (1654,
hash of `content`). All other loaders (`runLoad`, `runAutoAll`,
`constructLoop`, `resolveLoaded`, `runCheck`) stay on the `Nothing` path
(`doLoad ss file = loadAndSync ss Nothing file`).

**Id reset that fails loudly.** `GoalId.hs` gains:

```haskell
dropEntriesKeepNext :: GoalMap -> GoalMap
dropEntriesKeepNext gm = gm { gmByStable = M.empty }   -- counter PRESERVED
```

Critical detail: `emptyGoalMap` would reset `gmNext = 0`, so after an external
edit the first hole becomes `g0` again and a client's stale cached `g0`
*silently retargets* — recreating the bug one level up. Preserving the counter
makes a stale id resolve to "not an open goal" (loud). Extend the module
Haddock's "Scope of stability" paragraph and the `load` tool description; add
"or the file changed on disk and ids were renumbered" to `withGoal`'s
not-an-open-goal message.

### Behavior changes to call out

- A mutator issued between "client applied the returned diff" and "client
  re-`load`" now hard-refuses (previously silently spliced; only watch mode's
  dirty flag rescued it). Matches the documented GoalId contract.
- A failed load over *changed* content now drops goal entries (previously
  preserved unconditionally) — strictly more correct; the old iids are dead in
  Agda anyway.
- Perf: two extra reads + Murmur64 per load, one per mutation, one per write —
  noise next to `Cmd_load`.

### Tests

Offline (`stampTests` group): `contentStamp` equality/difference/unicode;
`shouldKeepGoalIds` 6-case truth table; `dropEntriesKeepNext` + `syncGoals`
composition (drop then re-sync same offsets → fresh ids `g2`,`g3`; `g0`
lookup → `Nothing`). Live (convergence.py scenario): load (note `g0`) →
externally swap an equal-length token → `construct give g0` → expect the
stale-disk error and byte-identical file → `load` → old id refused, fresh ids
listed → `auto goal=<fresh> write:true` applies → follow-up `load` keeps
surviving ids (bridge-write continuity). Run the existing convergence loop
end-to-end (it exercises `doLoadAfterWrite`).

---

## R23 — wall-clock budgets for Mimer probes

**Files:** `src/AgdaInteract/Session.hs`, `src/AgdaInteract/Tools.hs`,
`test/Spec.hs`. (`Cmd_abort` deliberately out of scope — no builder exists in
Iotcm.hs and its wire behavior needs live-Agda verification; the established
poison→respawn model is the fix vehicle. Revisit as a stretch.)

### Key correction to the naive fix

`collectBurst` applies `sTimeout` **per event read** — it is an *inactivity*
timeout, not a wall budget (a chatty burst may legally exceed 60 s; a silent
normalization wedge hits it at exactly 60 s). So the fix adds a true
**deadline** variant and leaves plain `sendIotcm` byte-identical (a big
`Cmd_load` streams events for minutes without being 60 s silent — changing
default semantics would break loads).

### Session.hs

```haskell
sendIotcmBudget :: Int -> Session -> String -> IO SendOutcome   -- wall-clock µs for the whole burst
```

Factor `collectBurst` into `collectBurstWith :: Session -> IO Int -> IO
SendOutcome` where the `IO Int` yields the next `readChan` timeout: default
path constantly returns `sTimeout`; budget path computes a deadline once from
`GHC.Clock.getMonotonicTimeNSec` and returns the remainder. **Clamp:** if the
remainder ≤ 0, do NOT call `System.Timeout.timeout` (non-positive = wait
forever — a landmine); poison and return `SendTimeout` directly. Expiry
poisons exactly like today (`sAlive := False`; `getLiveSession` respawns on
next use). Fix the `scTimeoutMicros`/`sTimeout` Haddocks ("per-command
inactivity budget (between reply events)").

### Tools.hs

```haskell
probeGraceSecs :: Int
probeGraceSecs = 5                       -- dispatch + scope resolution + modest normalization

probeBudgetMicros :: Int -> Int
probeBudgetMicros secs = (max 1 secs + probeGraceSecs) * 1000000
```

- `autoSolve` (516): probes call `sendIotcmBudget` directly (not `runRaw`) so
  `SendTimeout` is distinguishable. Plain probe: `probeBudgetMicros secs`;
  hint probes: `probeBudgetMicros hintSecs`. New constructor
  `AutoAbort !Text` on `AutoResult`: budget expiry / session death → the
  session is dead, remaining hints skipped. Message: *"Mimer/goal work
  exceeded its ⟨secs⟩s+⟨grace⟩s wall budget — the Agda session was reset and
  reloads on the next command; retry with a larger `timeout`, or guide the
  goal with `construct` refine/case_split or `lemmas`."*
- `runAuto` (457): `AutoAbort m → Left m`.
- `autoAllLoop` (611): on `AutoAbort` stop probing (further sends would only
  fast-fail), return collected edits + an abort note (extend the result tuple
  with `Maybe Text`); remaining goals join `unsolved`. Collected edits stay
  valid (confirmed GiveActions in ORIGINAL offsets) and still flow to
  `spliceRanges`/`applyOrDiff`; `markSessionDirty` stays (successes may
  precede the abort — invariant 7). `write:true` still works because
  `applyOrDiff` → `doLoadAfterWrite` respawns via `getLiveSession`.
- `autoHints` (1272): probes use
  `sendIotcmBudget (probeBudgetMicros (cfgAutoHintsSecs c))`; on expiry/death
  skip remaining candidates. Signature → `IO ([(GoalEntry, Text)], Maybe
  Text)`; `runCheck` threads the note into `renderCheckLive` (appended, e.g.
  *"auto-hints probe exceeded its ⟨n⟩s budget on ⟨gid⟩; remaining goals not
  probed — the session was reset and reloads on the next command"*).
  `runCheck`'s verdict/diagnostics/goals are computed **before** `autoHints`
  runs — a mid-check poison cannot lose the check output; keep that ordering.
- `runStepEdit`'s `op == "auto"` (1833): budgeted send (`probeBudgetMicros 5`,
  Mimer opts unchanged) so a lone construct auto step can't wedge a batch.
  `give`/`refine`/`case_split` keep session defaults (a heavy but legitimate
  elaboration after a give is not a probe). Flag as the only semantics change
  outside probe paths.
- Never budget loads: `loadAndSync` and the throwaway validate sessions
  (600 s) stay on plain `sendIotcm`.

Worst-case wall for one `auto` call: first expiry poisons the session and all
subsequent probes short-circuit on the `sAlive` check, so real worst wall ≈
the first probe's budget. (Per-call hard ceiling — one deadline threaded
through `autoSolve` — noted as a rejected alternative: more plumbing, little
gain.)

### Tests

Offline: `probeBudgetMicros` arithmetic/clamping; extract pure message
builders (`budgetMsg`) and pin; `renderCheckLive` with a `Just note` over a
tiny fixture. Live (convergence.py sibling scenario, the report's repro —
local `pow`, goal `pow 2 24 ≡ 16777216`): `auto goal=g0 timeout=2` returns in
≈7 s naming the budget + reset; immediate `load` succeeds (respawn); `check`
returns full verdict + skip note in ≈ `cfgAutoHintsSecs + 5` s; `construct
steps=[{op:auto, goal:"*"}]` on trivial+heavy two-goal file → diff for the
solved goal + abort note. Then re-run the `agda-goals` `-N1`/`-NK`
byte-identity check (Session.hs was touched).

---

## R25a — remove the rename path (maintainer decision)

**Files:** `src/AgdaRepair/Strategy.hs`, `src/AgdaRepair/Edit.hs`,
`src/AgdaRepair/Diagnostic.hs` (comment), `src/AgdaInteract/Tools.hs`,
`test/Spec.hs`, `FixLoop.md`, `CLAUDE.md`.

Lands **before** the Env refactor — it shrinks the surface R24 must reshape.

- `Strategy.candidatesFor`: `DScope name -> imports name` (imports only, same
  as `DParse`). Delete `graphNearMatches`; keep `lev` + `nearMatches` solely
  for suggestions (below).
- `Edit.hs`: delete `ERename`, `renameInBody` (and its `walk` scanner —
  but only after R21 has copied its comment/string scanning idiom into
  `guardScrub`), `isProtectedLine`. `data Edit = EAddImport !Text` remains
  (keep the `Candidate = [Edit]` shape for future extensibility);
  `applyEdits`/`insertImport`/`signatures`/`isSigLine` stay. The
  `signatures`-equality assertion in `firstWorking` stays as belt-and-braces
  (an `open import …` line never classifies as a sig line).
- Failure-message suggestions instead of edits — new Strategy export:

```haskell
nearMissSuggestions :: Env -> Text -> Text -> [Text]   -- env, src, name → closest existing names
```

  (in-scope + graph base-name near matches, distance ≤ 2, closest-first,
  capped at 3). `repairLoop`'s `"no candidate resolved: X"` appends
  `" — closest existing names: a, b (repair does not rename; fix the spelling
  or add the missing import/definition by hand)"`.
- `describeEdits` (Tools.hs) drops its rename arm.
- Spec.hs: remove `renameInBody` pins from `repairEditTests` (keep
  `insertImport`/`isSigLine`/`applyEdits`); add a `candidatesFor` pin: DScope
  yields **no** edit kind other than `EAddImport`.
- Docs: FixLoop.md invariant 1 and the CLAUDE.md repair gotcha rewritten —
  *"repair is import-only; renames were removed (R25). Spec preservation is
  structural: the only edit is an import-line insertion, and the
  `signatures`-set assertion remains as a backstop."* `DScope`'s Haddock in
  Diagnostic.hs updates ("resolve by adding an import").

---

## R24 (+R25b) — alias-aware, State-free, carrier-ranked resolvers

**Files:** `src/AgdaRepair/Strategy.hs`, `src/AgdaInteract/Tools.hs`,
`src-agda-graph/AgdaGraph/LemmaRank.hs`, `agda-graph-explorer.cabal`,
`test/Spec.hs`.

### LemmaRank (small, backwards-compatible)

Split so the expensive map is a parameter; export the pieces:

```haskell
carrierMap         :: RankEnv -> Map Text (Set Text)      -- newly exported
envVocab           :: RankEnv -> Set Text                  -- newly exported
carrierSegmentsFor :: Map Text (Set Text) -> Set Text -> Text -> [Text] -> Set Text
-- goalCarrierSegments env g cs = carrierSegmentsFor (carrierMap env) (envVocab env) g cs
```

`lemmaRankTests` must stay byte-identical (pure refactor).

### Strategy — the core refactor

Drop `import AgdaMcp.State`; the `Env` constructor stays unexported so the
representation is free to change:

```haskell
data EnvEntry
  = EntryDef   !Definition      -- honest graph def
  | EntryAlias !Text !Text      -- (alias short name e.g. "ℕ"/"combine", host module e.g. "Data.Nat.Base")

data Env = Env
  { envByBase     :: !(Map Text [EnvEntry])   -- key = stripUnderscores base name
  , envCarrierMap :: Map Text (Set Text)       -- lazy: LemmaRank.carrierMap over defs+aliases
  , envVocab      :: Set Text                  -- lazy
  }

buildEnv :: [Definition] -> Map Text Text -> Env   -- ldRealDefs + ldAliases
```

Alias entries: split each `ldAliases` key `Host.alias` on the last `.`
(`T.breakOnEnd`); Env key = `stripUnderscores alias`, entry =
`EntryAlias alias host`. The sum type is deliberate — never fabricate a
`Definition` (no fake `defId`/`defKind` flowing into `importLineFor`/
`oosNote`); ranking pattern-matches (alias ranks as public, non-constructor,
module = host). The alias *value* (canonical node-key) is **not** used for the
import line — the alias is only in scope via the host.

Accessors:

```haskell
entryBaseName    :: EnvEntry -> Text     -- mixfix form for using-lists ("_×_", "ℕ", "combine")
entryModules     :: EnvEntry -> [Text]   -- EntryDef ctor → [moduleParent m, m]; plain def → [defModule];
                                         -- EntryAlias → [host]
entryImportLines :: EnvEntry -> [Text]   -- "open import M using (base)" per candidate module
importLineFor    :: Definition -> Text   -- UNCHANGED (Tools.hs:499 oosNote depends on it)
```

`importCandidates` iterates `[EnvEntry]`; an alias hit for bare
`combine`/`ℕ` yields exactly `open import <Host> using (<alias>)`.

Carrier-affinity ranking (R25b half): new

```haskell
fileCarrierSegments :: Env -> Text -> Set Text
-- carrierSegmentsFor (envCarrierMap env) (envVocab env) "" [sig-line RHSs of src]
```

`importCandidates` gains a carrier-segments parameter; the rank tuple becomes

```haskell
rank e = ( Down (module ∈ already)                                        -- unchanged, strongest
         , entryIsPrivate e
         , Down (Set.size (segs ∩ moduleSegments (entryModule e)))         -- NEW: carrier affinity
         , exotic (entryModule e)
         , T.length (entryModule e) )
```

New export for `new_module` (module names, preserving its `open import M` /
`import M` output shape):

```haskell
resolveImportModules :: Env -> [Text] -> Text -> [Text]
-- env, carrier-hint type strings (stub types), bare name → ranked candidate modules
```

Shares `importCandidates`' ranking; returns `entryModules` heads-first — for a
constructor the **parent** module comes first, fixing the broken
`open import Agda.Builtin.Nat.Nat` (which came from `resolveModuleFor`
counting raw constructor `defModule`s).

### Tools.hs

- `runRepair` (1385):
  `RS.buildEnv (maybe [] ldRealDefs mld) (maybe M.empty ldAliases mld)`.
- Rewrite `resolveImports` (1676) onto Strategy; **delete**
  `resolveModuleFor`/`lastCompT`:

```haskell
resolveImports :: RS.Env -> [Text] -> Bool -> [Text] -> ([Text], [Text])
-- step nm = case RS.resolveImportModules env hints nm of (m:_) -> Left (kw <> m); [] -> Right nm
```

- `runNewModule`: build the env once; pass `[ ty | DefStub _ ty <- defs ]` as
  carrier hints (so `"ℕ → ℕ"` → segment `Nat` → `Data.Nat`-family modules
  outrank other exporters of the same short name).

### Build/test plumbing

- cabal: add `AgdaRepair.Strategy` to interaction-spec `other-modules` (its
  remaining deps — Schema, LemmaRank, Diagnostic, Edit, containers, text —
  are already in the suite).
- Spec.hs, new `strategyTests` (reuse the `mkDef` fixture helper):
  - plain def: `_×_` found under bare `×` (pins pre-existing behavior, now
    offline-testable);
  - alias: env with `"Reexports.combine" ↦ "Core.Base.merge"` →
    `importCandidates "combine"` contains
    `"open import Reexports using (combine)"`;
  - ℕ alias: `"Data.Nat.Base.ℕ" ↦ "Agda.Builtin.Nat.Nat"` →
    `"open import Data.Nat.Base using (ℕ)"`;
  - mixfix alias: key `"Host._∔_"` resolves under bare `"∔"`, emits
    `using (_∔_)`;
  - constructor parent: `mkDef "Agda.Builtin.Nat.Nat.zero"` `KConstructor` →
    `resolveImportModules env [] "zero"` head = `"Agda.Builtin.Nat"` (the
    exact new_module repro);
  - alias + real-def key collision: both offered;
  - carrier ranking: `_+_` from `Data.Nat.Base` vs `Data.Integer.Base`; sig
    hint `f : ℕ → ℕ` ranks Nat first; empty segs preserves today's order
    (determinism pin);
  - `nearMissSuggestions` pin (from R25a).

### Edge cases

- Alias short name colliding with a real def: both entries under one key;
  repair's recompile disambiguates, `new_module` takes the ranked head.
- Empty graph (cold `ensureFresh`): `buildEnv [] M.empty` — degrades to
  "unresolved, add by hand", same as today.
- Old overlay graphs without `renames` decode to `mempty` → today's behavior;
  extend `new_module`'s unresolved note: *"if the name is a `renaming`
  re-export, rebuild the overlay graph with a renames-emitting agda-deps"*.
- `open:false` + alias: emits `import Host` (alias then only qualified) —
  same semantics as for real defs; note in tool docs.

### R25 verdict

`new_module`'s R25 half is fully covered by alias resolution (ℕ resolves at
all) + constructor-parent (no more `Agda.Builtin.Nat.Nat`) + carrier ranking
(right module among several). `repair`'s R25 half is dead by construction
(no rename path) *and* ℕ now resolves to a real import candidate.

---

## R26 — recover parse-level missing imports

**Files:** `src/AgdaRepair/Diagnostic.hs`, `src/AgdaRepair/Strategy.hs`,
`src/AgdaInteract/Tools.hs`, `test/Spec.hs`.

### Step 0 (manual, before coding): capture real Agda 2.9 fixtures

Run real `agda` by hand on (i) a file using `_×_`/`_,_` with `Data.Product`
dropped, (ii) a file pattern-matching `just`/`nothing` with the import
dropped — capture **round-1 AND round-2** (after adding the first import)
error texts as inline `Text` fixtures in Spec.hs (style of `parseAppMsg`,
Spec.hs:869). Round-2 texts decide the `accepts` question below empirically.

### Diagnostic.hs

1. **Expression tokenizer** for the lines after `Could not parse …` /
   `Problematic expression:` only (the "read the line(s) after" gotcha
   discipline is untouched):

```haskell
exprTokens :: Text -> [Text]
-- delimiters " \t\r\n(){};|" — ',' and '.' are NOT delimiters here;
-- post-split: strip leading/trailing '.', drop pure-digit and "." tokens
```

   `,` survives as a token (rendered dumps space applications); Env lookup
   already works: `stripUnderscores "," == ","` matches `_,_`'s key, and
   `nameKeys ","` yields `_,_` for the membership oracle. A raw-source dump
   that glues `,` to an identifier misses that round — accepted limitation,
   documented.
2. **`pick` extension**: keep symbolic tokens (as now, plus `,`); additionally
   keep **alphabetic** tokens with `T.length ≥ 2`, not a stopword, not an Agda
   keyword (new list `agdaKeywords = ["with","where","rewrite","let","in",
   "do","open","import","module","record","data","field","λ","forall"]` —
   separate from `stopWords`, which `notInScopeNames` shares), not all-digits.
3. **Grammar-operator subtraction**:

```haskell
grammarOperators :: Text -> [Text]  -- first token of each indented line under "Operators used in the grammar:"
```

   `parseErrorNames` subtracts any token whose `nameKeys` intersect the
   grammar list — an already-imported operator stops appearing "missing"
   (directly serves `accepts`; the existing `parseAppMsg` fixture shows the
   rendering).
4. **Ordering**: in `parseErrorNames` only, replace `dedup = nub . sort`
   (which alphabetizes) with stable first-appearance `nub`, then a stable
   partition symbolic-first. `notInScopeNames` keeps its `dedup`.
5. **Cap in `classify`, not in `parseErrorNames`**:
   `parses = map DParse (take 6 names)`. `parseErrorNames` itself stays
   **uncapped** — `accepts` uses it as the membership oracle, and a capped
   oracle could silently drop the target and fake `targetResolved`.
6. Factor a pure `stillMissingNames :: Text -> [Text]` helper
   (`notInScopeNames ∪ parseErrorNames` after grammar subtraction) into
   Diagnostic so both `accepts` and the test suite consume the exact same
   predicate.

### Strategy + driver bounding (each candidate costs a full throwaway-agda validate, ~seconds)

- `candidatesFor` DParse: skip when `name ∈ inScopeNames src` (alphabetic dump
  tokens are often the file's own defs). Env-miss tokens already cost zero
  validates (empty `importCandidates` → no candidates) — that's what makes
  alphabetic inclusion affordable.
- `firstWorking`: per-round cap `flat = take 16 [...]` — worst case 16
  validates/round instead of 6 names × 6 imports = 36; symbolic-first ordering
  means the cap bites on the speculative alphabetic tail. `max_iter`
  (default 8) bounds the total as before.

### `accepts` and monotone termination (Tools.hs:1500)

Risk: after importing `just`, a residual `NoParseForLHS` on `nothing` may
re-dump the whole LHS still containing `just` → strict membership keeps
failing → loop stalls. Decision gate on the round-2 fixtures:

- If the round-2 dump no longer contains the resolved name (or grammar
  subtraction removes it — provably true for the operator case): leave
  `accepts` unchanged.
- Else, weaken `targetResolved` **for `DParse` targets only**: resolved iff
  strict membership passes OR the `stillMissingNames` set changed.
  Termination stays sound: every accepted DParse candidate is import-only,
  `insertImport` of a present line is a no-op (`applyEdits` → `Nothing`), so
  each accepted round adds a **new distinct** import line — text strictly
  grows in a finite universe, `max_iter` caps regardless, and the error-count
  guard (`<=`) still rejects regressions. Document beside `accepts` and in
  FixLoop.md invariant 3. (Reserve alternative: leave `accepts` unchanged and
  accept that multi-constructor parse errors need two `repair` invocations.)

### Tests

`parseErrorNames`: keeps `,` from a spaced dump; includes `just`/`nothing`
from the NoParseForLHS fixture; excludes 1-char names, keywords, stopwords;
symbolic-first ordering; `classify` caps at 6. `grammarOperators` reads
`parseAppMsg` (`×` listed); subtraction removes an in-scope operator from the
round-2 fixture. `stillMissingNames` pinned on the round-2 fixture (exactly
what `accepts` consumes). **Deliberate churn:** the existing exclusion pin at
Spec.hs:898-900 (`AllPairs`/`result` excluded) flips under alphabetic
inclusion — rewrite it to assert they are extracted *after* symbolic tokens
and bounded by the classify cap + Env-hit filtering; comment why.

---

## Sequencing (one commit each)

| # | Commit | Scope | Gate check |
|---|--------|-------|-----------|
| C1 | R21 guard region-awareness | Guard.hs, Literate.hs, Tools.hs call sites, Spec | `cabal test` |
| C2 | R22 content stamps | Registry.hs, GoalId.hs, Tools.hs, Spec | `cabal test` + convergence.py full loop |
| C3 | R23 wall budgets | Session.hs, Tools.hs, Spec | `cabal test` + live wedge scenario + agda-goals `-N1`/`-NK` byte-identity |
| C4 | R25a rename removal | Strategy.hs, Edit.hs, Tools.hs, Spec, FixLoop.md, CLAUDE.md | `cabal test` |
| C5 | R24+R25b alias/carrier resolvers | Strategy.hs, LemmaRank.hs, Tools.hs, cabal, Spec | `cabal test` (strategyTests now in suite) |
| C6 | R26 parse-level recovery | Diagnostic.hs, Strategy.hs, Tools.hs, Spec (+ manual fixture capture first) | `cabal test` + live repro of both W4 variants |

Order rationale: C1/C2/C3 are the bridge cluster (C2 before C3 — both touch
`runAutoAll`). C4 before C5 shrinks the surface the Env refactor reshapes
(`graphNearMatches` never needs porting to `EnvEntry`). C6 last — its
bounding leans on C5's Env-hit filtering and needs the fixture capture. R21's
`guardScrub` borrows `renameInBody`'s scanner idiom, so C1 lands before C4
deletes it.

## Verification (end-to-end)

1. `cabal build && cabal test` after every commit (offline suite; CI-safe).
2. Live, after C2/C3/C6: `test/interaction/convergence.py` full loop + the
   new scenarios (stale-disk refusal; wedge budget; literate give_file with
   pragma-quoting prose; repair of the two W4 parse variants against copies of
   `../MCPBenchArena/fixtures/live/src/PairClient.agda`).
3. `agda-goals` determinism after C3: byte-identical output `-N1` vs `-NK`
   (human + `--format=json`) — the CLAUDE.md acceptance test for touching
   Session.hs.
4. Arena re-verification (in `../MCPBenchArena`): re-run
   `runners/followup_gates.py` and the W-family gates — W1/W8 (R21 accept
   controls + literate premise), W7 (R22 wrong-write rate, R23
   session-wedge/recovery), W4 (R24 re-export write sub-case, R25
   import-storm + scaffold one-shot-green, R26 operator-parse).
5. Doc pass lands with the relevant commits: CLAUDE.md gotchas (guard region
   awareness; content-stamp invariant incl. the read-before/after bracket; the
   two timeout semantics — inactivity vs wall; repair is import-only),
   FixLoop.md (invariants 1 and 3, alias bullet in "graph as scope oracle",
   re-measured results table), tool descriptions (`load`, `repair`,
   `new_module`, `auto`, `check`).
