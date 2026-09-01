#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): close the edit→check loop for Agda files.
#
# Phase 2 (preferred): if the agda-explore daemon serves its control
# endpoint (--control-port; discovered via <project>/.agda-explore/
# control-port), run a REAL warm `check` of the edited file and inject the
# verdict + diagnostics + open goals as context. On a ✗ it appends a
# diff-only `repair` suggestion; on a ✓ it appends any unused-ARGUMENT
# findings, which a clean check cannot report (Agda has no warning for an
# argument a definition never uses).
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
    ctx="$result"
    # On a failing check, ask `repair` for a diff-only suggestion and append it
    # if it produced one. `repair` decides what is mechanical — it refuses
    # semantic errors — so classification lives in the tool, not in this hook.
    # The graph can usually fix imports/typos without spending a model turn.
    # Never writes (diff-only).
    if grep -q '✗' <<<"$result"; then
      if rep=$(curl -sf --max-time 90 --get \
                 "http://127.0.0.1:$port/repair" \
                 --data-urlencode "file=$file" 2>/dev/null) \
           && grep -q 'Applied fixes' <<<"$rep"; then
        ctx="$result

── suggested repair (diff-only; NOT applied — review and apply, or call \`repair file=$file write:true\`) ──
$rep"
      fi
    else
      # A ✓ file can still carry arguments nothing uses: that verdict comes
      # from the GRAPH (the producer's argUsage, Agda's own occurrence and
      # polarity analysis), never from a type-check, so `check` alone can
      # never surface it. /unused runs `unused scope=<file> kinds=args`.
      #
      # `# total: 0 finding(s)` is agda-unused's own zero line — skip the
      # whole section then, so a clean edit stays silent. A 500 (file not in
      # the graph yet, no agda-unused binary) fails `curl -sf` and is also
      # silent. The graph may still predate this edit; the tool's own
      # freshness footer says so when it does, and the next edit's hook
      # catches what the background rebuild has since landed.
      #
      # 20s, not the 90s the bridge routes get: this is an agda-unused
      # subprocess over an already-loaded graph (sub-second in practice), and
      # it has to fit inside what `check` leaves of the hook's own 120s
      # timeout. A cold daemon whose first query blocks on a full build hits
      # the cap and degrades to silence, which is the right trade for a
      # report-only section.
      if un=$(curl -sf --max-time 20 --get \
                "http://127.0.0.1:$port/unused" \
                --data-urlencode "file=$file" 2>/dev/null) \
           && ! grep -q '^# total: 0 finding' <<<"$un"; then
        ctx="$result

── unused arguments in $file (agda-unused kinds=args; NOT applied) ──
$un"
      fi
    fi
    jq -n --arg ctx "$ctx" \
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
  additionalContext:("You edited \($f) as text. Validate it now with the agda-explore bridge before further edits: `check file=\($f)` (warm session; returns ✓/✗ plus every error, warning, and open goal — and any goals Mimer can already solve). Do not run `agda` directly — the bridge session is already warm. If goals remain, `construct steps=[{op:auto, goal:\"*\"}]` tries Mimer on all of them in one call.")}}'
exit 0
