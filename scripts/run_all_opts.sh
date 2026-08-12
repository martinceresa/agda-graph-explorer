#!/usr/bin/env bash
# name: run-all-opts
# description: Run EVERY agda-optimization subcommand over one expanded
#   graph.json in a single go, writing <name>.txt + <name>.json per subcommand
#   into an out-dir (plus <name>.log for what the run had to say, and
#   <name>.err only when it actually failed). The script passes no analysis
#   flags of its own, so each subcommand takes its defaults from
#   ./.agda-optimization.yml (if present) and the built-in defaults otherwise.
#   Optionally builds the graph first with agda-deps.
# metadata: type: project
#
# Run it FROM THE REPO TOP LEVEL. Two reasons: agda-optimization discovers
# ./.agda-optimization.yml relative to the CURRENT directory (so the script
# never cd's for an analysis run), and the `cabal run` fallback below needs the
# project root. The subcommand list is read from the binary's own --help, so it
# cannot drift from the tool.
#
# Usage:
#   scripts/run_all_opts.sh [-N<j>]
#   scripts/run_all_opts.sh [-N<j>] <graph.json> [out-dir]
#   scripts/run_all_opts.sh [-N<j>] <agda-src-dir> <entry.(l)agda(.md)> [out-dir] [agda-deps flags...]
#
# Options — LEADING position only, before the positional arguments (build mode
# hands every trailing flag to agda-deps, so a trailing -N would be ambiguous):
#   -N<j>, -N <j>   run each analysis on j capabilities (+RTS -N<j> -RTS) instead
#                   of the binary's built-in -N = every core. Analyses only; the
#                   agda-deps build in build mode is left alone. Needs the binary
#                   built with -rtsopts, as agda-graph-explorer.cabal does.
#
# Examples:
#   scripts/run_all_opts.sh                                # the committed fixture
#   scripts/run_all_opts.sh .agda-explore/deps.json /tmp/opts
#   scripts/run_all_opts.sh -N1 .agda-explore/deps.json /tmp/opts
#   scripts/run_all_opts.sh -N4 ~/proj/agda-src ~/proj/Main.agda ~/proj/Opts
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
#
# WHY -N<j>: the analyses are this batch's only parallel work, and two RTS-level
# faults ride on it for a big graph. On GHC 9.12.4 a heap-corruption bug (exit
# 139, or an abort printing "evacuate: strange closure type") needs >= 2
# capabilities — GHC 9.14.1 fixes it. A rarer livelock (one thread spinning at
# 100%, the rest idle) survives that fix. Neither is reachable at -N1, which is
# therefore the deterministic fallback, at roughly 5x the wall clock.

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
# Leading options are peeled off first; the loop stops at the first token that
# is not one of ours, so the positional scanner below and build mode's
# agda-deps passthrough both see exactly what they saw before.
#
# RTS is the argv tail appended to every analysis run — empty by default, so a
# binary built without -rtsopts keeps working as long as -N is not asked for.
# It is expanded as ${RTS[@]+"${RTS[@]}"}: under `set -u`, bash before 4.4
# treats "${RTS[@]}" on an empty array as an unbound variable.
RTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -N)  [ $# -ge 2 ] || { echo "-N requires a capability count, e.g. -N4" >&2; exit 2; }
         RTS_N="$2"; shift 2 ;;
    -N*) RTS_N="${1#-N}"; shift ;;
    --)  shift; break ;;
    *)   break ;;
  esac
  case "$RTS_N" in
    ''|*[!0-9]*) echo "-N takes a positive integer (got: '$RTS_N')" >&2; exit 2 ;;
  esac
  [ "$RTS_N" -ge 1 ] || { echo "-N must be >= 1 (got: $RTS_N)" >&2; exit 2; }
  RTS=(+RTS "-N$RTS_N" -RTS)
done

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
# Only when asked for, so the default run's output is unchanged.
[ "${#RTS[@]}" -gt 0 ] && echo ">> rts:    ${RTS[*]} — every analysis"

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

# --- stderr routing ---------------------------------------------------------
# The tool talks on stderr for BOTH progress ("[motif] seeds=1024/9819, …") and
# diagnostics, and the two cannot be told apart by shape — fiedler prints its
# missing-SciPy diagnostic under the same "[fiedler] " prefix it uses for its
# progress line. So the run's OUTCOME does the routing, never the text:
#
#   <name>.log  every stderr line the run produced — notes, warnings, sizing
#               stats, progress. Its presence means "this analysis had
#               something to say", NEVER "something went wrong".
#   <name>.err  written only when the run actually failed: a script-authored
#               failure record (exit code, signal name, reproduce line) plus
#               the tool's own last words. Its presence always means a real
#               failure.
#
# A tool that exits on purpose prints its diagnostic and then exits, so the tail
# of the log IS that diagnostic and the record quotes it. A tool killed by a
# signal prints nothing, so there is none to find — and the record says exactly
# that, rather than leaving a reader to mistake the last progress line for a
# cause (which is what a truncated "[motif] seeds=2944/9819" looks like).
FAILED=()
FAIL_SUMMARY=""   # one-line cause for the console
FAIL_DIAG=""      # the tool's own words; empty when it died by a signal

# record_failure <name> <exit-code> human|json <log-to-quote> — write
# <name>.err, set FAIL_*. The log to quote is the failing pass's OWN stderr, so
# a json-pass failure is not reported with the human pass's breadcrumbs.
# 128+n is read as death by signal n; agda-optimization only ever exits 1/2/3
# on purpose, so that reading is unambiguous here.
record_failure() {
  local name="$1" rc="$2" pass="$3" src="$4" sig="" ext="txt" rts=""
  [ "$pass" = json ] && ext="json"
  # The reproduce line has to carry -N<j> too, or it does not reproduce.
  [ "${#RTS[@]}" -gt 0 ] && rts=" ${RTS[*]}"
  FAIL_DIAG=""
  [ "$rc" -ge 128 ] && sig="$(kill -l "$((rc - 128))" 2>/dev/null)"
  if [ -n "$sig" ]; then
    FAIL_SUMMARY="exit $rc, killed by SIG$sig — crashed, no diagnostic"
  else
    FAIL_SUMMARY="exit $rc"
    FAIL_DIAG="$(grep -v '^[[:space:]]*$' "$src" 2>/dev/null | tail -n 5)"
  fi
  {
    printf '%s FAILED — %s\n' "$name" "$FAIL_SUMMARY"
    printf 'pass:      --format=%s\n' "$pass"
    printf 'reproduce: %s %s %s --format=%s --out %s%s\n' \
      "${OPT[*]}" "$name" "$GRAPH" "$pass" "$OUT/$name.$ext" "$rts"
    if [ -s "$OUT/$name.log" ]; then
      printf 'progress:  %s.log — full stderr, up to the point it stopped\n' "$name"
    else
      printf 'progress:  none — the run printed nothing before it stopped\n'
    fi
    if [ -n "$sig" ]; then
      printf 'hint:      a signal death is the runtime, not the analysis reporting\n'
      printf '           a problem. Re-run the batch with -N1 to rule out the\n'
      printf '           parallel RTS; check dmesg for an OOM kill.\n'
    fi
    [ -n "$FAIL_DIAG" ] &&
      printf -- '--- last words (tail of %s.log) ---\n%s\n' "$name" "$FAIL_DIAG"
  } >> "$OUT/$name.err"
}

# Echo the tool's own diagnostic under the status line, indented so it reads as
# quoted output rather than as this script speaking.
show_diag() {
  [ -n "$FAIL_DIAG" ] && printf '%s\n' "$FAIL_DIAG" | sed 's/^/     | /'
  return 0
}

# tidy_log <logfile> — the "applied config from …" breadcrumb fires on every
# run. Drop it only when the header already named that config, so it does not
# make every log look noteworthy — but a config the header could not see (found
# by the tool's *.agda-lib ancestor walk) stays visible rather than silent.
# Removes the file when nothing is left, so "a .log exists" means "it spoke".
tidy_log() {
  local f="$1"
  if [ -n "$CFG" ] && [ -f "$f" ]; then
    grep -v 'applied config from' "$f" > "$f.tmp"
    mv -f "$f.tmp" "$f"
  fi
  [ -s "$f" ] || rm -f "$f"
}

# run <subcommand> — writes <name>.txt + <name>.json + the .log/.err above,
# never aborts the batch. No analysis flags: defaults + YAML only.
run() {
  local name="$1" t0=$SECONDS rc=0 note=""
  printf '>> %-16s' "$name"
  # Clean slate: anything left in the out-dir afterwards was produced by THIS
  # run, so a stale artifact from an earlier run can never lie about it.
  rm -f "$OUT/$name.txt" "$OUT/$name.json" "$OUT/$name.log" "$OUT/$name.err"

  # The analysis runs inside a subshell so that a SIGSEGV/SIGKILL death is
  # announced by THAT shell ("Segmentation fault (core dumped)") into /dev/null,
  # instead of being spliced into this script's own status line. The trailing
  # `exit` is load-bearing: without it the analysis is the subshell's last
  # command, bash execs it in place, and the outer shell reaps the signal after
  # all. The subshell's status is the analysis's, so nothing else changes.
  ( "${OPT[@]}" "$name" "$GRAPH" --format=human --out "$OUT/$name.txt" \
      ${RTS[@]+"${RTS[@]}"} 2> "$OUT/$name.log"; exit $? ) 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name")
    [ -s "$OUT/$name.txt" ] || rm -f "$OUT/$name.txt"   # no misleading empty report
    tidy_log "$OUT/$name.log"
    record_failure "$name" "$rc" human "$OUT/$name.log"
    printf 'FAILED (%s) — see %s\n' "$FAIL_SUMMARY" "$name.err"
    show_diag
    return
  fi

  # Same analysis again, structured. Its stderr just repeats the human pass's
  # breadcrumbs, so it is folded into the log only when this pass fails.
  ( "${OPT[@]}" "$name" "$GRAPH" --format=json --out "$OUT/$name.json" \
      ${RTS[@]+"${RTS[@]}"} 2> "$OUT/$name.json.log"; exit $? ) 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED+=("$name(json)")
    tidy_log "$OUT/$name.json.log"
    record_failure "$name" "$rc" json "$OUT/$name.json.log"
    [ -f "$OUT/$name.json.log" ] && cat "$OUT/$name.json.log" >> "$OUT/$name.log"
    note=", json FAILED → $name.err"
  fi
  rm -f "$OUT/$name.json.log"
  tidy_log "$OUT/$name.log"
  [ -s "$OUT/$name.log" ] && note="$note, has notes → $name.log"
  printf 'ok (%s lines, %ss%s)\n' \
    "$(wc -l < "$OUT/$name.txt" | tr -d ' ')" "$((SECONDS - t0))" "$note"
  [ "$rc" -eq 0 ] || show_diag
  return 0
}

for sub in "${SUBS[@]}"; do run "$sub"; done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo ">> done: ${#SUBS[@]}/${#SUBS[@]} ok — reports in $OUT/"
  exit 0
fi
echo ">> done: $(( ${#SUBS[@]} - ${#FAILED[@]} ))/${#SUBS[@]} ok, ${#FAILED[@]} failed: ${FAILED[*]}"
echo "   reports in $OUT/ — <name>.err is a failure record (cause + reproduce"
echo "   line); <name>.log is only what a run had to say, never a failure."
echo "   (fiedler never fails: with no scripts/fiedler_helper.py or no SciPy it"
echo "    writes an empty report and says why in fiedler.log)"
exit 1
