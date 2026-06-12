"""Project descriptor — the ONE file that makes PyRun specific to a project.

This instance targets **agda-graph-explorer**. The engine (run.py + harness.py
+ discover.py) is project-independent and reads this file through the interface
documented at the top of run.py. To point PyRun at a different project, copy the
PyRun/ folder, replace this file (see config.template.py) and write that
project's tests/<area>.py case modules — nothing in the engine changes.

What a descriptor provides:
  required : AREAS, OUT_ROOT, Ctx, outdir(), capped_timeout()
  optional : PROJECT_LABEL, CRASH_MARKERS, DETERMINISM_RERUN_ARGS, prepare()

Everything is discovered at runtime so the framework keeps working after a
rebuild; override any path via the AGE_* environment variables noted below.
"""
from __future__ import annotations

import functools
import os
import subprocess
import time
from pathlib import Path

import discover

PROJECT_LABEL = "agda-graph-explorer"

# --- Locations --------------------------------------------------------------
# REPO defaults to the repo that contains this PyRun/ folder (portable); the
# external corpus + producer repos can't be inferred, so they take env-aware
# defaults you override per machine with AGE_CORPUS / AGE_DEPS.
REPO        = Path(os.environ.get("AGE_REPO",   str(Path(__file__).resolve().parents[1])))
DEPS_REPO   = Path(os.environ.get("AGE_DEPS",   "/home/mceresa/Repositories/Projects/AgdaDependencies"))
# The corpus is an external Agda development; set AGE_CORPUS to point at it
# (the default below is a neutral placeholder that won't exist on your machine).
CORPUS      = Path(os.environ.get("AGE_CORPUS", str(REPO.parent / "agda-corpus")))
CORPUS_MAIN = os.environ.get("AGE_CORPUS_MAIN", "Main.lagda.md")

# Corpus-specific example identifiers used by the `explore` cases. They must
# match real nodes in the graph fixture, so they are corpus-dependent: set them
# for YOUR corpus via env. The defaults are neutral placeholders that will not
# match a real graph — so the explore cases stay red until you supply these.
EX_FN            = os.environ.get("AGE_EX_FN",            "My.Module.someFunction")   # a Defined function
EX_FN2           = os.environ.get("AGE_EX_FN2",           "My.Module.otherFunction")  # another function, same module
EX_POSTULATE     = os.environ.get("AGE_EX_POSTULATE",     "My.Module.somePostulate")  # a postulate
EX_MODULE_PREFIX = os.environ.get("AGE_EX_MODULE_PREFIX", "My.Module")                 # a module subtree to filter by
EX_SEARCH        = os.environ.get("AGE_EX_SEARCH",        "some")                      # a substring that matches something
EX_MISSING       = os.environ.get("AGE_EX_MISSING",       "No.Such.Definition.absent_xyz123")  # guaranteed-absent name

PYRUN   = REPO / "PyRun"        # the harness's home (= this folder)
BATTLE  = REPO / "BattleTest"   # legacy: archived prior run + reusable graph fixtures

# Where reports / raw captures / summary land (engine-required: OUT_ROOT).
# A dedicated subdir keeps all generated output isolated from the tracked
# source, so .gitignore is a single line (PyRun/out/).
OUT_ROOT = Path(os.environ.get("AGE_OUT", str(PYRUN / "out")))
# Where graph fixtures live (and where prepare() writes them).
GRAPHS  = Path(os.environ.get("AGE_GRAPHS", str(OUT_ROOT / "graphs")))


def _resolve_graph(fname: str, env_var: str) -> Path:
    """Resolve a graph fixture: env override > PyRun/graphs > the legacy
    BattleTest/graphs fixtures (reused as-is) > PyRun/graphs as the prepare()
    target even if absent yet."""
    if os.environ.get(env_var):
        return Path(os.environ[env_var])
    for cand in (GRAPHS / fname, BATTLE / "graphs" / fname):
        if cand.exists():
            return cand
    return GRAPHS / fname


GRAPH_BASE = _resolve_graph("graph-base.json", "AGE_GRAPH_BASE")  # full stdlib closure (~15k nodes), plain
GRAPH_FULL = _resolve_graph("graph-full.json", "AGE_GRAPH_FULL")  # project-only (~5.8k) + signatures + term-hashes + provenance

# --- Engine settings (optional interface) -----------------------------------
AREAS = ["opt", "unused", "goals", "explore", "plugin"]

# GHC/Haskell-specific crash signatures — tighter than the engine's generic
# default (harness.DEFAULT_CRASH_MARKERS), tuned to this project's runtime.
CRASH_MARKERS = [
    "Uncaught exception",
    "CallStack (from HasCallStack)",
    "Prelude.head", "Prelude.tail", "Prelude.!!", "Prelude.last", "Prelude.init",
    "Non-exhaustive patterns",
    "Maybe.fromJust", "IntMap.!", "Map.!",
    "<<loop>>", "stack overflow", "out of memory", "heap overflow",
    "internal error", "ghc-internal",
]
# agda-optimization / agda-unused build -with-rtsopts=-N; force multicore on the
# determinism re-run so output must be byte-identical at -N1 vs -N4.
DETERMINISM_RERUN_ARGS = ["+RTS", "-N4", "-RTS"]

# Timeout governance. A genuinely-slow case proves "too slow" at the cap just as
# well as at its full budget, so clamp per-case timeouts to bound the total run
# — EXCEPT cases that legitimately need a big budget (live agda-explore
# regeneration), exempted by a threshold.
GLOBAL_TIMEOUT_CAP = int(os.environ.get("AGE_TIMEOUT_CAP", "90"))
CAP_EXEMPT_AT      = int(os.environ.get("AGE_TIMEOUT_EXEMPT_AT", "400"))


def capped_timeout(t: int) -> int:
    return t if t >= CAP_EXEMPT_AT else min(t, GLOBAL_TIMEOUT_CAP)


# --- Binary discovery -------------------------------------------------------
# Each area's binary is resolved (cached) via discover.resolve_tool. The agda
# binaries come from `cabal list-bin` in this repo; agda-deps from a recorded
# path or the producer repo. Override any with the env var in ENV_OVERRIDES.
_EXE = {
    "opt":     "agda-optimization",
    "unused":  "agda-unused",
    "goals":   "agda-goals",
    "explore": "agda-explore",
}

ENV_OVERRIDES = {  # area -> env var that, if set, is used verbatim as the binary path
    "opt":     "AGE_BIN_OPT",
    "unused":  "AGE_BIN_UNUSED",
    "goals":   "AGE_BIN_GOALS",
    "explore": "AGE_BIN_EXPLORE",
    "deps":    "AGE_BIN_DEPS",
}


def _deps_bin_record() -> Path | None:
    """Recorded absolute path to agda-deps, if a `.agda-deps-bin` file exists
    under the output root / PyRun (preferred) or the legacy BattleTest dir."""
    for d in (OUT_ROOT, PYRUN, BATTLE):
        rec = d / ".agda-deps-bin"
        if rec.exists():
            p = rec.read_text().strip()
            if p and Path(p).exists():
                return Path(p)
    return None


@functools.lru_cache(maxsize=None)
def bin_path(area: str) -> str:
    """Absolute path to the binary for an area (or 'deps' for agda-deps)."""
    env = ENV_OVERRIDES.get(area)
    if env and os.environ.get(env):
        return os.environ[env]
    if area == "deps":
        rec = _deps_bin_record()
        if rec is not None:
            return str(rec)
        return discover.resolve_tool(("cmd", ["cabal", "list-bin", "agda-deps"], DEPS_REPO))
    return discover.resolve_tool(("cmd", ["cabal", "list-bin", _EXE[area]], REPO))


def outdir(area: str) -> Path:
    d = OUT_ROOT / area
    d.mkdir(parents=True, exist_ok=True)
    (d / "raw").mkdir(exist_ok=True)
    return d


# --- Fixture preparation (optional interface) -------------------------------
def prepare(force: bool = True) -> None:
    """Generate the two graph.json fixtures from the corpus via agda-deps.
    Engine hook for `run.py --prepare[-if-missing]`."""
    GRAPHS.mkdir(parents=True, exist_ok=True)
    deps = bin_path("deps")
    jobs = [
        ("graph-base.json", ["--keep-going", "--format=json", "--json-mode=expanded"]),
        ("graph-full.json", ["--keep-going", "--no-externals", "--with-signatures",
                              "--with-term-hashes", "--min-term-depth=3",
                              "--format=json", "--json-mode=expanded"]),
    ]
    for fname, flags in jobs:
        dest = GRAPHS / fname
        if dest.exists() and not force:
            print(f"[prepare] {fname} exists, skipping"); continue
        tmp = GRAPHS / f".{fname}.d"
        tmp.mkdir(exist_ok=True)
        print(f"[prepare] {fname} via agda-deps {' '.join(flags)} ...")
        t0 = time.time()
        p = subprocess.run([deps, *flags, f"--out-dir={tmp}", CORPUS_MAIN],
                          cwd=str(CORPUS), capture_output=True, text=True, timeout=900)
        produced = tmp / "deps.json"
        if produced.exists():
            produced.replace(dest)
            print(f"[prepare] {fname}: {dest.stat().st_size} bytes in {time.time()-t0:.0f}s")
        else:
            print(f"[prepare] {fname} FAILED (exit {p.returncode}):\n{p.stderr[-800:]}")
        for f in tmp.glob("*"):
            f.unlink()
        tmp.rmdir()


class Ctx:
    """Handed to every area's cases(ctx). Bundles resolved paths."""
    repo        = REPO
    deps_repo   = DEPS_REPO
    corpus      = CORPUS
    corpus_main = CORPUS_MAIN
    battle      = BATTLE
    out_root    = OUT_ROOT
    graphs      = GRAPHS
    graph_base  = GRAPH_BASE
    graph_full  = GRAPH_FULL
    # corpus-specific example identifiers for the explore cases (env-supplied)
    ex_fn            = EX_FN
    ex_fn2           = EX_FN2
    ex_postulate     = EX_POSTULATE
    ex_module_prefix = EX_MODULE_PREFIX
    ex_search        = EX_SEARCH
    ex_missing       = EX_MISSING

    @staticmethod
    def bin(area: str) -> str:
        return bin_path(area)
