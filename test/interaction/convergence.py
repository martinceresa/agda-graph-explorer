#!/usr/bin/env python3
"""End-to-end convergence test for the agda-explore interaction bridge.

Unlike the offline `interaction-spec` suite (which replays golden transcripts
with no agda), this drives a *live* daemon through the FULL editing loop:

    load -> goal_type -> give -> APPLY the returned diff to the source ->
    reload -> repeat until no goals -> `agda` confirms it typechecks clean

so it exercises the contract the unit tests can't: diffs actually apply, the
reload picks up the edit, goals converge to zero, and the finished proof
compiles. Operates on a *scratch copy* of test/interaction/proj/ so the
committed fixtures stay pristine.

Requires `agda` on $PATH (or pass --agda-bin to the daemon). NOT run in CI.

Usage:
    python3 test/interaction/convergence.py [path-to-agda-explore] [graph.json]
(defaults discover the cabal-built binary and use test/deps.json.)
"""
import json, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJ = os.path.join(ROOT, "test", "interaction", "proj")

def discover_bin():
    out = subprocess.run(["cabal", "list-bin", "agda-explore"],
                         cwd=ROOT, capture_output=True, text=True)
    return out.stdout.strip()

class Daemon:
    def __init__(self, binpath, graph):
        self.p = subprocess.Popen(
            [binpath, "--enable-interact", "--graph", graph],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._id = 0
        self.call("initialize", {"protocolVersion": "2024-11-05"})

    def call(self, method, params):
        self._id += 1
        self.p.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())

    def tool(self, name, args):
        res = self.call("tools/call", {"name": name, "arguments": args})["result"]
        return res["content"][0]["text"], res.get("isError", False)

    def close(self):
        try:
            self.p.stdin.close(); self.p.wait(timeout=10)
        except Exception:
            self.p.kill()

# A goal line in `load` output: "  g0  : Nat   (10:7)"
GOAL_RE = re.compile(r'\b(g\d+)\b\s*:\s*(.+?)\s*\((\d+):\d+\)')

def goals(load_text):
    """[(stable_id, type, line)] parsed from a load/reload result."""
    return [(g, ty, int(ln)) for g, ty, ln in GOAL_RE.findall(load_text)]

HUNK_RE = re.compile(r'@@ -(\d+),(\d+) \+(\d+),(\d+) @@')

def apply_diff(path, tool_text):
    """Apply the single-hunk unified diff embedded in a mutating tool's
    result to `path` (pure Python, so it works regardless of the UTF-8
    content and absolute-path headers that confuse `patch`). Verifies the
    hunk's context+removed block matches the file before splicing."""
    i = tool_text.index('--- ')
    lines = tool_text[i:].splitlines()
    m = HUNK_RE.match(lines[2])
    if not m:
        return False
    start = int(m.group(1)) - 1                      # 1-based -> 0-based
    body = lines[3:]
    old_block = [l[1:] for l in body if l[:1] in (' ', '-')]
    new_block = [l[1:] for l in body if l[:1] in (' ', '+')]
    with open(path, encoding='utf-8') as f:
        src = f.read().split('\n')
    if src[start:start + len(old_block)] != old_block:
        return False
    src[start:start + len(old_block)] = new_block
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(src))
    return True

def agda_clean(scratch, module):
    """True iff `agda` typechecks the module (run from the scratch dir so the
    module name resolves and the builtin library is found) with no errors."""
    r = subprocess.run(["agda", module], cwd=scratch, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

FAILS = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  -- " + detail) if detail and not ok else ""))
    if not ok:
        FAILS.append(name)

def converge(d, scratch, module, recipe):
    """give-loop: close every hole using recipe {line: term}, bottom-up."""
    path = os.path.join(scratch, module)
    text, err = d.tool("load", {"file": path})
    check(f"{module}: initial load ok", not err, text)
    gs = goals(text)
    check(f"{module}: found {len(recipe)} holes", len(gs) == len(recipe), text)
    # Solve bottom-up so each edit never shifts an earlier hole's offset.
    rounds = 0
    while gs and rounds <= len(recipe) + 1:
        rounds += 1
        gid, _ty, line = max(gs, key=lambda t: t[2])  # bottom-most
        term = recipe.get(line)
        if term is None:
            check(f"{module}: recipe has a term for line {line}", False, str(gs)); break
        out, gerr = d.tool("give", {"goal": gid, "term": term, "file": path})
        check(f"{module}: give {gid} := {term!r} ok", not gerr, out)
        check(f"{module}: diff for {gid} applies", apply_diff(path, out), out)
        text, err = d.tool("load", {"file": path})
        check(f"{module}: reload after {gid} ok", not err, text)
        gs = goals(text)
    check(f"{module}: converged to 0 goals", len(gs) == 0, str(gs))
    ok, log = agda_clean(scratch, module)
    check(f"{module}: agda typechecks the closed proof", ok, log[-400:])

def main():
    binpath = sys.argv[1] if len(sys.argv) > 1 else discover_bin()
    graph = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "test", "deps.json")
    if not binpath or not os.path.exists(binpath):
        print("agda-explore binary not found; build it (cabal build agda-explore)"); sys.exit(2)
    if shutil.which("agda") is None:
        print("agda not on $PATH — this live test needs it; skipping."); sys.exit(0)

    scratch = tempfile.mkdtemp(prefix="agda-conv-")
    for f in os.listdir(PROJ):
        shutil.copy(os.path.join(PROJ, f), scratch)
    d = Daemon(binpath, graph)
    try:
        # 1. give-only convergence on a plain .agda module.
        converge(d, scratch, "Nat.agda", {10: "1", 13: "2", 16: "suc n"})
        # 1b. give_many: fill all of Nat.agda's holes in ONE session load,
        #     apply the single combined diff, and typecheck.
        shutil.copy(os.path.join(PROJ, "Nat.agda"), os.path.join(scratch, "Nat.agda"))  # restore holes
        natp = os.path.join(scratch, "Nat.agda")
        text, _ = d.tool("load", {"file": natp})
        terms = {10: "1", 13: "2", 16: "suc n"}
        gives = [{"goal": g, "term": terms[ln]} for g, _ty, ln in sorted(goals(text), key=lambda t: t[2])]
        out, err = d.tool("give_many", {"file": natp, "gives": gives})
        check("give_many: one combined diff, no error", not err, out)
        check("give_many: combined diff applies", apply_diff(natp, out), out)
        text2, _ = d.tool("load", {"file": natp})
        check("give_many: 0 goals after applying the batch", len(goals(text2)) == 0, text2)
        okb, logb = agda_clean(scratch, "Nat.agda")
        check("give_many: agda typechecks the batch-filled module", okb, logb[-300:])
        # 2. give convergence inside a literate .lagda.md module (edit must
        #    land in the code fence; agda must typecheck the literate file).
        converge(d, scratch, "Doc.lagda.md", {12: "6"})
        # 3. one-shot: case_split + refine each return an applyable diff and
        #    the patched file still loads (full convergence of Proof.agda is
        #    left to the agent-driven pass).
        proof = os.path.join(scratch, "Proof.agda")
        text, _ = d.tool("load", {"file": proof})
        # neg : Bool, three : Nat, double : Nat→Nat — pick the Bool goal to split.
        bid = next((g for g, ty, _ln in goals(text) if ty == "Bool"), None)
        check("Proof: found a Bool goal to split", bid is not None, text)
        if bid:
            out, e = d.tool("case_split", {"goal": bid, "var": "b", "file": proof})
            check("Proof: case_split returns a diff, no error", not e, out)
            check("Proof: case_split diff applies", apply_diff(proof, out), out)
            text2, e2 = d.tool("load", {"file": proof})
            check("Proof: reload after case_split ok", not e2, text2)
            check("Proof: split produced 2 Bool clauses",
                  len([1 for _g, ty, _l in goals(text2) if ty == "Bool"]) == 2, text2)
    finally:
        d.close()
        shutil.rmtree(scratch, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED: " + ", ".join(FAILS)); sys.exit(1)
    print("all convergence checks passed"); sys.exit(0)

if __name__ == "__main__":
    main()
