#!/usr/bin/env bash
# Offline acceptance for scripts/zero-config.py.
#
#   bash scripts/zero-config-smoke.sh      # (also: just zero-config-smoke)
#
# Builds a throwaway Agda project in a temp dir (two toy modules + an
# *.agda-lib), drops the committed expanded-JSON fixture in as the shared
# graph, and asserts:
#
#   1. all five tool configs are written, and every graph consumer resolves to
#      the SAME graph  (the whole point of zero-config);
#   2. a second run is byte-identical — every file reports "current";
#   3. `agda-optimization` then runs with NO graph path, off `global: graph:`;
#   4. repointing one config's graph by hand is detected and exits 1.
#
# Uses the freshly built binaries via `cabal list-bin`, so it tests what the
# tree currently produces. Needs NO `agda` / `agda-deps`: those show up as
# warnings (zero-config never builds a graph), which is itself asserted by (1)
# passing on a machine without them.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"                       # `cabal list-bin` needs the project root
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"; mkdir -p "$bin"
for t in agda-unused agda-optimization agda-explore agda-auto agda-goals; do
  ln -sf "$(cabal list-bin "$t")" "$bin/$t"
done

proj="$tmp/proj"; mkdir -p "$proj/src" "$proj/.agda-deps"
printf 'name: smoke\ninclude: src\n'                        > "$proj/smoke.agda-lib"
printf 'module Main where\n\nopen import Nat\n'             > "$proj/src/Main.agda"
printf 'module Nat where\n\ndata Nat : Set where\n  zero : Nat\n' > "$proj/src/Nat.agda"
cp "$repo/test/deps.json" "$proj/.agda-deps/deps.json"

zc() { python3 "$repo/scripts/zero-config.py" --project "$proj" --bin-dir "$bin" "$@"; }

zc --json > "$tmp/first.json"
zc --json > "$tmp/second.json"

python3 - "$tmp/first.json" "$tmp/second.json" <<'PY'
import json, sys

first, second = (json.load(open(p)) for p in sys.argv[1:3])

def status(report, name):
    for c in report["checks"]:
        if c["check"] == name:
            return c["status"]
    return None

assert first["ok"], "first run reported a failing check: %s" % [
    c for c in first["checks"] if c["status"] == "fail"]
assert first["graph"] == ".agda-deps/deps.json", first["graph"]
assert first["entries"] == ["src/Main.agda"], first["entries"]

wrote = {f["tool"]: f["action"] for f in first["files"]}
for tool in ("agda-unused", "agda-optimization", "agda-explore", "agda-auto",
             "agda-goals"):
    assert wrote.get(tool) == "written", (tool, wrote.get(tool))

assert status(first, "graph") == "ok", first["checks"]
assert status(first, "graph agreement") == "ok", first["checks"]

# Idempotence: same inputs, nothing rewritten.
again = {f["tool"]: f["action"] for f in second["files"]}
for tool, action in again.items():
    assert action in ("current", "missing binary"), (tool, action)
assert second["ok"]
print("zero-config: write + agreement + idempotence OK")
PY

# The payoff: a subcommand with no graph path, taking it from the config.
( cd "$proj" && "$bin/agda-optimization" motif >/dev/null )
echo "zero-config: agda-optimization ran with no graph path OK"

# A config repointed by hand breaks the shared-graph invariant: ✗ + exit 1.
sed -i 's|^graph: .agda-deps/deps.json|graph: elsewhere/deps.json|' "$proj/.agda-auto.yml"
if zc > "$tmp/mismatch.out" 2>&1; then
  echo "zero-config: expected exit 1 on a graph disagreement"; cat "$tmp/mismatch.out"; exit 1
fi
grep -q "graph agreement" "$tmp/mismatch.out" \
  || { echo "zero-config: disagreement not reported"; cat "$tmp/mismatch.out"; exit 1; }
echo "zero-config: graph disagreement detected (exit 1) OK"

zc --force >/dev/null
echo "zero-config smoke OK"
