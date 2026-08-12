#!/usr/bin/env bash
# Offline acceptance for the YAML config surface shared by all five binaries.
#
#   bash scripts/config-smoke.sh          # (also: just config-smoke)
#
# Two contracts, both of which used to be broken in ways a user reads as
# "the config file is ignored":
#
#   1. `--config FILE` / `--config=FILE` is honoured in EVERY argv position.
#      agda-optimization's positional scanner reserves the token right after
#      the subcommand for the graph path and never peels it, so a `--config`
#      there was dropped — and lifting `--graph` out of argv first SHIFTED a
#      later `--config` into that slot. Both spellings are now lifted out of
#      argv before the scanner runs, which is what this pins.
#
#   2. An unknown key is REJECTED, not silently ignored — matching every CLI
#      parser's treatment of an unknown flag. Checked per tool, since each has
#      its own key vocabulary, plus agda-optimization's sections and the
#      near-miss suggestion.
#
# Uses the freshly built binaries via `cabal list-bin`. Needs no `agda`,
# `agda-deps` or network: every assertion is argv + YAML handling over the
# committed test/deps.json fixture.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"                       # `cabal list-bin` needs the project root
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

opt="$(cabal list-bin agda-optimization)"
graph="$repo/test/deps.json"
fails=0

note() { printf '%s\n' "$*" >&2; }
fail() { note "FAIL: $*"; fails=$((fails + 1)); }

# Run "$@", capture stdout/stderr/exit. Sets: out, err, code.
run() {
  set +e
  out="$("$@" 2>"$tmp/err")"; code=$?
  set -e
  err="$(cat "$tmp/err")"
}

# --------------------------------------------------------------------
# 1. `--config` is position-independent.
#
# The config sets min-support to a threshold no motif in the fixture meets,
# so "was it honoured?" is a visible property of the report rather than a
# stderr breadcrumb: honoured => the no-motifs line, ignored => a full table.
# --------------------------------------------------------------------
cat > "$tmp/m.yml" <<YAML
global:
  graph: $graph
motif:
  min-support: 500
YAML

honoured() {  # honoured <description> <argv...>
  local desc="$1"; shift
  run "$@"
  if [ "$code" -ne 0 ]; then
    fail "$desc: exit $code ($(printf '%s' "$err" | head -1))"
  elif ! printf '%s' "$out" | grep -q "no motifs found at this threshold"; then
    fail "$desc: config not applied (report ignored min-support)"
  fi
}

honoured "--config=F before the subcommand"  "$opt" "--config=$tmp/m.yml" motif "$graph"
honoured "--config F before the subcommand"  "$opt" --config "$tmp/m.yml" motif "$graph"
honoured "--config=F after the graph path"   "$opt" motif "$graph" "--config=$tmp/m.yml"
honoured "--config F after the graph path"   "$opt" motif "$graph" --config "$tmp/m.yml"
# The regression slot: immediately after the subcommand.
honoured "--config=F in the post-subcommand slot" "$opt" motif "--config=$tmp/m.yml" "$graph"
honoured "--config F in the post-subcommand slot" "$opt" motif --config "$tmp/m.yml" "$graph"
# `--graph` is lifted out of argv first, which used to shift these into it.
honoured "--config=F beside --graph"         "$opt" motif "--config=$tmp/m.yml" --graph "$graph"
honoured "--config=F written after --graph"  "$opt" motif --graph "$graph" "--config=$tmp/m.yml"
# No path anywhere on the CLI: the graph comes from the config it just loaded.
honoured "--config=F supplying the graph"    "$opt" motif "--config=$tmp/m.yml"

# A bare `--config` still names itself rather than running config-less.
run "$opt" motif "$graph" --config
[ "$code" -eq 1 ] && printf '%s' "$err" | grep -q -- "--config: missing FILE argument" \
  || fail "bare --config: expected exit 1 + a missing-FILE diagnostic, got $code / $err"

note "config: --config honoured in every argv position OK"

# --------------------------------------------------------------------
# 2. Unknown keys are rejected.
# --------------------------------------------------------------------

# rejects <description> <yaml> [expected-substring]
rejects() {
  local desc="$1" yaml="$2" want="${3:-unknown key}"
  printf '%s' "$yaml" > "$tmp/bad.yml"
  run "$opt" "--config=$tmp/bad.yml" motif "$graph"
  if [ "$code" -eq 0 ]; then
    fail "$desc: accepted silently (exit 0)"
  elif ! printf '%s' "$err" | grep -q -- "$want"; then
    fail "$desc: wrong diagnostic: $err"
  fi
}

rejects "typo'd key in a section" \
  "motif:
  min-suport: 500
" "unknown key: min-suport (did you mean min-support?)"

rejects "typo'd section name" \
  "mtif:
  min-support: 500
" "top level: unknown key: mtif (did you mean motif?)"

rejects "typo'd key in global:" \
  "global:
  grap: $graph
" "global: unknown key: grap (did you mean graph?)"

# A section other than the one being run is still checked, so a typo does not
# lie dormant until someone happens to run that analysis.
rejects "typo'd key in an unrelated section" \
  "global:
  graph: $graph
ledger:
  axiom-sorce: x
" "ledger: unknown key: axiom-sorce"

# A `--no-x` flag reads the positive key; the suggestion has to bridge that.
rejects "negated flag spelling used as a key" \
  "global:
  graph: $graph
debt:
  no-include-postulates: true
" "did you mean include-postulates?"

# ... and the real key loads.
printf 'global:\n  graph: %s\ndebt:\n  include-postulates: true\nmotif:\n  min-support: 500\n' \
  "$graph" > "$tmp/ok.yml"
run "$opt" "--config=$tmp/ok.yml" motif "$graph"
[ "$code" -eq 0 ] || fail "a fully-valid config was rejected: $err"

note "config: agda-optimization rejects unknown sections + keys OK"

# Every other tool has its own vocabulary; check each rejects a stray key and
# accepts its own `--show-defaults` skeleton (which is how zero-config.py
# writes these files, so the two can never disagree).
for t in agda-auto agda-goals agda-unused agda-explore; do
  b="$(cabal list-bin "$t")"
  # The cheapest subcommand that actually reads the config. `--version` and
  # `--help` short-circuit before the load on agda-explore, so it gets the
  # read-only environment preflight instead.
  case "$t" in
    agda-explore) probe=(doctor --json) ;;
    *)            probe=(--help)        ;;
  esac

  printf 'definitely-not-a-key: 1\n' > "$tmp/$t-bad.yml"
  run "$b" "${probe[@]}" "--config=$tmp/$t-bad.yml"
  { [ "$code" -ne 0 ] && printf '%s' "$err" | grep -q "unknown key"; } \
    || fail "$t: unknown key not rejected (exit $code)"

  # The accept half asserts the absence of the diagnostic rather than exit 0:
  # `doctor` legitimately reports a non-zero environment verdict here (no
  # graph is configured), which says nothing about the key vocabulary.
  "$b" --show-defaults > "$tmp/$t-defaults.yml"
  run "$b" "${probe[@]}" "--config=$tmp/$t-defaults.yml"
  printf '%s' "$err" | grep -q "unknown key" \
    && fail "$t: its own --show-defaults skeleton names a rejected key: $err"
done

note "config: every tool rejects a stray key and loads its own --show-defaults OK"

# --------------------------------------------------------------------
# 3. agda-explore's subcommands accept leading global flags.
#
# `doctor` / `query` used to have to be argv[0], so writing the config flag
# first — the habit every other tool encourages — died with
# `unknown argument: doctor`. The subcommand is now pulled out of argv from
# any position, stepping over flags and the values they consume.
# --------------------------------------------------------------------
exp="$(cabal list-bin agda-explore)"
printf 'graph: %s\n' "$graph" > "$tmp/x.yml"

for form in "--config=$tmp/x.yml doctor --json" \
            "--config $tmp/x.yml doctor --json" \
            "doctor --config=$tmp/x.yml --json" \
            "--graph $graph doctor --json"; do
  # shellcheck disable=SC2086
  run "$exp" $form
  [ "$code" -eq 0 ] || fail "agda-explore $form: exit $code ($(printf '%s' "$err" | head -1))"
done

# A value-LESS global flag before the subcommand, where what is under test is
# that `doctor` was still FOUND — not the verdict it then reports. Asserting
# exit 0 here would be asserting the machine has Agda: --enable-interact adds
# the `agda` probe, which legitimately fails (exit 1) on a host without it.
# So look for the report itself; a misparse exits before printing one.
run "$exp" --enable-interact --graph "$graph" doctor --json
printf '%s' "$out" | grep -q '"checks"' \
  || fail "agda-explore --enable-interact … doctor --json: no report ($(printf '%s' "$err" | head -1))"

# `query` likewise, and the answer must not depend on where the flags sit.
"$exp" query search query=eval --graph "$graph" > "$tmp/q1" 2>/dev/null || true
"$exp" --graph "$graph" query search query=eval > "$tmp/q2" 2>/dev/null || true
"$exp" query --graph "$graph" search query=eval > "$tmp/q3" 2>/dev/null || true
[ -s "$tmp/q1" ] || fail "agda-explore query: baseline produced no output"
cmp -s "$tmp/q1" "$tmp/q2" || fail "agda-explore query: leading --graph changed the answer"
cmp -s "$tmp/q1" "$tmp/q3" || fail "agda-explore query: --graph before the tool changed the answer"

# A flag VALUE that happens to spell a subcommand is not the subcommand.
# Claiming it would route to `doctor` and choke on the leftover tool name, so
# that misparse has a distinctive fingerprint.
run "$exp" --graph doctor query roots
printf '%s' "$err" | grep -q "unknown argument: roots" \
  && fail "agda-explore: --graph's value was claimed as the subcommand"

note "config: agda-explore subcommands accept leading global flags OK"

if [ "$fails" -ne 0 ]; then
  note "config smoke: $fails check(s) failed"
  exit 1
fi
note "config smoke OK"
