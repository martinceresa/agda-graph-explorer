#!/usr/bin/env bash
# name: run-all-opts
# description: Build an agda-deps expanded JSON (with subterm hashes) for an entry
#   module, then run every agda-optimization heuristic into an output dir
#   (one <name>.txt + <name>.json per subcommand). Continues past a failing
#   heuristic so one bad analysis never aborts the batch.
# metadata: type: project
#
# Usage:
#   run_all_opts.sh <agda-src-dir> <entry.(l)agda(.md)> <out-dir> [extra agda-deps flags...]
# Example:
#   run_all_opts.sh \
#     Project/agda-src \
#     Project/main.agda \
#     Project/Opts 
#
# NOTE: paths MUST be absolute — agda-deps emits absolute moduleFiles and
# agda-optimization keys off them. `set -e` is deliberately OFF: a single
# heuristic that errors (e.g. an unsupported flag) must not kill the run.

set -uo pipefail

AGDA_SRC="$(readlink -f "${1:?usage: run_all_opts.sh <agda-src> <entry> <out-dir>}")"
ENTRY="$(readlink -f "${2:?missing <entry>}")"
OUT_RAW="${3:?missing <out-dir>}"
shift 3 || true
mkdir -p "$OUT_RAW"
OUT="$(readlink -f "$OUT_RAW")"

# ghc-9.14.1 builds: agda-deps from AgdaDependencies, agda-optimization from
# agda-graph-explorer. Both support the term-hash producer/consumer contract.
DEPS="${AGDA_DEPS_BIN:-$(which agda-deps)}"
OPT="${AGDA_OPT_BIN:-$(which agda-optimization)}"

[ -x "$DEPS" ] || { echo "agda-deps not found/executable: $DEPS" >&2; exit 2; }
[ -x "$OPT"  ] || { echo "agda-optimization not found/executable: $OPT" >&2; exit 2; }

DEPS_JSON="$OUT/deps.json"

echo ">> agda-deps → $DEPS_JSON  (expanded, term-hashes, min-term-depth=3, no-externals)"
( cd "$AGDA_SRC" && "$DEPS" --format=json --json-mode=expanded \
    --with-term-hashes --min-term-depth=3 --no-externals \
    "$@" -o "$OUT" "$ENTRY" ) || { echo "agda-deps FAILED" >&2; exit 3; }
[ -f "$DEPS_JSON" ] || { echo "expected $DEPS_JSON, not produced" >&2; exit 3; }
echo "   deps.json: $(du -h "$DEPS_JSON" | cut -f1)"

# run <subcommand> [subcommand flags...] — writes <name>.txt + <name>.json,
# logs stderr to <name>.err, never aborts the batch.
run() {
  local name="$1"; shift
  printf '>> %-14s' "$name"
  if "$OPT" "$name" "$DEPS_JSON" "$@" --out "$OUT/$name.txt" 2> "$OUT/$name.err"; then
    "$OPT" "$name" "$DEPS_JSON" "$@" --json --out "$OUT/$name.json" 2>> "$OUT/$name.err" || true
    echo "ok ($(wc -l < "$OUT/$name.txt" | tr -d ' ') lines)"
    [ -s "$OUT/$name.err" ] || rm -f "$OUT/$name.err"
  else
    echo "FAILED — see $name.err"
  fi
}

# Duplication / abstraction candidates (primary signal for refactoring).
run fingerprint    --top-n=40
run term-cluster   --span-modules=3 --min-diversity=0.7 --top-n=40
run concept-bundle --min-span=3 --k-max=2 --top-n=40
run motif          --top-n=40
run echo           --top-n=40
run basket         --top-n=40
run entwine        --top-n=40
run silhouette     --top-n=40
# Importance / where-to-focus.
run load-bearing   --top-n=40
run polyglot       --top-n=40
run gravity        --top-n=40
run chokepoint     --top-n=40
run pyre           --top-n=40
# Module structure.
run strata
run fiedler
run horizon
# Axiom hygiene (expected ~empty: 0 postulates).
run debt
run ledger

echo ">> done. reports in $OUT/"
ls -1 "$OUT"/*.txt 2>/dev/null
