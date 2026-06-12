"""Generic, project-agnostic resolution of tool / binary paths.

A project descriptor (``config.py``) declares how each logical tool name maps
to an executable; the engine resolves it once. Nothing in this module is
project-specific — it is pure plumbing reused verbatim across projects.

Resolution specs (the value a project maps each tool to):

  ("path", "/abs/or/rel/path")              use verbatim (must exist)
  ("which", "toolname")                     search $PATH
  ("cmd",  ["build","print-bin","x"], cwd)  run; LAST stdout line is the path
  ("env",  "VAR", <fallback-spec>)          $VAR if set, else the fallback spec
  ("first", spec, spec, ...)                first spec that resolves wins

Examples:
  Haskell/cabal:  ("cmd", ["cabal", "list-bin", "my-exe"], repo_dir)
  Rust/cargo:     ("path", repo / "target/release/my-bin")
  on PATH:        ("which", "ripgrep")
  env-overridable:("env", "MY_BIN", ("which", "my-bin"))
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


class ToolNotFound(RuntimeError):
    pass


def resolve_tool(spec, *, timeout: int = 120) -> str:
    """Resolve a tool spec to an absolute executable path, or raise
    ToolNotFound. See the module docstring for the spec grammar."""
    if isinstance(spec, (str, Path)):
        spec = ("path", str(spec))
    kind = spec[0]

    if kind == "path":
        p = Path(spec[1]).expanduser()
        if not p.exists():
            raise ToolNotFound(f"path does not exist: {p}")
        return str(p)

    if kind == "which":
        p = shutil.which(spec[1])
        if not p:
            raise ToolNotFound(f"not on $PATH: {spec[1]!r}")
        return p

    if kind == "env":
        val = os.environ.get(spec[1])
        if val:
            return resolve_tool(("path", val), timeout=timeout)
        return resolve_tool(spec[2], timeout=timeout)

    if kind == "cmd":
        cmd = spec[1]
        cwd = str(spec[2]) if len(spec) > 2 and spec[2] is not None else None
        out = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        path = out.stdout.strip().splitlines()[-1] if out.stdout.strip() else ""
        if not path or not Path(path).exists():
            raise ToolNotFound(
                f"command {' '.join(cmd)!r} did not yield an existing path "
                f"(exit {out.returncode}): {out.stderr.strip()[:200]}"
            )
        return path

    if kind == "first":
        errors = []
        for sub in spec[1:]:
            try:
                return resolve_tool(sub, timeout=timeout)
            except ToolNotFound as e:
                errors.append(str(e))
        raise ToolNotFound("no spec resolved: " + " | ".join(errors))

    raise ValueError(f"unknown tool spec kind {kind!r} in {spec!r}")
