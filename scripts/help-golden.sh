#!/usr/bin/env bash
# Capture or check the CLI --help goldens under test/help/.
#
#   scripts/help-golden.sh regen   # rewrite the goldens (after an intended change)
#   scripts/help-golden.sh check   # diff live --help against them (CI default)
#
# A normalization pass makes the goldens stable across builds and version
# bumps: every semver-looking token becomes VERSION, and the volatile build
# fingerprint line (git rev + date + ghc, agda-explore only) is dropped. The
# SAME normalization is applied to both sides, so it need only be deterministic.
#
# This is the structural safety net for the FlagSpec migration: any change to a
# flag surface produces a reviewable golden diff. Offline (no agda / agda-deps).
set -uo pipefail

mode="${1:-check}"
dir="test/help"
mkdir -p "$dir"

norm() { sed -E 's/[0-9]+\.[0-9]+(\.[0-9]+)?/VERSION/g; /git .*built.*ghc/d'; }

fail=0
run() {
  local name="$1"; shift
  local out golden
  out="$(cabal run -v0 "$@" 2>/dev/null | norm)"
  golden="$dir/$name.txt"
  if [ "$mode" = regen ]; then
    printf '%s\n' "$out" > "$golden"
    echo "wrote $golden"
  else
    if [ ! -f "$golden" ]; then
      echo "MISSING golden: $golden (run: just help-goldens)"; fail=1; return
    fi
    if ! diff -u "$golden" <(printf '%s\n' "$out"); then
      echo "HELP GOLDEN DRIFT: $name (regen with: just help-goldens)"; fail=1
    fi
  fi
}

run agda-unused                    agda-unused -- --help
run agda-goals                     agda-goals -- --help
run agda-optimization              agda-optimization -- --help
run agda-optimization-load-bearing agda-optimization -- load-bearing --help
run agda-optimization-motif        agda-optimization -- motif --help
run agda-explore                   agda-explore -- --help
run agda-auto                      agda-auto -- --help

# tools/list catalogue goldens: the sorted advertised tool names for each tier,
# with the write bridge on. Guards against accidental catalogue drift in either
# direction (a tool added/removed, or the core set changing) — see §3.1.
runTools() {
  local name="$1" tier="$2" out golden
  out="$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}\n' \
    | cabal run -v0 agda-explore -- --tool-tier "$tier" --enable-interact --graph test/deps.json 2>/dev/null \
    | grep -oE '"name":"[a-z_]+"' | sed -E 's/.*:"([a-z_]+)"/\1/' | sort -u)"
  golden="$dir/tools-$name.txt"
  if [ "$mode" = regen ]; then
    printf '%s\n' "$out" > "$golden"; echo "wrote $golden"
  else
    if [ ! -f "$golden" ]; then echo "MISSING golden: $golden (run: just help-goldens)"; fail=1; return; fi
    if ! diff -u "$golden" <(printf '%s\n' "$out"); then
      echo "TOOLS/LIST GOLDEN DRIFT: tier=$name (regen with: just help-goldens)"; fail=1
    fi
  fi
}
runTools core core
runTools full full

if [ "$mode" != regen ] && [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "help goldens OK"
