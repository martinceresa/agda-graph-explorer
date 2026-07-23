#!/usr/bin/env bash
# Live end-to-end smoke test for `agda-auto` (Phase A).
#
# Requires `agda` on $PATH. CI does NOT run this — the offline Spec.hs suite
# covers the pure CLI/config layer; this exercises the real ladder against a
# live agda session and so is a manual/local check. Run from anywhere:
#
#   bash test/auto/smoke.sh
#
# Asserts, on a throwaway copy of the single-hole AutoOne fixture:
#   1. a dry run prints a give diff and leaves the file byte-identical;
#   2. --write applies the give and the result typechecks under a fresh agda;
#   3. a graph-less run (no deps.json) still fills the hole (plain Mimer).
# NB: no `set -e` — agda-auto intentionally exits 1 (holes remain) / 2 (error),
# and a command substitution capturing that would trip errexit before our own
# assertions run. Explicit `fail` checks below are the guard instead.
set -uo pipefail
cd "$(dirname "$0")/../.."          # repo root

command -v agda >/dev/null || { echo "smoke: agda not on \$PATH; skipping." >&2; exit 0; }

BIN=$(cabal list-bin agda-auto 2>/dev/null) || { echo "smoke: build agda-auto first (cabal build agda-auto)." >&2; exit 1; }
FIXTURE="test/interaction/proj/AutoOne.agda"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# 1. dry run: per-hole table + give diff on stdout, file untouched, exit 0.
cp "$FIXTURE" "$WORK/AutoOne.agda"
OUT=$("$BIN" --project "$WORK" "$WORK/AutoOne.agda"); RC=$?
echo "$OUT" | grep -q '1 filled'   || fail "dry run report did not show 1 filled"
echo "$OUT" | grep -q '^+f x = '    || fail "dry run did not print a give diff"
[ "$RC" -eq 0 ]                     || fail "all-filled dry run should exit 0 (got $RC)"
diff -q "$WORK/AutoOne.agda" "$FIXTURE" >/dev/null || fail "dry run modified the file"

# 2. --write applies + the written file typechecks in a fresh agda.
"$BIN" --project "$WORK" --write "$WORK/AutoOne.agda" >/dev/null
grep -q '{!!}' "$WORK/AutoOne.agda" && fail "--write left the hole unfilled"
agda --no-libraries -i "$WORK" "$WORK/AutoOne.agda" >/dev/null 2>&1 \
  || fail "agda rejected the written file"

# 3. graph-less run (fresh dir, no deps.json anywhere above it) still fills.
GDIR="$WORK/nograph"; mkdir -p "$GDIR"
cp "$FIXTURE" "$GDIR/AutoOne.agda"
"$BIN" --project "$GDIR" "$GDIR/AutoOne.agda" 2>/dev/null | grep -q '1 filled' \
  || fail "graph-less plain-Mimer run did not fill the hole"

# 4. --json is well-formed and reports the fill; exit 0 (dry, graph-less).
cp "$FIXTURE" "$GDIR/AutoOne.agda"
J=$("$BIN" --project "$GDIR" --json "$GDIR/AutoOne.agda" 2>/dev/null); RC=$?
echo "$J" | grep -q '"solved":1'  || fail "--json did not report solved:1"
echo "$J" | grep -q '"status":"solved"' || fail "--json hole status not solved"
[ "$RC" -eq 0 ]                   || fail "--json all-filled run should exit 0 (got $RC)"
command -v python3 >/dev/null && \
  { echo "$J" | python3 -c 'import json,sys; json.load(sys.stdin)' \
      || fail "--json output is not valid JSON"; }

# 5. an unsolvable hole: exit 1, reported UNSOLVED, file untouched (dry).
cat > "$GDIR/Stuck.agda" <<'EOF'
module Stuck where
open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
lemma : (n : Nat) → n + 0 ≡ n
lemma n = {!!}
EOF
OUT=$("$BIN" --project "$GDIR" "$GDIR/Stuck.agda" 2>/dev/null); RC=$?
echo "$OUT" | grep -q 'UNSOLVED'  || fail "unsolvable hole not reported UNSOLVED"
[ "$RC" -eq 1 ]                   || fail "unsolved holes should exit 1 (got $RC)"

# 6. Phase C: --write annotates the stuck hole, the file still loads in agda,
#    and a second --write is a zero diff (idempotent, no timestamps).
"$BIN" --project "$GDIR" --write "$GDIR/Stuck.agda" >/dev/null 2>&1
grep -q 'agda-auto/1' "$GDIR/Stuck.agda" || fail "stuck hole was not annotated"
# Agda still parses it — only UnsolvedInteractionMetas, no parse/scope error.
AG=$(agda --no-libraries -i "$GDIR" "$GDIR/Stuck.agda" 2>&1)
echo "$AG" | grep -qiE 'unsolved interaction' || fail "annotated file lost its hole"
echo "$AG" | grep -qiE 'parse|not in scope|Unexpected' && fail "annotated file broke agda parsing"
cp "$GDIR/Stuck.agda" "$GDIR/Stuck.before"
"$BIN" --project "$GDIR" --write "$GDIR/Stuck.agda" >/dev/null 2>&1
diff -q "$GDIR/Stuck.before" "$GDIR/Stuck.agda" >/dev/null \
  || fail "second annotate run was not idempotent (marker stacked or drifted)"

# 7. --no-annotate leaves the stuck hole bare.
cp "$FIXTURE" "$GDIR/Bare.agda" 2>/dev/null || true
cat > "$GDIR/Bare.agda" <<'EOF'
module Bare where
open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
lemma : (n : Nat) → n + 0 ≡ n
lemma n = {!!}
EOF
"$BIN" --project "$GDIR" --no-annotate --write "$GDIR/Bare.agda" >/dev/null 2>&1
grep -q 'agda-auto' "$GDIR/Bare.agda" && fail "--no-annotate still wrote a marker"
grep -q '{!!}' "$GDIR/Bare.agda"      || fail "--no-annotate should leave the bare hole"

# 8. Phase D read side: a hole naming the needed in-scope lemma is solved via
#    that hint (graph-less), tagged "(from hole)".
cat > "$GDIR/Hole.agda" <<'EOF'
module Hole where
open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
bar : (n : Nat) → n + 0 ≡ n
bar zero = refl
bar (suc n) rewrite bar n = refl
foo : (n : Nat) → n + 0 ≡ n
foo n = {! bar !}
EOF
OUT=$("$BIN" --project "$GDIR" "$GDIR/Hole.agda" 2>/dev/null); RC=$?
echo "$OUT" | grep -q '(from hole)' || fail "hole-hint solve not tagged (from hole)"
echo "$OUT" | grep -q '^+foo n = bar n' || fail "hole-hint did not produce the give"
[ "$RC" -eq 0 ]                    || fail "hole-hint solved run should exit 0 (got $RC)"

# 9. Phase E project mode: a directory of two modules (B imports A). A module
#    with an open hole cannot be imported, so filling A first (dependency order)
#    is what lets B load — the sweep + --write must close both.
PDIR="$WORK/proj"; mkdir -p "$PDIR"
cat > "$PDIR/A.agda" <<'EOF'
module A where
open import Agda.Builtin.Nat
lemA : Nat → Nat
lemA x = {!!}
EOF
cat > "$PDIR/B.agda" <<'EOF'
module B where
open import Agda.Builtin.Nat
open import A
useB : Nat → Nat
useB n = {! lemA n !}
EOF
OUT=$("$BIN" --project "$PDIR" --write "$PDIR" 2>/dev/null); RC=$?
echo "$OUT" | grep -q 'files 2, holes 2, filled 2' || fail "project sweep totals wrong: $OUT"
[ "$RC" -eq 0 ]                        || fail "project sweep --write should exit 0 (got $RC)"
grep -q '{!!}' "$PDIR/A.agda" "$PDIR/B.agda" && fail "project sweep left a hole unfilled"
agda --no-libraries -i "$PDIR" "$PDIR/B.agda" >/dev/null 2>&1 || fail "swept project does not typecheck"

# 10. --json project mode: a {files:[...], summary:{...}} envelope, valid JSON.
cat > "$PDIR/A.agda" <<'EOF'
module A where
open import Agda.Builtin.Nat
lemA : Nat → Nat
lemA x = {!!}
EOF
J=$("$BIN" --project "$PDIR" --json "$PDIR/A.agda" "$PDIR/B.agda" 2>/dev/null)
command -v python3 >/dev/null && {
  echo "$J" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert isinstance(d.get("files"),list) and len(d["files"])==2, "files array"
assert d["summary"]["files"]==2, "summary.files"
' || fail "--json project envelope malformed"; }

# 11. Determinism: two identical dry sweeps are byte-identical (human + json).
D1=$("$BIN" --project "$PDIR" "$PDIR" 2>/dev/null)
D2=$("$BIN" --project "$PDIR" "$PDIR" 2>/dev/null)
[ "$D1" = "$D2" ]                      || fail "human sweep is not deterministic"
J1=$("$BIN" --project "$PDIR" --json "$PDIR" 2>/dev/null)
J2=$("$BIN" --project "$PDIR" --json "$PDIR" 2>/dev/null)
[ "$J1" = "$J2" ]                      || fail "json sweep is not deterministic"

# 12. Phase F --ledger: one JSON line per goal, valid JSON.
cp "$FIXTURE" "$GDIR/Led.agda" 2>/dev/null
cat > "$GDIR/Led.agda" <<'EOF'
module Led where
open import Agda.Builtin.Nat
open import Agda.Builtin.Equality
easy : Nat → Nat
easy x = {!!}
hard : (n : Nat) → n + 0 ≡ n
hard n = {!!}
EOF
LED="$GDIR/led.jsonl"; rm -f "$LED"
"$BIN" --project "$GDIR" --ledger "$LED" "$GDIR/Led.agda" >/dev/null 2>&1
[ "$(wc -l < "$LED")" -eq 2 ] || fail "ledger should have one line per goal (got $(wc -l < "$LED"))"
command -v python3 >/dev/null && {
  while IFS= read -r ln; do echo "$ln" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    || fail "ledger line is not valid JSON"; done < "$LED"; }

# 13. Phase F --fixpoint --write: converges (fills both), exit 0.
FP="$GDIR/fp"; mkdir -p "$FP"
cat > "$FP/A.agda" <<'EOF'
module A where
open import Agda.Builtin.Nat
lemA : Nat → Nat
lemA x = {!!}
EOF
cat > "$FP/B.agda" <<'EOF'
module B where
open import Agda.Builtin.Nat
open import A
useB : Nat → Nat
useB n = {! lemA n !}
EOF
"$BIN" --project "$FP" --write --fixpoint "$FP" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ]                        || fail "--fixpoint sweep should exit 0 (got $RC)"
grep -q '{!!}' "$FP/A.agda" "$FP/B.agda" && fail "--fixpoint left a hole unfilled"

# 14. Phase F --repair: a missing import (graph knows its module) is added, then
#     the file loads. Uses a hand-written minimal graph + a real Lib module.
RP="$GDIR/rp"; mkdir -p "$RP"
cat > "$RP/Lib.agda" <<'EOF'
module Lib where
open import Agda.Builtin.Nat
myConst : Nat
myConst = 5
EOF
cat > "$RP/Use.agda" <<'EOF'
module Use where
open import Agda.Builtin.Nat
foo : Nat
foo = myConst
EOF
cat > "$RP/deps.json" <<'EOF'
{ "v":2, "mode":"expanded", "schemaVersion":2, "nodeKeyVersion":3
, "modules":["Lib","Use"], "moduleFiles":{}
, "definitions":[{"name":"Lib.myConst","module":"Lib","kind":"function"}]
, "definitionEdges":[] }
EOF
"$BIN" --graph "$RP/deps.json" --project "$RP" --repair --write "$RP/Use.agda" >/dev/null 2>&1
grep -q 'open import Lib' "$RP/Use.agda" || fail "--repair did not add the missing import"
agda --no-libraries -i "$RP" "$RP/Use.agda" >/dev/null 2>&1 || fail "repaired file does not typecheck"

echo "agda-auto smoke: all checks passed"
