#!/usr/bin/env bash
# PreToolUse hook (Grep): once per session, route a structural grep over
# Agda sources to the agda-explore dependency graph instead — grep misses
# with-abstractions and instance references, and re-reads every file the
# elaborated graph already indexes.
#
# Deny exactly ONCE per session (a sentinel keeps later greps silent): text
# searches over prose/comments are legitimate, so the second attempt sails
# through. This is one well-timed lesson, not a wall.
set -u

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

sid=$(jq -r '.session_id // "nosession"' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
filter=$(jq -r '[.tool_input.glob // empty, .tool_input.path // empty,
                 .tool_input.type // empty] | join(" ")' <<<"$input")

# Fire when the grep explicitly targets Agda sources, or when this is an
# agda-explore project and no non-Agda filter narrows the search away.
agda_project=false
if [[ -n "$cwd" ]]; then
  if [[ -f "$cwd/.agda-explore.yml" || -f "$cwd/.agda-explore.yaml" ]] \
     || compgen -G "$cwd/*.agda-lib" >/dev/null 2>&1; then
    agda_project=true
  fi
fi
case "$filter" in
  *agda*) ;;                                    # explicitly Agda-targeted
  *.hs*|*.rs*|*.md*|*.py*|*.json*|*.yml*|*.yaml*) exit 0 ;;  # explicitly not Agda
  *) $agda_project || exit 0 ;;
esac

# Once per session: deny with the tool mapping; afterwards stay silent.
sentinel="${TMPDIR:-/tmp}/agda-explore-grep-route-$sid"
[[ -e "$sentinel" ]] && exit 0
touch "$sentinel" 2>/dev/null

jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",
  permissionDecision:"deny",
  permissionDecisionReason:"This project serves an elaborated Agda dependency graph via the agda-explore MCP; structural questions are better answered there (grep misses with-abstractions and instance references, and re-reads every file): definition site -> locate; name substring or list by kind/state -> search; who uses X -> callers; what X uses -> callees; type -> type_of; lemma matching a goal -> find_lemma. If you genuinely need a TEXT search (prose, comments, error strings), re-run the same grep now - it will be allowed."}}'
exit 0
