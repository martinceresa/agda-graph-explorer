"""Core test harness: the Case model, declarative checks, the runner, and
report compilation.

This module is the project-independent ENGINE — it knows nothing about any
particular project's tools. Everything project-specific (which binaries exist,
what counts as a crash, how to force determinism) is supplied by the project
descriptor (config.py) and threaded in by the orchestrator (run.py):
``run_case`` takes ``crash_markers`` and ``determinism_args``.

A `Case` is one invocation: a full command line (built by the area module from
ctx-resolved binary paths), optional stdin, a timeout, and a list of declarative
`checks`. The runner executes it, captures stdout/stderr/exit/wall-time as
artifacts under <outdir>/raw/<name>.*, evaluates the checks, and records a
verdict. Crash markers in stderr are ALWAYS flagged, even without a check.

Check specs (list of dicts, `type` selects the check):
  {"type": "exit_eq",        "v": 0}
  {"type": "exit_in",        "v": [0, 1]}
  {"type": "stdout_json"}                         # stdout must parse as JSON
  {"type": "stdout_nonempty"}
  {"type": "stdout_empty"}
  {"type": "stdout_contains",    "v": "..."}
  {"type": "stdout_not_contains","v": "..."}
  {"type": "stderr_contains",    "v": "..."}
  {"type": "no_crash"}                            # stderr lacks crash markers
  {"type": "determinism"}                         # re-run (+ determinism_args); stdout+exit must match
  {"type": "max_seconds",        "v": 60}         # wall-time budget (soft: flagged, not fatal)
"""
from __future__ import annotations

import dataclasses
import json
import subprocess
import time
from pathlib import Path

# Generic, cross-language crash signatures. A project descriptor (config.py)
# may override with a tighter, runtime-specific list via CRASH_MARKERS; the
# orchestrator threads whichever it finds into run_case().
DEFAULT_CRASH_MARKERS = [
    "Traceback (most recent call last)",       # Python
    "panic:", "goroutine ",                    # Go / Rust panics
    "Segmentation fault", "core dumped",
    "AddressSanitizer", "runtime error:",
    "Uncaught exception", "Unhandled exception",
    "<<loop>>",                                # Haskell black-hole
    "stack overflow", "StackOverflow",
    "out of memory", "OutOfMemoryError", "heap overflow",
    "internal error",
]


@dataclasses.dataclass
class Case:
    area: str
    name: str                       # unique within area; used for artifact filenames
    cmd: list                       # full argv (cmd[0] is the binary/interpreter)
    note: str = ""                  # what feature/edge this exercises
    stdin: bytes | None = None
    timeout: int = 120
    cwd: str | None = None
    env: dict | None = None
    checks: list = dataclasses.field(default_factory=list)
    # If set, the harness treats a nonzero exit as expected-and-fine for the
    # crash scan summary line (still recorded). Use for deliberate error cases.
    expect_error: bool = False


@dataclasses.dataclass
class Result:
    case: Case
    exit_code: int
    seconds: float
    stdout_bytes: int
    stderr_bytes: int
    timed_out: bool
    crashed: bool                   # crash marker found in stderr
    checks: list                    # [(spec_type, ok, detail)]
    artifacts: dict                 # {"out":path,"err":path,"meta":path}

    @property
    def passed(self) -> bool:
        return (not self.timed_out) and all(ok for _, ok, _ in self.checks)

    @property
    def anomalies(self) -> list:
        a = [f"{t}: {d}" for t, ok, d in self.checks if not ok]
        if self.timed_out:
            a.append(f"TIMEOUT after {self.case.timeout}s")
        if self.crashed and not self.case.expect_error:
            a.append("CRASH marker in stderr")
        return a


def _run(cmd, stdin, timeout, cwd, env):
    import os
    full_env = None
    if env:
        full_env = dict(os.environ); full_env.update(env)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True,
                           timeout=timeout, cwd=cwd, env=full_env)
        return p.returncode, p.stdout, p.stderr, time.time() - t0, False
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b""), (e.stderr or b""), time.time() - t0, True


def _eval_check(spec, exit_code, out, err, seconds, rerun, crash_markers):
    t = spec["type"]
    sd = out.decode("utf-8", "replace")
    se = err.decode("utf-8", "replace")
    if t == "exit_eq":
        return (exit_code == spec["v"], f"exit={exit_code} want={spec['v']}")
    if t == "exit_in":
        return (exit_code in spec["v"], f"exit={exit_code} want∈{spec['v']}")
    if t == "stdout_json":
        try:
            json.loads(sd); return (True, "valid JSON")
        except Exception as e:
            return (False, f"invalid JSON: {e}")
    if t == "stdout_nonempty":
        return (len(out) > 0, f"{len(out)} bytes")
    if t == "stdout_empty":
        return (len(out) == 0, f"{len(out)} bytes")
    if t == "stdout_contains":
        return (spec["v"] in sd, f"{'found' if spec['v'] in sd else 'MISSING'}: {spec['v']!r}")
    if t == "stdout_not_contains":
        return (spec["v"] not in sd, f"{'absent' if spec['v'] not in sd else 'PRESENT'}: {spec['v']!r}")
    if t == "stderr_contains":
        return (spec["v"] in se, f"{'found' if spec['v'] in se else 'MISSING'}: {spec['v']!r}")
    if t == "no_crash":
        hit = [m for m in crash_markers if m in se]
        return (not hit, "clean" if not hit else f"markers: {hit}")
    if t == "max_seconds":
        return (seconds <= spec["v"], f"{seconds:.1f}s budget={spec['v']}s")
    if t == "determinism":
        if rerun is None:
            return (True, "skipped (re-run unavailable)")
        r_exit, r_out = rerun
        same = (r_exit == exit_code and r_out == out)
        return (same, "match" if same else f"DIFFERS (exit {exit_code} vs {r_exit}, {len(out)} vs {len(r_out)} bytes)")
    return (False, f"unknown check type {t!r}")


def run_case(case: Case, out_root: Path, *, crash_markers=None,
             determinism_args=()) -> Result:
    crash_markers = DEFAULT_CRASH_MARKERS if crash_markers is None else crash_markers
    raw = out_root / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    code, out, err, secs, to = _run(case.cmd, case.stdin, case.timeout, case.cwd, case.env)

    # determinism: re-run the command (with determinism_args appended, e.g. the
    # GHC RTS multicore flags for -with-rtsopts=-N binaries) and assert the
    # output is byte-identical. With no extra args it is still a plain re-run,
    # which catches non-reproducible output on any toolchain.
    rerun = None
    if any(c["type"] == "determinism" for c in case.checks) and not to:
        re_cmd = list(case.cmd) + list(determinism_args)
        re_code, re_out, _, _, re_to = _run(re_cmd, case.stdin, case.timeout, case.cwd, case.env)
        if not re_to:
            rerun = (re_code, re_out)

    crashed = any(m in err.decode("utf-8", "replace") for m in crash_markers)
    checks = [(c["type"], *(_eval_check(c, code, out, err, secs, rerun, crash_markers)))
              for c in case.checks]

    ap = raw / f"{case.name}.out"; ap.write_bytes(out)
    ep = raw / f"{case.name}.err"; ep.write_bytes(err)
    meta = {
        "area": case.area, "name": case.name, "cmd": case.cmd, "note": case.note,
        "exit_code": code, "seconds": round(secs, 3), "timed_out": to,
        "stdout_bytes": len(out), "stderr_bytes": len(err), "crashed": crashed,
        "expect_error": case.expect_error,
        "checks": [{"type": t, "ok": ok, "detail": d} for t, ok, d in checks],
    }
    mp = raw / f"{case.name}.meta.json"; mp.write_text(json.dumps(meta, indent=2))

    return Result(case, code, secs, len(out), len(err), to, crashed, checks,
                  {"out": str(ap), "err": str(ep), "meta": str(mp)})


# --- report compilation (built from on-disk meta dicts, so resume works) ----

def _meta_passed(m: dict) -> bool:
    return (not m["timed_out"]) and all(c["ok"] for c in m["checks"])


def _meta_anomalies(m: dict) -> list:
    a = [f"{c['type']}: {c['detail']}" for c in m["checks"] if not c["ok"]]
    if m["timed_out"]:
        a.append("TIMEOUT")
    if m["crashed"] and not m.get("expect_error"):
        a.append("CRASH marker in stderr")
    return a


def write_area_report(area: str, metas: list[dict], out_root: Path,
                      label: str = "PyRun") -> dict:
    metas = sorted(metas, key=lambda m: m["name"])
    n = len(metas)
    passed = sum(1 for m in metas if _meta_passed(m))
    crashed = [m for m in metas if m["crashed"] and not m.get("expect_error")]
    anom = [(m, _meta_anomalies(m)) for m in metas if _meta_anomalies(m)]
    summary = {
        "area": area, "total": n, "passed": passed, "failed": n - passed,
        "crashes": len(crashed),
        "cases": [
            {"name": m["name"], "note": m["note"], "cmd": m["cmd"],
             "exit": m["exit_code"], "seconds": m["seconds"],
             "passed": _meta_passed(m), "crashed": m["crashed"],
             "anomalies": _meta_anomalies(m)}
            for m in metas
        ],
    }
    (out_root / "report.json").write_text(json.dumps(summary, indent=2))

    lines = [f"# {label} report — `{area}`", "",
             f"- cases: **{n}**  |  passed: **{passed}**  |  failed: **{n-passed}**  |  crashes: **{len(crashed)}**",
             ""]
    if anom:
        lines += ["## Anomalies", ""]
        for m, aa in anom:
            lines.append(f"### `{m['name']}` — {m['note']}")
            lines.append(f"- cmd: `{' '.join(m['cmd'])}`")
            lines.append(f"- exit `{m['exit_code']}`, {m['seconds']:.1f}s, "
                         f"stdout {m['stdout_bytes']}B, stderr {m['stderr_bytes']}B")
            for a in aa:
                lines.append(f"  - ⚠️ {a}")
            lines.append(f"  - artifacts: `raw/{m['name']}.out` `raw/{m['name']}.err`")
            lines.append("")
    lines += ["## All cases", "", "| case | exit | secs | pass | note |", "|---|---|---|---|---|"]
    for m in metas:
        lines.append(f"| `{m['name']}` | {m['exit_code']} | {m['seconds']:.1f} | "
                     f"{'✅' if _meta_passed(m) else '❌'} | {m['note']} |")
    (out_root / "report.md").write_text("\n".join(lines) + "\n")
    return summary
