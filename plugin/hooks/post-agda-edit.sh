#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): close the edit→check loop for Agda files.
#
# Phase 2 (preferred): if the agda-explore daemon serves its control
# endpoint (--control-port; discovered via <project>/.agda-explore/
# control-port), run a REAL warm `check` of the edited file and inject the
# verdict + diagnostics + open goals as context.
#
# Phase 1 (fallback): no endpoint (or busy/timeout) → inject a one-line
# nudge to validate via the bridge's `check` tool, rate-limited per
# session+file so a multi-file refactor isn't spammed.
#
# Never blocks the edit (PostToolUse can't) and never fails loudly: any
# problem here degrades to silence.
set -u

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
case "$file" in
  *.agda|*.lagda|*.lagda.md|*.lagda.rst|*.lagda.tex|*.lagda.org) ;;
  *) exit 0 ;;
esac

cwd=$(jq -r '.cwd // empty' <<<"$input")
sid=$(jq -r '.session_id // "nosession"' <<<"$input")

# Phase 2: a live control endpoint wins — real diagnostics, every time.
port_file="$cwd/.agda-explore/control-port"
if [[ -r "$port_file" ]]; then
  port=$(cat "$port_file")
  if result=$(curl -sf --max-time 90 --get \
                "http://127.0.0.1:$port/check" \
                --data-urlencode "file=$file" 2>/dev/null); then
    jq -n --arg ctx "$result" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'
    exit 0
  fi
  # busy / timed out / stale port file → fall through to the nudge
fi

# Phase 1: nudge, at most once per session+file per 2 minutes.
sentinel="${TMPDIR:-/tmp}/agda-explore-check-nudge-$sid-$(printf '%s' "$file" | cksum | cut -d' ' -f1)"
if [[ -e "$sentinel" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$sentinel" 2>/dev/null || echo 0) ))
  [[ $age -lt 120 ]] && exit 0
fi
touch "$sentinel" 2>/dev/null

jq -n --arg f "$file" '{hookSpecificOutput:{hookEventName:"PostToolUse",
  additionalContext:("You edited \($f) as text. Validate it now with the agda-explore bridge before further edits: `check file=\($f)` (warm session; returns ✓/✗ plus every error, warning, and open goal — and any goals Mimer can already solve). Do not run `agda` directly — the bridge session is already warm. If goals remain, `auto_all` tries Mimer on all of them in one call.")}}'
exit 0
