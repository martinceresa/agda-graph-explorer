# `agda --interaction-json` protocol fixtures

Golden transcripts of the `agda --interaction-json` wire protocol, captured
from a real `agda` against the tiny fixture modules in [`src/`](src/). They are
the spec the `AgdaGraph.Interaction.Protocol` parser is written against and the
regression tripwire when Agda bumps — `--interaction-json` is **not** officially
version-stable.

The committed fixtures under `2.9.0/` were captured from **Agda 2.9.0**
(GHC 9.6.7). CI replays them **offline** (no `agda` binary); regenerating them
is a manual, agda-required step — run `bash regen.sh` (needs `agda` on `$PATH`).

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

## Known limitation — `auto` / Mimer

In Agda 2.9.0 the IOTCM command reader rejects `Cmd_autoOne` and `Cmd_autoAll`
(`cannot read: …`) even though the constructors exist in `Agda.Interaction.Base`
and Mimer is the backend (`Resp_Mimer`). Same arg shape as `Cmd_make_case`,
which parses — so it is the constructor, not the arity. The `auto` MCP tool is
wired but degrades gracefully (returns a clear "auto unavailable on this agda"
message) until the correct invocation for this read path is pinned.

## End-to-end convergence test (`convergence.py`)

`convergence.py` drives a *live* `agda-explore --enable-interact` daemon
through the whole editing loop — `load → give → apply the returned diff →
reload → … → 0 goals → agda typechecks the result` — against the small
fixture project in [`proj/`](proj/) (`Nat.agda`, a literate `Doc.lagda.md`,
and `Proof.agda`). It works on a scratch copy, so the committed fixtures
stay pristine. This covers the contract the offline suite can't: that diffs
actually apply, reloads pick up edits, goals converge, and the finished
proof compiles. Needs `agda` on `$PATH`; NOT run in CI.

```
python3 test/interaction/convergence.py        # discovers the cabal binary
```

The richer `proj/Proof.agda` (a case-split + a refine + plain gives) is left
for an **agent-driven** pass: point an agent at the daemon and have it close
every hole using only the bridge tools, then confirm `agda` is clean — the
truest test of whether the tools are usable from their descriptions. (The
plugin loaded in a real Claude Code session against a real project is the
highest-fidelity version of that.)

## IOTCM command syntax (Agda 2.9.0, confirmed working)

```
IOTCM "F" None Direct (Cmd_load "F" [])
IOTCM "F" None Direct (Cmd_goal_type_context Simplified <id> noRange "")
IOTCM "F" None Direct (Cmd_infer Simplified <id> noRange "<expr>")
IOTCM "F" None Direct (Cmd_compute DefaultCompute <id> noRange "<expr>")
IOTCM "F" None Direct (Cmd_make_case <id> noRange "<vars>")
IOTCM "F" None Direct (Cmd_give WithoutForce <id> noRange "<term>")
IOTCM "F" None Direct (Cmd_refine_or_intro False <id> noRange "<hint>")
```

`Cmd_load`'s second argument is a list of bare command-line option tokens
(`["-iDIR"]`, a single token — **not** `["-i","DIR"]`).
