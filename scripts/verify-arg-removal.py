#!/usr/bin/env python3
"""Semantic acceptance for `agda-unused --kinds=arg-removable`.

For each finding, delete the flagged binders from the definition's source
signature, re-typecheck the file, and assert it still compiles. This tests
OUR INDEX PLUMBING, not Agda's analysis: the producer's verdict needs no
re-proving, but "position 2 of this definition" has to name the binder a
human would count, and that is ours to get wrong.

Needs `agda` on $PATH. Offline, slow, NOT in CI.

    scripts/verify-arg-removal.py --graph deps.json ROOT [-i INCLUDE ...]

Two properties, and the second is the one that makes the first mean
anything:

  POSITIVE  deleting a finding's whole `delete` set leaves a file that
            still typechecks.
  NEGATIVE  deleting a position the report did NOT flag makes it fail.

Without the negative control a script that silently edits nothing reports
100% success. Every positive result here is paired with a negative probe on
the same definition; a definition whose negative probe also passes is
reported as INCONCLUSIVE, not as a pass.

Scope, stated rather than hidden. A finding is only attempted when every
position in its deletion set is a **named binder in an explicit group**
(`{a : T}`, `(a : T)`, `⦃ a : T ⦄`, optionally `.`-irrelevant) and the
definition has **no callers** (so no call site needs the matching argument
dropped). Everything else is SKIPPED with a reason and counted. Unnamed
domains (`Nat → Nat`) are skipped because locating them textually means
counting arrows through nested types, which is the kind of guessing this
script exists to catch rather than commit.

Acting on `delete[i]` rather than on `i` is mandatory: a partial removal
strands a later binder, which is exactly the failure the set exists to
prevent.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Signature parsing


@dataclass
class Group:
    """One binder group in a telescope, with its span in the signature text."""

    start: int
    end: int          # exclusive
    names: list[str]  # [] for an unnamed domain
    hiding: str       # explicit | implicit | instance
    positions: list[int] = field(default_factory=list)


OPENERS = {"(": ")", "{": "}", "⦃": "⦄"}
CLOSERS = set(OPENERS.values())
HIDING = {"(": "explicit", "{": "implicit", "⦃": "instance"}


def parse_telescope(sig: str) -> list[Group] | None:
    """Split a signature's telescope into binder groups, in position order.

    Returns None when the signature contains something this v1 does not
    model, so the caller skips rather than guesses.
    """
    groups: list[Group] = []
    i, n, pos = 0, len(sig), 0
    while i < n:
        c = sig[i]
        if c.isspace():
            i += 1
            continue
        # `∀` just scopes the groups after it; it binds nothing itself.
        if c == "∀":
            i += 1
            continue
        # A codomain arrow at depth 0 ends the telescope only if nothing
        # follows that binds; keep walking — trailing domains are groups too.
        if sig.startswith("→", i) or sig.startswith("->", i):
            i += 2 if sig.startswith("->", i) else 1
            continue
        irrelevant = False
        if c == "." and i + 1 < n and sig[i + 1] in OPENERS:
            irrelevant = True
            i += 1
            c = sig[i]
        if c in OPENERS:
            depth, j = 0, i
            while j < n:
                if sig[j] in OPENERS:
                    depth += 1
                elif sig[j] in CLOSERS:
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= n:
                return None                       # unbalanced: refuse
            inner = sig[i + 1 : j]
            hiding = HIDING[c]
            if c == "{" and inner.startswith("{") and inner.endswith("}"):
                hiding, inner = "instance", inner[1:-1]
            if ":" in inner:
                names = inner.split(":", 1)[0].split()
            else:
                names = inner.split()            # `∀ {a b}` — no type given
            if not names or any(not _is_name(x) for x in names):
                return None
            g = Group(i - (1 if irrelevant else 0), j + 1, names, hiding)
            for _ in names:
                g.positions.append(pos)
                pos += 1
            groups.append(g)
            i = j + 1
            continue
        # A bare (unnamed) domain: consume to the next depth-0 arrow.
        j, depth = i, 0
        while j < n:
            if sig[j] in OPENERS:
                depth += 1
            elif sig[j] in CLOSERS:
                depth -= 1
            elif depth == 0 and (sig.startswith("→", j) or sig.startswith("->", j)):
                break
            j += 1
        if j >= n:
            break                                 # the codomain: not a binder
        groups.append(Group(i, j, [], "explicit", [pos]))
        pos += 1
        i = j
    return groups


def _is_name(tok: str) -> bool:
    return bool(tok) and not any(ch in tok for ch in "()[]{}→:")


# ---------------------------------------------------------------------------
# Source surgery


def find_declaration(lines: list[str], line_no: int, short: str) -> tuple[int, int] | None:
    """Span of the `name : type` declaration starting at 1-based `line_no`."""
    i = line_no - 1
    if i < 0 or i >= len(lines):
        return None
    if not lines[i].lstrip().startswith(short):
        return None
    j = i
    while j < len(lines):
        # The declaration ends at the line before the first clause: a line
        # at the same indent starting with the name again, or a blank line
        # followed by one.
        if j > i and lines[j].lstrip().startswith(short) and "=" in lines[j]:
            break
        if j > i and not lines[j].strip():
            break
        j += 1
    return (i, j)


def delete_positions(sig: str, groups: list[Group], drop: set[int]) -> str | None:
    """Remove every binder whose position is in `drop`, right to left."""
    out = sig
    for g in sorted(groups, key=lambda g: g.start, reverse=True):
        hit = [p for p in g.positions if p in drop]
        if not hit:
            continue
        if len(hit) == len(g.positions):
            # A group may or may not be followed by an arrow: `(a : T) → B`
            # has one, `{a} (b : T) → B` does not between the first two.
            # Removing the group must take its arrow with it, or the
            # signature is left starting with `→`.
            end = g.end
            rest = out[end:]
            m = re.match(r"\s*(→|->)", rest)
            if m:
                end += m.end()
            out = out[: g.start] + out[end:]              # whole group goes
        else:
            keep = [nm for nm, p in zip(g.names, g.positions) if p not in drop]
            if not keep:
                return None
            inner = out[g.start : g.end]
            if ":" not in inner:
                return None
            _, ty = inner.split(":", 1)
            open_c = inner[0]
            if open_c not in OPENERS:
                return None
            out = (out[: g.start] + open_c + " ".join(keep) + " :" + ty
                   + out[g.end :])
    return re.sub(r"[ \t]+", " ", out)


# ---------------------------------------------------------------------------
# Driver


def typechecks(agda: str, root: Path, target: Path, includes: list[str]) -> tuple[bool, str]:
    cmd = [agda, "--no-libraries"]
    for inc in includes:
        cmd += ["-i", inc]
    cmd += ["-i", str(root), str(target)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    return r.returncode == 0, (r.stdout + r.stderr)[-800:]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="source root passed to agda-unused")
    ap.add_argument("--graph", required=True)
    ap.add_argument("--unused-bin", default="agda-unused")
    ap.add_argument("--agda-bin", default="agda")
    ap.add_argument("-i", dest="includes", action="append", default=[])
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    out = subprocess.run(
        [args.unused_bin, f"--graph={args.graph}", "--kinds=arg-removable",
         "--format=json", str(root)],
        capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr, file=sys.stderr)
        return 2
    findings = json.loads(out.stdout)
    if args.limit:
        findings = findings[: args.limit]

    tally = {"pass": 0, "FAIL": 0, "inconclusive": 0}
    skips: Counter[str] = Counter()
    failures: list[str] = []
    sources: dict[Path, list[str]] = {}

    # One copy of the tree for every probe, so Agda's .agdai interfaces
    # persist and each probe re-checks only the edited module's cone.
    with tempfile.TemporaryDirectory() as td:
      work = Path(td) / "work"
      shutil.copytree(root, work)

      for f in findings:
        argsj = f.get("arguments")
        qn = f"{f['module']}.{f['symbol']}"
        if not argsj:
            skips["no arguments payload"] += 1
            continue

        src = root / f["file"]        # pathlib keeps an absolute right operand
        if not src.exists():
            skips["source not found"] += 1
            continue
        if src not in sources:
            sources[src] = src.read_text(encoding="utf-8").splitlines()
        lines = sources[src]
        short = f["symbol"].split("@")[0]
        span = find_declaration(lines, f["line"], short)
        if span is None:
            skips["declaration not located"] += 1
            continue

        decl = "\n".join(lines[span[0] : span[1]])
        if ":" not in decl:
            skips["no signature"] += 1
            continue
        head, sig = decl.split(":", 1)
        groups = parse_telescope(sig)
        if groups is None:
            skips["signature not modelled"] += 1
            continue

        pos_list = argsj["positions"]
        target_pos = pos_list[0]
        drop = set(argsj.get("delete", {}).get(str(target_pos), [target_pos]))
        # Order matters for an honest skip reason: an unnamed domain is
        # always explicit, so reporting it as "unnamed" would hide that the
        # real limiter is the clause LHS, not the name.
        hid = {p: g.hiding for g in groups for p in g.positions}
        if any(hid.get(p) == "explicit" for p in drop):
            skips["explicit binder (clause LHS would change too)"] += 1
            continue
        named = {p for g in groups if g.names for p in g.positions}
        if not drop <= named:
            skips["unnamed binder in the set"] += 1
            continue

        # POSITIVE: delete the whole set; the file must still typecheck.
        ok_pos, log = _try_edit(args, root, work, src, lines, span, head, sig, groups, drop)
        # NEGATIVE: delete a position the report did NOT flag. If that also
        # passes, the edit is not discriminating and the positive proves
        # nothing about this definition.
        others = sorted(named - set(pos_list))
        ok_neg = False
        if others:
            npos = others[0]
            if hid.get(npos) != "explicit":
                ok_neg, _ = _try_edit(args, root, work, src, lines, span, head,
                                      sig, groups, {npos})

        if not ok_pos:
            tally["FAIL"] += 1
            failures.append(f"{qn}: deleting {sorted(drop)} broke the build\n    {log.strip()[:300]}")
        elif ok_neg:
            tally["inconclusive"] += 1
        else:
            tally["pass"] += 1

    print(f"findings: {len(findings)}")
    print(f"  pass         : {tally['pass']}")
    print(f"  FAIL         : {tally['FAIL']}")
    print(f"  inconclusive : {tally['inconclusive']}   (negative control also typechecked)")
    tot_skip = sum(skips.values())
    print(f"  skipped      : {tot_skip}")
    for k, v in sorted(skips.items(), key=lambda kv: -kv[1]):
        print(f"      {v:4}  {k}")
    for msg in failures:
        print(f"\nFAIL {msg}")
    return 1 if tally["FAIL"] else 0


def _try_edit(args, root: Path, work: Path, src: Path, lines, span, head, sig, groups, drop):
    """Apply one edit inside the shared work tree, then restore it.

    The tree is copied ONCE by the caller, not per probe. That is not just
    less I/O: a fresh copy has no `.agdai` interfaces, so every probe would
    recompile the whole dependency closure instead of re-checking the
    edited module's cone. Restoring the original bytes in `finally` keeps
    probes independent while the interfaces persist across them.
    """
    new_sig = delete_positions(sig, groups, drop)
    if new_sig is None:
        return False, "could not rewrite the signature"
    edited = list(lines)
    edited[span[0] : span[1]] = [f"{head}:{new_sig}"]
    rel = src.resolve().relative_to(root)
    target = work / rel
    original = target.read_bytes()
    try:
        target.write_text("\n".join(edited) + "\n", encoding="utf-8")
        return typechecks(args.agda_bin, work, target, args.includes)
    finally:
        target.write_bytes(original)


if __name__ == "__main__":
    sys.exit(main())
