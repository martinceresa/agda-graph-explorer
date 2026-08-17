#!/usr/bin/env bash
# Regenerate the golden --interaction-json fixtures from a real agda.
# Requires `agda` on $PATH. CI does NOT run this; it only replays the
# committed output offline. Re-run after an Agda version bump and review
# the diff — a change here is a protocol-skew signal.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(agda --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
OUT="$VER"
mkdir -p "$OUT"
F="$PWD/src/Holes.agda"
L="$PWD/src/Lit.lagda.md"
C="$PWD/src/Combine.agda"
HH="$PWD/src/HoleHint.agda"
# IOTCM needs an ABSOLUTE path, and agda echoes it back inside error messages,
# JumpToError payloads and highlighting notes. Committed fixtures must not carry
# the generating machine's paths — CI's drift check compares them verbatim, so a
# baked-in /home/<dev>/… fails on every checkout for a reason that is not drift.
# Rewrite the fixture root back out of everything captured.
ROOT_RE=$(printf '%s' "$PWD/" | sed 's/[][\.*^$&#]/\\&/g')
normpaths() { sed "s#$ROOT_RE##g"; }
clean() { grep -vE 'ClearRunningInfo|ClearHighlighting|RunningInfo|"kind":"Status"' | sed 's/^JSON> //' | grep '^{' | normpaths; }
load() { printf 'IOTCM "%s" None Direct (Cmd_load "%s" [])\n' "$1" "$1"; }

{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_goal_type_context Simplified 0 noRange "")\n' "$F"; printf 'IOTCM "%s" None Direct (Cmd_infer Simplified 3 noRange "zero")\n' "$F"; printf 'IOTCM "%s" None Direct (Cmd_compute DefaultCompute 0 noRange "1 + 1")\n' "$F"; } | agda --interaction-json 2>/dev/null | normpaths > "$OUT/session-readonly.txt"

load "$F" | agda --interaction-json 2>/dev/null | clean > "$OUT/load.jsonl"
load "$L" | agda --interaction-json 2>/dev/null | clean > "$OUT/load-literate.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_make_case 0 noRange "n")\n' "$F"; }                 | agda --interaction-json 2>/dev/null | clean | grep MakeCase    > "$OUT/make-case.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_give WithoutForce 0 noRange "n")\n' "$F"; }         | agda --interaction-json 2>/dev/null | clean | grep GiveAction  > "$OUT/give.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_refine_or_intro False 0 noRange "suc")\n' "$F"; }   | agda --interaction-json 2>/dev/null | clean | grep GiveAction  > "$OUT/refine.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_goal_type_context Simplified 0 noRange "")\n' "$F"; }| agda --interaction-json 2>/dev/null | clean | grep GoalSpecific > "$OUT/goal-type-context.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_infer Simplified 3 noRange "zero")\n' "$F"; }       | agda --interaction-json 2>/dev/null | clean | grep InferredType > "$OUT/infer.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_compute DefaultCompute 0 noRange "1 + 1")\n' "$F"; }| agda --interaction-json 2>/dev/null | clean | grep NormalForm   > "$OUT/compute.jsonl"
# A REJECTED give (`Set` into a `Nat` hole): the type error arrives as a
# DisplayInfo/Error reply, not as a failed command — pins that the bridge reads
# the localized message out of the wire rather than dumping the JSON.
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_give WithoutForce 0 noRange "Set")\n' "$F"; }       | agda --interaction-json 2>/dev/null | clean | grep '"kind":"Error"' > "$OUT/give-error.jsonl"
# Phase-3a multi-hint batch: a goal solvable ONLY by combining two in-scope
# hints (trans' eq1 eq2). Confirms Cmd_autoOne accepts a batch of in-scope
# hints and returns the combined term — the tripwire for a batch-semantics
# change in a future agda. (Single quote kept out of printf via a sed swap.)
{ load "$C"; printf 'IOTCM "%s" None Direct (Cmd_autoOne AsIs 0 noRange "-t 5 transQ eq1 eq2")\n' "$C"; } \
  | sed "s/transQ/trans'/" | agda --interaction-json 2>/dev/null | clean | grep GiveAction > "$OUT/auto-batch.jsonl"
# Phase-D: plain Cmd_autoOne on a hole whose body names an in-scope lemma
# (`{! bar !}`). Mimer does NOT read hole contents as a hint on this agda, so
# the stream carries NO GiveAction and the goal stays open — the tripwire for a
# future agda that starts consuming hole bodies (which would add a GiveAction).
{ load "$HH"; printf 'IOTCM "%s" None Direct (Cmd_autoOne AsIs 0 noRange "-t 5")\n' "$HH"; } \
  | agda --interaction-json 2>/dev/null | clean > "$OUT/auto-hole-content.jsonl"

# The unsolved-meta trio (load + Cmd_constraints each). These pin where the
# wire reports un-produced evidence, which is NOT the errors/warnings lists:
#   unsolved-meta   a missing record field — zero errors, zero warnings, zero
#                   visible goals, the meta in `invisibleGoals`. The false-✓
#                   repro; batch agda rejects this file.
#   stuck-instance  two candidate instances — an [UnsolvedConstraints] error
#                   AND a structured Cmd_constraints entry with the candidates.
#   hole-blocked    an ORDINARY `?` hole also yields an invisible meta, so the
#                   ✗ rule cannot be "any invisible meta"; this one stays ✓.
constraints() { printf 'IOTCM "%s" None Direct (Cmd_constraints)\n' "$1"; }
for probe in Unsolved:unsolved-meta Stuck:stuck-instance HoleBlocked:hole-blocked; do
  f="$PWD/src/${probe%%:*}.agda"
  { load "$f"; constraints "$f"; } \
    | agda --interaction-json 2>/dev/null | clean > "$OUT/${probe##*:}.jsonl"
done
echo "regenerated fixtures under $OUT/"
