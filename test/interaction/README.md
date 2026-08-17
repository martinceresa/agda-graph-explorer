# `agda --interaction-json` protocol fixtures

Golden transcripts of the `agda --interaction-json` wire protocol, captured
from a real `agda` against the tiny fixture modules in [`src/`](src/). They are
the spec the `AgdaGraph.Interaction.Protocol` parser is written against and the
regression tripwire when Agda bumps — `--interaction-json` is **not** officially
version-stable.

The committed fixtures under `2.8.0/` were captured from **Agda 2.8.0**. The
offline suite replays them without an `agda` binary; regenerating is a manual,
agda-required step — run `bash regen.sh` (needs `agda` on `$PATH`).

`regen.sh` writes into `$(agda --version)/`, so a different local Agda lands its
output in a *new* directory rather than overwriting these. Exactly one version
is committed at a time, and it must be the one
`.github/workflows/ci-live.yml` pins: that job regenerates and fails on any
diff, so a second version directory reads as protocol drift. Bumping means
regenerating, repointing `fixtureDir` in `test/Spec.hs`, deleting the old
directory, and moving the workflow's pin — in one commit.

Fixtures are **path-normalized**: `IOTCM` requires an absolute file argument and
agda echoes it back inside error messages and highlighting notes, so `regen.sh`
rewrites the fixture root back out of everything it captures. Committed
transcripts therefore say `src/Holes.agda`, not `/home/<you>/…/src/Holes.agda`,
and regenerate identically on any checkout.

## Protocol facts pinned by these fixtures

- **Prompt framing.** Each command's reply burst is terminated by a `JSON> `
  readiness prompt printed *without* a trailing newline. The prompt is glued to
  the first reply of the *next* burst on the same physical line
  (`JSON> {…}`). `AgdaInteract.Session` treats the prompt as a burst delimiter
  (more version-stable than any `kind`) — see `session-readonly.txt`.
- **Interaction id.** Lives at `constraintObj.id` on each `visibleGoals` entry
  in `AllGoalsWarnings`, and at `interactionPoint.id` on `GoalSpecific` /
  `GiveAction` / `MakeCase` replies. A parallel `InteractionPoints` reply lists
  `{id,range}` pairs.
- **Positions are 1-based *character* offsets into the full file.** Verified
  against `Lit.lagda.md`: the hole is reported at `pos 379` / `line 14`, exactly
  the character index of `{!!}` *including all the preceding markdown prose*. So
  literate range-mapping is the identity for ranges; only an "is this offset
  inside a code block?" guard + clause re-indentation matter. Note `→` counts as
  one character — splicing must use `Data.Text` character indexing, not bytes.
- **Reply shapes** (see the per-command `*.jsonl`):
  - `load` → `DisplayInfo`/`AllGoalsWarnings` (+ `InteractionPoints`).
  - `goal_type_context` → `DisplayInfo`/`GoalSpecific`, `goalInfo.kind=GoalType`
    with `type` + `entries` (`{binding,reifiedName,originalName,inScope}`).
  - `infer` → `GoalSpecific`, `goalInfo.kind=InferredType` with `expr`.
  - `compute` → `GoalSpecific`, `goalInfo.kind=NormalForm` with `expr`.
  - `make_case` → `MakeCase` with `clauses` (full replacement clause lines) +
    `variant` (`Function`/`ExtendedLambda`).
  - `give` → `GiveAction`, `giveResult={"paren":Bool}` (splice the *user's*
    input, parenthesized per flag).
  - `refine_or_intro` → `GiveAction`, `giveResult={"str":"…"}` (splice this exact
    string), followed by an updated `AllGoalsWarnings` carrying any new subgoals.

## `auto` / Mimer

Agda 2.8's signature is `Cmd_autoOne Rewrite InteractionId Range String` — the
leading `Rewrite` is mandatory (omit it and Mimer "cannot read" the command).
With it, Mimer runs and replies with a `GiveAction` carrying the found term —
the `auto` MCP tool fills the hole (diff) or reports no solution.

## End-to-end convergence test (`convergence.py`)

`convergence.py` drives a *live* `agda-explore --enable-interact` daemon
through the whole editing loop — `load → give → apply the returned diff →
reload → … → 0 goals → agda typechecks the result` — against the small
fixture project in [`proj/`](proj/) (`Nat.agda`, a literate `Doc.lagda.md`,
`Proof.agda`, and `AutoOne.agda`). It works on a scratch copy, so the
committed fixtures stay pristine. Beyond the plain give-loop it also covers
`give_many` (one combined diff), `auto` (Mimer fills `AutoOne.agda`),
`case_split`, and the **`stage` → `give` → `promote` → `discard`** staging
flow. This covers the contract the offline suite can't: that diffs actually
apply, reloads pick up edits, goals converge, and the finished proof
compiles. Needs `agda` on `$PATH`; NOT run in CI.

The staging case drops an `.agda-lib` at its temp project root so the scratch
module sits *under* a project root — the condition that triggers the
`ModuleNameDoesntMatchFileName` regression `loadIncludes` fixes (a plain
tempdir doesn't surface it).

```
python3 test/interaction/convergence.py        # discovers the cabal binary
```

`proj/Proof.agda` (a case-split + a refine + plain gives) is left for an
**agent-driven** pass: point an agent at the daemon, have it close every hole
using only the bridge tools, then confirm `agda` is clean.

## IOTCM command syntax (Agda 2.8.0, confirmed working)

```
IOTCM "F" None Direct (Cmd_load "F" [])
IOTCM "F" None Direct (Cmd_goal_type_context Simplified <id> noRange "")
IOTCM "F" None Direct (Cmd_infer Simplified <id> noRange "<expr>")
IOTCM "F" None Direct (Cmd_compute DefaultCompute <id> noRange "<expr>")
IOTCM "F" None Direct (Cmd_make_case <id> noRange "<vars>")
IOTCM "F" None Direct (Cmd_give WithoutForce <id> noRange "<term>")
IOTCM "F" None Direct (Cmd_refine_or_intro False <id> noRange "<hint>")
IOTCM "F" None Direct (Cmd_autoOne AsIs <id> noRange "")
```

`Cmd_load`'s second argument is a list of bare command-line option tokens
(`["-iDIR"]`, a single token — **not** `["-i","DIR"]`).
