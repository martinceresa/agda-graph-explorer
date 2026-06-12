#!/usr/bin/env python3
"""PyRun orchestrator — the project-independent engine entry point.

Usage:
  python3 run.py                 # run every area's full matrix
  python3 run.py opt explore     # run only the named areas
  python3 run.py --list          # list cases per area without running
  python3 run.py --force         # ignore cached results; re-run every case
  python3 run.py --prepare       # run the project's fixture-prep hook, then exit
  python3 run.py --prepare-if-missing  # prep only what's absent, then run
                                 # (--gen / --gen-if-missing are accepted aliases)

This file knows nothing about any particular project. It reads the *project
descriptor* from config.py through a small, documented interface and drives the
engine in harness.py. Each area's tests/<area>.py exposes
`cases(ctx) -> list[Case]`. Results land in <OUT_ROOT>/<area>/ (report.md,
report.json, raw/<case>.{out,err,meta.json}) and a top-level
<OUT_ROOT>/summary.{md,json} aggregates everything.

Project-descriptor interface (config.py) — required:
  AREAS: list[str]                 case-module names under tests/
  OUT_ROOT: Path                   where reports/raw/summary land
  Ctx                              object handed to each cases(ctx); needs .bin(name)
  outdir(area) -> Path             make+return OUT_ROOT/<area> (with raw/)
  capped_timeout(t) -> int         per-case timeout governance
Optional (sensible defaults applied here if absent):
  PROJECT_LABEL: str               report heading (default "PyRun")
  CRASH_MARKERS: list[str]         stderr crash signatures (default: harness's)
  DETERMINISM_RERUN_ARGS: list     args appended on the determinism re-run (default: none)
  prepare(force: bool) -> None     build/generate fixtures the cases need
"""
from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import config
from harness import Case, run_case, write_area_report

# --- project-descriptor interface, with defaults for the optional parts ------
LABEL            = getattr(config, "PROJECT_LABEL", "PyRun")
CRASH_MARKERS    = getattr(config, "CRASH_MARKERS", None)        # None -> harness default
DETERMINISM_ARGS = getattr(config, "DETERMINISM_RERUN_ARGS", ())


def prepare(force: bool) -> None:
    """Run the project's fixture-preparation hook, if it defines one."""
    hook = getattr(config, "prepare", None)
    if callable(hook):
        hook(force=force)
    else:
        print(f"[{LABEL}] no prepare() hook in config.py — nothing to prepare.")


def load_cases(area: str) -> list[Case]:
    mod = importlib.import_module(f"tests.{area}")
    return list(mod.cases(config.Ctx))


def build_summary() -> None:
    """Aggregate the top-level summary from every area's report.json on disk,
    so a partial / parallel / resumed run still yields a complete picture."""
    overall = {"areas": {}, "totals": {"total": 0, "passed": 0, "crashes": 0}}
    for area in config.AREAS:
        rp = config.OUT_ROOT / area / "report.json"
        if not rp.exists():
            continue
        s = json.loads(rp.read_text())
        overall["areas"][area] = {k: s[k] for k in ("total", "passed", "failed", "crashes")}
        for k in ("total", "passed", "crashes"):
            overall["totals"][k] += s[k]
    (config.OUT_ROOT / "summary.json").write_text(json.dumps(overall, indent=2))
    lines = [f"# {LABEL} summary", ""]
    for area, s in overall["areas"].items():
        lines.append(f"- **{area}**: {s['passed']}/{s['total']} passed, {s['crashes']} crashes")
    t = overall["totals"]
    lines += ["", f"**Total: {t['passed']}/{t['total']} passed, {t['crashes']} crashes.**", ""]
    (config.OUT_ROOT / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n" + "\n".join(lines))


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    areas = [a for a in argv if not a.startswith("--")] or config.AREAS

    if "--prepare" in flags or "--gen" in flags:
        prepare(force=True); return
    if "--prepare-if-missing" in flags or "--gen-if-missing" in flags:
        prepare(force=False)

    if "--list" in flags:
        for area in areas:
            cs = load_cases(area)
            print(f"\n== {area} ({len(cs)} cases) ==")
            for c in cs:
                print(f"  {c.name:38} {c.note}")
        return

    force = "--force" in flags
    for area in areas:
        out_root = config.outdir(area)
        try:
            cs = load_cases(area)
        except Exception as e:
            print(f"[{area}] FAILED to load cases: {e}")
            continue
        print(f"\n=== {area}: {len(cs)} cases ===")
        metas = []
        for c in cs:
            mp = out_root / "raw" / f"{c.name}.meta.json"
            if mp.exists() and not force:
                print(f"  [cache] {c.name:38} (skipped)")
                metas.append(json.loads(mp.read_text()))
                continue
            c.timeout = config.capped_timeout(c.timeout)
            r = run_case(c, out_root, crash_markers=CRASH_MARKERS,
                         determinism_args=DETERMINISM_ARGS)
            mark = "ok " if r.passed else "FAIL"
            cr = " CRASH" if (r.crashed and not c.expect_error) else ""
            print(f"  [{mark}{cr}] {c.name:38} exit={r.exit_code} {r.seconds:5.1f}s")
            metas.append(json.loads(mp.read_text()))
        write_area_report(area, metas, out_root, label=LABEL)

    build_summary()


if __name__ == "__main__":
    main(sys.argv[1:])
