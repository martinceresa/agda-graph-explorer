#!/usr/bin/env bash
# Launcher for the agda-explore MCP server, used by the Claude Code plugin.
#
# Locates the `agda-explore` binary, then execs it as a stdio MCP server
# rooted at the current Claude project. The server discovers the Agda
# entry module and include paths from that project; override via the
# AGDA_EXPLORE_* env vars (see `agda-explore --help`).
#
# Binary selection collects every candidate — a pinned AGDA_EXPLORE_BIN,
# a `$PATH` entry, and any agda-explore under a nearby `dist-newstyle`
# tree — and launches the one with the *newest* mtime. A pinned path that
# a GHC bump has left stale (Errors.3 E3.1: the canonical dist-newstyle
# artifact moved, but AGDA_EXPLORE_BIN kept resolving the old `ghc-9.6.7`
# tree) is therefore overridden by the fresher build automatically, with
# a one-line stderr note so the misconfiguration stays visible
# (Features.3 F3.2).
set -euo pipefail

find_bin () {
  local candidates=() pinned=""
  # 1. explicit pin via env var.
  if [ -n "${AGDA_EXPLORE_BIN:-}" ] && [ -x "${AGDA_EXPLORE_BIN}" ]; then
    candidates+=("${AGDA_EXPLORE_BIN}")
    pinned="${AGDA_EXPLORE_BIN}"
  fi
  # 2. on $PATH.
  local onpath
  onpath=$(command -v agda-explore 2>/dev/null || true)
  [ -n "$onpath" ] && candidates+=("$onpath")
  # 3. agda-explore under a project/ancestor/plugin dist-newstyle tree.
  # Roots: the Claude project dir and the plugin's own ancestors (where a
  # dist-newstyle build tree lives during development). The bare $PWD is
  # dropped (CLAUDE_PROJECT_DIR defaults to it), and we never scan from
  # the filesystem root — that would be a whole-FS `find` if the script is
  # ever relocated near `/`. -maxdepth bounds the dist-newstyle nesting
  # (the binary sits ~10 levels under the project root).
  local script_dir hit root rootabs
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  for root in "${CLAUDE_PROJECT_DIR:-$PWD}" "$script_dir/.." "$script_dir/../.."; do
    [ -d "$root" ] || continue
    rootabs=$(cd "$root" 2>/dev/null && pwd -P)
    case "$rootabs" in ""|/) continue;; esac
    while IFS= read -r hit; do
      [ -n "$hit" ] && [ -x "$hit" ] && candidates+=("$hit")
    done < <(find "$root" -maxdepth 12 -type f \
               -path '*x/agda-explore/build/agda-explore/agda-explore' 2>/dev/null || true)
  done

  [ ${#candidates[@]} -eq 0 ] && return 1

  # Newest mtime wins. `ls -t` sorts by mtime on both GNU and BSD ls.
  local newest
  newest=$(ls -t "${candidates[@]}" 2>/dev/null | head -n1 || true)
  [ -z "$newest" ] && newest="${candidates[0]}"

  if [ -n "$pinned" ] && [ "$newest" != "$pinned" ]; then
    echo "agda-explore: NOTE: AGDA_EXPLORE_BIN ($pinned) is older than a discovered build;" >&2
    echo "  launching the newer $newest instead. Repoint or unset AGDA_EXPLORE_BIN to silence." >&2
  fi

  printf '%s' "$newest"
}

if ! BIN=$(find_bin); then
  cat >&2 <<'EOF'
agda-explore: could not find the `agda-explore` binary.

  Build it from the agda-deps project:
      cabal build agda-explore
  then either install it onto your PATH:
      cabal install agda-explore
  or point this plugin at it explicitly:
      export AGDA_EXPLORE_BIN=/abs/path/to/agda-explore

The companion `agda-deps` and `agda-unused` binaries should also be on PATH
(or set AGDA_DEPS_BIN / AGDA_UNUSED_BIN) so the server can rebuild the graph
and run the unused-import check. The server prefers the newest matching build
for those too, so a stale pin after a GHC bump self-heals.
EOF
  exit 127
fi

# Hook preflight: the two hooks parse their JSON input with `jq`, and the edit
# hook's real-check path reaches the control endpoint with `curl`. Without them
# the hooks degrade silently — so say why, once, on stderr (never fatal).
command -v jq >/dev/null 2>&1 || \
  echo "agda-explore: NOTE: 'jq' not found — the edit-validation and grep-routing hooks will be inactive. Install jq to enable them." >&2
command -v curl >/dev/null 2>&1 || \
  echo "agda-explore: NOTE: 'curl' not found — the edit hook's warm-check path is unavailable (it falls back to a text nudge). Install curl to enable it." >&2

# Plugin defaults (the launcher's opinion; still overridable):
#   --tool-tier core     — advertise only the measured-used tool subset, cutting
#                          the agent's per-choice decision-load.
#   --enable-interact
#   --control-port 7100  — the write bridge + a localhost control endpoint (port
#                          probed upward on clash) so the PostToolUse edit hook
#                          runs a REAL warm `check` instead of just a nudge.
# Opt out of the bridge (e.g. no `agda`, or a constrained machine) with
# AGDA_EXPLORE_NO_INTERACT=1. Anything in .mcp.json `args` ("$@") comes after
# these and wins (flags are last-wins), so a project can restore --tool-tier full.
plugin_args=(--tool-tier core)
if [ -z "${AGDA_EXPLORE_NO_INTERACT:-}" ]; then
  plugin_args+=(--enable-interact --control-port 7100)
fi

exec "$BIN" --project "${CLAUDE_PROJECT_DIR:-$PWD}" "${plugin_args[@]}" "$@"
