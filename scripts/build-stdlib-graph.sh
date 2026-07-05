#!/usr/bin/env bash
# Build a reusable "overlay" dependency graph (typically agda-stdlib) that the
# agda-explore daemon federates into every project snapshot via
# --overlay-graph. Because a library's graph rarely changes, build it ONCE and
# point --overlay-graph / overlay-graphs: at the result; the daemon unions it
# into the project graph so `search` / `type_of` / `find_lemma` answer "does
# the library already have this?" — the most common proving question.
#
# The overlay must be built with the SAME node-key convention this binary
# expects (agda-explore skips an overlay whose nodeKeyVersion differs), and
# with --with-signatures so type_of / find_lemma have types to match. This
# script uses the flags that satisfy both.
#
# Usage:
#   scripts/build-stdlib-graph.sh --seed FILE   [-i DIR ...] [-o OUTDIR]
#   scripts/build-stdlib-graph.sh --everything FILE [-i DIR ...] [-o OUTDIR]
#
#   --seed FILE        An Agda module that `open import`s the surface you want
#                      in the overlay (e.g. a curated list of common modules,
#                      for a smaller graph than full Everything).
#   --everything FILE  The library's generated Everything.agda (full coverage).
#   -i DIR             Include dir for the library sources (repeatable). Point
#                      at the library's `src` so agda finds it.
#   -o OUTDIR          Output directory (default: a version-keyed cache dir
#                      under ${XDG_CACHE_HOME:-~/.cache}/agda-explore/).
#
# On success it prints the path to register, e.g.:
#   --overlay-graph /home/you/.cache/agda-explore/stdlib-2.9.0-<hash>/deps.json
set -euo pipefail

AGDA_DEPS_BIN="${AGDA_DEPS_BIN:-agda-deps}"
seed=""; everything=""; out=""; includes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed)       seed="$2"; shift 2 ;;
    --everything) everything="$2"; shift 2 ;;
    -i)           includes+=("$2"); shift 2 ;;
    -o)           out="$2"; shift 2 ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

entry="${seed:-$everything}"
if [[ -z "$entry" ]]; then
  echo "error: pass --seed FILE or --everything FILE (see --help)" >&2
  exit 2
fi
if [[ ! -f "$entry" ]]; then
  echo "error: entry file not found: $entry" >&2
  exit 2
fi
if ! command -v "$AGDA_DEPS_BIN" >/dev/null 2>&1; then
  echo "error: agda-deps not found (set AGDA_DEPS_BIN or put it on PATH)" >&2
  exit 2
fi

# Version-key the cache dir so a library / agda bump lands in a fresh path and
# a stale overlay is never silently reused.
if [[ -z "$out" ]]; then
  agda_ver="$(agda --version 2>/dev/null | head -1 | awk '{print $NF}' || echo unknown)"
  # A cheap content key over the include dirs + entry, so distinct libraries
  # (or a changed seed) don't collide.
  key="$( { printf '%s\0' "$entry" "${includes[@]:-}"; } | cksum | awk '{print $1}')"
  out="${XDG_CACHE_HOME:-$HOME/.cache}/agda-explore/stdlib-${agda_ver}-${key}"
fi
mkdir -p "$out"

inc_args=()
for d in "${includes[@]:-}"; do [[ -n "$d" ]] && inc_args+=(-i "$d"); done

echo "building overlay graph from $entry → $out/deps.json" >&2
# NOTE: no --no-externals — the entry IS the library, so its modules are the
# graph we want; --with-signatures + --with-term-hashes match the daemon's
# defaults so type_of / find_lemma / similar_* all work against the overlay.
"$AGDA_DEPS_BIN" \
  --format=json --json-mode=expanded \
  --with-signatures --with-term-hashes \
  "${inc_args[@]}" "$entry" -o "$out"

if [[ ! -f "$out/deps.json" ]]; then
  echo "error: agda-deps did not produce $out/deps.json" >&2
  exit 1
fi

echo >&2
echo "done. Register it with agda-explore:" >&2
echo "  --overlay-graph $out/deps.json" >&2
echo "or in .agda-explore.yml:" >&2
echo "  overlay-graphs:" >&2
echo "    - $out/deps.json" >&2
# Also emit the bare path on stdout so callers can capture it.
echo "$out/deps.json"
