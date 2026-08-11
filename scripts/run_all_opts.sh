#!/usr/bin/env bash
# name: run-all-opts
# description: Run EVERY agda-optimization subcommand over one expanded
#   graph.json in a single go, writing <name>.txt + <name>.json per subcommand
#   into an out-dir. The script passes no analysis flags of its own, so each
#   subcommand takes its defaults from ./.agda-optimization.yml (if present)
#   and the built-in defaults otherwise. Optionally builds the graph first
#   with agda-deps.
# metadata: type: project
#
# Run it FROM THE REPO TOP LEVEL. Two reasons: agda-optimization discovers
# ./.agda-optimization.yml relative to the CURRENT directory (so the script
# never cd's for an analysis run), and the `cabal run` fallback below needs the
# project root. The subcommand list is read from the binary's own --help, so it
# cannot drift from the tool.
#
# Usage:
#   scripts/run_all_opts.sh                                # test/deps.json → opt-report/
#   scripts/run_all_opts.sh <graph.json> [out-dir]
#   scripts/run_all_opts.sh <agda-src-dir> <entry.(l)agda(.md)> [out-dir] [agda-deps flags...]
#
# Examples:
#   scripts/run_all_opts.sh                                # the committed fixture
#   scripts/run_all_opts.sh .agda-explore/deps.json /tmp/opts
#   scripts/run_all_opts.sh ~/proj/agda-src ~/proj/Main.agda ~/proj/Opts
#
# Binaries: agda-optimization from $AGDA_OPT_BIN > $PATH > `cabal run`.
# Build mode additionally needs agda-deps ($AGDA_DEPS_BIN > $PATH).
#
# Exit codes: 0 every analysis ok · 1 some analysis failed (batch still ran to
# the end) · 2 usage / missing binary / missing graph · 3 the agda-deps build
# failed.
#
# NOTE: in build mode the paths MUST be absolute — agda-deps emits absolute
# moduleFiles and agda-optimization keys off them — so the script absolutizes
# them for you. `set -e` is deliberately OFF: a single heuristic that errors
# (e.g. fiedler without SciPy) must not kill the batch.

set -uo pipefail

DEFAULT_GRAPH="test/deps.json"
DEFAULT_OUT="opt-report"

# The Usage/Examples block of the header above, verbatim (single source).
usage() {
  echo "run_all_opts.sh — run every agda-optimization subcommand in one go."
  awk '/^# Usage:/ { f = 1 } /^# Binaries:/ { exit } f { sub(/^# ?/, ""); print }' "$0"
}

# --- binaries ---------------------------------------------------------------
if [ -n "${AGDA_OPT_BIN:-}" ]; then
  [ -x "$AGDA_OPT_BIN" ] || { echo "\$AGDA_OPT_BIN not executable: $AGDA_OPT_BIN" >&2; exit 2; }
  OPT=("$AGDA_OPT_BIN")
elif command -v agda-optimization >/dev/null 2>&1; then
  OPT=("agda-optimization")
elif command -v cabal >/dev/null 2>&1 && [ -f agda-graph-explorer.cabal ]; then
  OPT=(cabal run -v0 agda-optimization --)
else
  echo "agda-optimization not found: put it on \$PATH, set \$AGDA_OPT_BIN," >&2
  echo "or run this from the repo top level (the 'cabal run' fallback)." >&2
  exit 2
fi

# --- arguments --------------------------------------------------------------
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

GRAPH=""; AGDA_SRC=""; ENTRY=""
if [ $# -eq 0 ]; then
  GRAPH="$DEFAULT_GRAPH"; OUT_RAW="$DEFAULT_OUT"
elif [ -d "$1" ]; then                       # build mode: <src-dir> <entry> …
  AGDA_SRC="$(readlink -f "$1")"
  [ $# -ge 2 ] || { echo "missing <entry.(l)agda(.md)> after $1" >&2; usage >&2; exit 2; }
  ENTRY="$(readlink -f "$2")"
  [ -f "$ENTRY" ] || { echo "no such entry module: $2" >&2; exit 2; }
  shift 2
  # An out-dir if the next token isn't a flag; the rest goes to agda-deps.
  if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then OUT_RAW="$1"; shift
  else OUT_RAW="$DEFAULT_OUT"; fi
elif [ -f "$1" ]; then                       # graph mode: <graph.json> [out-dir]
  GRAPH="$1"; OUT_RAW="${2:-$DEFAULT_OUT}"
  [ $# -le 2 ] || { echo "graph mode takes at most <graph.json> [out-dir]; got: $*" >&2; exit 2; }
else
  echo "no such file or directory: $1" >&2; usage >&2; exit 2
fi

mkdir -p "$OUT_RAW" || exit 2
OUT="$(readlink -f "$OUT_RAW")"

# --- graph ------------------------------------------------------------------
if [ -n "$AGDA_SRC" ]; then
  DEPS="${AGDA_DEPS_BIN:-$(command -v agda-deps 2>/dev/null)}"
  [ -n "$DEPS" ] && [ -x "$DEPS" ] || {
    echo "agda-deps not found/executable: ${DEPS:-<unset>}" >&2
    echo "(build mode only — pass an existing graph.json to skip it)" >&2
    exit 2; }
  GRAPH="$OUT/deps.json"
  echo ">> agda-deps → $GRAPH  (expanded, term-hashes, min-term-depth=3, no-externals)"
  ( cd "$AGDA_SRC" && "$DEPS" --format=json --json-mode=expanded \
      --with-term-hashes --min-term-depth=3 --no-externals \
      "$@" -o "$OUT" "$ENTRY" ) || { echo "agda-deps FAILED" >&2; exit 3; }
  [ -f "$GRAPH" ] || { echo "expected $GRAPH, not produced" >&2; exit 3; }
fi
[ -f "$GRAPH" ] || { echo "graph not found: $GRAPH" >&2; exit 2; }
echo ">> graph:  $GRAPH ($(du -h "$GRAPH" | cut -f1))"

# --- config -----------------------------------------------------------------
# Purely a breadcrumb — the script never passes --config, so the tool does the
# real discovery ($AGDA_OPTIMIZATION_CONFIG > ./.agda-optimization.y{a,}ml >
# nearest *.agda-lib ancestor). Only those first two steps are checked here;
# the ancestor walk is the tool's business, so when this finds nothing the
# per-subcommand "applied config from …" stderr line is kept (see 'run').
CFG=""
if [ -n "${AGDA_OPTIMIZATION_CONFIG:-}" ]; then
  CFG="$AGDA_OPTIMIZATION_CONFIG (\$AGDA_OPTIMIZATION_CONFIG)"
else
  for c in .agda-optimization.yml .agda-optimization.yaml; do
    [ -f "$c" ] && { CFG="$PWD/$c"; break; }
  done
fi
if [ -n "$CFG" ]; then
  echo ">> config: $CFG"
else
  echo ">> config: none in $PWD — analyses run on built-in defaults"
  echo "           (start one with: agda-optimization --show-defaults > .agda-optimization.yml)"
fi

# --- subcommands ------------------------------------------------------------
# Read from the binary, so a new analysis is picked up without touching this
# script. Pinned by test/help/ goldens, hence safe to parse.
SUBS=()
while IFS= read -r s; do [ -n "$s" ] && SUBS+=("$s"); done < <(
  "${OPT[@]}" --help 2>/dev/null |
    awk '/^SUBCOMMANDS:/ { f = 1; next } f && NF == 0 { exit } f { print $1 }'
)
[ "${#SUBS[@]}" -ge 10 ] || {
  echo "could not read the subcommand list from --help (${#SUBS[@]} found)" >&2
  exit 2; }
echo ">> running ${#SUBS[@]} subcommands into $OUT/"

# run <subcommand> — writes <name>.txt + <name>.json, keeps stderr notes in
# <name>.err, never aborts the batch. No analysis flags: defaults + YAML only.
FAILED=()
run() {
  local name="$1" t0=$SECONDS rc=0 note=""
  printf '>> %-16s' "$name"
  "${OPT[@]}" "$name" "$GRAPH" --format=human --out "$OUT/$name.txt" 2> "$OUT/$name.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
    [ -s "$OUT/$name.txt" ] || rm -f "$OUT/$name.txt"   # no misleading empty report
    printf 'FAILED (exit %s) — see %s\n' "$rc" "$name.err"
    return
  fi
  # Same analysis again, structured. Its stderr just repeats the human pass's
  # breadcrumbs, so keep it only when this pass actually fails.
  "${OPT[@]}" "$name" "$GRAPH" --format=json --out "$OUT/$name.json" 2> "$OUT/$name.json.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name(json)")
    note=", json FAILED"
    { echo "--- --format=json pass failed (exit $rc):"; cat "$OUT/$name.json.err"; } \
      >> "$OUT/$name.err"
  fi
  rm -f "$OUT/$name.json.err"
  # The "applied config from …" breadcrumb fires on every human run. Strip it
  # only when the header already named that config, so it must not make every
  # .err look noteworthy — but a config the header could not see (found by the
  # tool's *.agda-lib ancestor walk) stays visible rather than silent.
  if [ -n "$CFG" ]; then
    grep -v 'applied config from' "$OUT/$name.err" > "$OUT/$name.err.tmp"
    mv -f "$OUT/$name.err.tmp" "$OUT/$name.err"
  fi
  if [ -s "$OUT/$name.err" ]; then note="$note, notes → $name.err"
  else rm -f "$OUT/$name.err"; fi
  printf 'ok (%s lines, %ss%s)\n' \
    "$(wc -l < "$OUT/$name.txt" | tr -d ' ')" "$((SECONDS - t0))" "$note"
}

for sub in "${SUBS[@]}"; do run "$sub"; done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo ">> done: ${#SUBS[@]}/${#SUBS[@]} ok — reports in $OUT/"
  exit 0
fi
echo ">> done: $(( ${#SUBS[@]} - ${#FAILED[@]} ))/${#SUBS[@]} ok, ${#FAILED[@]} failed: ${FAILED[*]}"
echo "   reports in $OUT/ — each failure's diagnostic is in <name>.err"
echo "   (fiedler exits 2 without scripts/fiedler_helper.py, 3 without SciPy)"
exit 1
