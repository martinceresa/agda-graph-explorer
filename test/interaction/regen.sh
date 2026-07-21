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
clean() { grep -vE 'ClearRunningInfo|ClearHighlighting|RunningInfo|"kind":"Status"' | sed 's/^JSON> //' | grep '^{'; }
load() { printf 'IOTCM "%s" None Direct (Cmd_load "%s" [])\n' "$1" "$1"; }

{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_goal_type_context Simplified 0 noRange "")\n' "$F"; printf 'IOTCM "%s" None Direct (Cmd_infer Simplified 3 noRange "zero")\n' "$F"; printf 'IOTCM "%s" None Direct (Cmd_compute DefaultCompute 0 noRange "1 + 1")\n' "$F"; } | agda --interaction-json 2>/dev/null > "$OUT/session-readonly.txt"

load "$F" | agda --interaction-json 2>/dev/null | clean > "$OUT/load.jsonl"
load "$L" | agda --interaction-json 2>/dev/null | clean > "$OUT/load-literate.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_make_case 0 noRange "n")\n' "$F"; }                 | agda --interaction-json 2>/dev/null | clean | grep MakeCase    > "$OUT/make-case.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_give WithoutForce 0 noRange "n")\n' "$F"; }         | agda --interaction-json 2>/dev/null | clean | grep GiveAction  > "$OUT/give.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_refine_or_intro False 0 noRange "suc")\n' "$F"; }   | agda --interaction-json 2>/dev/null | clean | grep GiveAction  > "$OUT/refine.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_goal_type_context Simplified 0 noRange "")\n' "$F"; }| agda --interaction-json 2>/dev/null | clean | grep GoalSpecific > "$OUT/goal-type-context.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_infer Simplified 3 noRange "zero")\n' "$F"; }       | agda --interaction-json 2>/dev/null | clean | grep InferredType > "$OUT/infer.jsonl"
{ load "$F"; printf 'IOTCM "%s" None Direct (Cmd_compute DefaultCompute 0 noRange "1 + 1")\n' "$F"; }| agda --interaction-json 2>/dev/null | clean | grep NormalForm   > "$OUT/compute.jsonl"
# Phase-3a multi-hint batch: a goal solvable ONLY by combining two in-scope
# hints (trans' eq1 eq2). Confirms Cmd_autoOne accepts a batch of in-scope
# hints and returns the combined term — the tripwire for a batch-semantics
# change in a future agda. (Single quote kept out of printf via a sed swap.)
{ load "$C"; printf 'IOTCM "%s" None Direct (Cmd_autoOne AsIs 0 noRange "-t 5 transQ eq1 eq2")\n' "$C"; } \
  | sed "s/transQ/trans'/" | agda --interaction-json 2>/dev/null | clean | grep GiveAction > "$OUT/auto-batch.jsonl"
echo "regenerated fixtures under $OUT/"
