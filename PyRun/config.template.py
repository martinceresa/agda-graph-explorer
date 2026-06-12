"""TEMPLATE project descriptor — copy to config.py and fill in for YOUR project.

PyRun's engine (run.py + harness.py + discover.py) is project-independent. To
exercise a new project's tools, you only write two things:

  1. this file (config.py) — paths, binaries, and engine settings, and
  2. tests/<area>.py modules — each exposing `cases(ctx) -> list[Case]`.

Nothing in the engine changes. Delete the parts you don't need; the engine
applies sensible defaults for everything marked OPTIONAL.

Quick start:
    cp config.template.py config.py     # then edit the marked spots
    # add tests/<area>.py for each AREA (see the example at the bottom)
    python3 run.py --list               # sanity-check discovery + case counts
    python3 run.py                       # run everything
"""
from __future__ import annotations

import os
from pathlib import Path

import discover

# REQUIRED: short label used in report headings.
PROJECT_LABEL = "my-project"

# The repo that contains this PyRun/ folder (portable default). Point external
# inputs (source trees, corpora) at env-overridable absolute paths.
REPO     = Path(os.environ.get("MYPROJ_REPO", str(Path(__file__).resolve().parents[1])))

# REQUIRED: where reports / raw captures / summary land. A dedicated subdir
# keeps generated output isolated from tracked source (one-line .gitignore).
OUT_ROOT = Path(os.environ.get("MYPROJ_OUT", str(Path(__file__).resolve().parent / "out")))

# REQUIRED: the case-module names under tests/ (tests/<area>.py).
AREAS = ["cli", "server"]   # <-- your surfaces

# REQUIRED: per-case timeout governance (clamp slow cases to bound total run).
GLOBAL_TIMEOUT_CAP = int(os.environ.get("MYPROJ_TIMEOUT_CAP", "90"))


def capped_timeout(t: int) -> int:
    return min(t, GLOBAL_TIMEOUT_CAP)


# OPTIONAL: stderr crash signatures. Omit to use the engine's cross-language
# default (harness.DEFAULT_CRASH_MARKERS). Override to tighten to your runtime.
# CRASH_MARKERS = ["panic:", "Traceback (most recent call last)", ...]

# OPTIONAL: args appended on the `determinism` check's re-run. Default: none
# (a plain re-run, which still catches non-reproducible output). Haskell
# projects use ["+RTS", "-N4", "-RTS"] to force multicore.
# DETERMINISM_RERUN_ARGS = []


# --- Binary discovery -------------------------------------------------------
# Map each logical tool name to a discover.resolve_tool spec. See discover.py
# for the spec grammar (path / which / cmd / env / first).
TOOLS = {
    "cli":    ("first",
               ("env", "MYPROJ_CLI", ("path", REPO / "target/release/mycli")),
               ("which", "mycli")),
    "server": ("path", REPO / "target/release/myserver"),
}


def bin_path(area: str) -> str:
    return discover.resolve_tool(TOOLS[area])


def outdir(area: str) -> Path:
    d = OUT_ROOT / area
    d.mkdir(parents=True, exist_ok=True)
    (d / "raw").mkdir(exist_ok=True)
    return d


# OPTIONAL: build/generate any fixtures your cases consume. Engine hook for
# `run.py --prepare[-if-missing]`. Delete if your tools need no fixtures.
# def prepare(force: bool = True) -> None:
#     ...


# REQUIRED: the object handed to every cases(ctx). Must expose .bin(area);
# attach whatever else your case modules reference (paths, fixtures, …).
class Ctx:
    repo     = REPO
    out_root = OUT_ROOT

    @staticmethod
    def bin(area: str) -> str:
        return bin_path(area)


# --- Example tests/cli.py (put this in tests/cli.py, not here) --------------
#
#   from harness import Case
#
#   def cases(ctx):
#       cli = str(ctx.bin("cli"))
#       return [
#           Case(area="cli", name="help", cmd=[cli, "--help"],
#                note="prints usage",
#                checks=[{"type": "exit_eq", "v": 0},
#                        {"type": "stdout_contains", "v": "USAGE"},
#                        {"type": "no_crash"}]),
#           Case(area="cli", name="version", cmd=[cli, "--version"],
#                note="prints a version",
#                checks=[{"type": "exit_eq", "v": 0}, {"type": "stdout_nonempty"}]),
#       ]
