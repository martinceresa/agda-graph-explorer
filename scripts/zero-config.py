#!/usr/bin/env python3
"""zero-config.py — one-shot config bootstrap for every agda-graph-explorer tool.

Writes one config file per tool — `.agda-unused.yml`, `.agda-optimization.yml`,
`.agda-explore.yml`, `.agda-auto.yml`, `.agda-goals.yml`, plus the producer-side
`.agda-deps.yml` — each seeded from that binary's own `--show-defaults` payload
(so the emitted defaults can never drift from the code), then pointed at ONE
shared graph: `<graph-dir>/deps.json`, default `.agda-deps/deps.json`.

Afterwards every tool runs with no flags:

    agda-optimization motif          # graph from `global: graph:`
    agda-unused                      # graph + roots from the config
    agda-auto src/Foo.agda           # graph for hint ranking
    agda-explore                     # live: regenerates that same file itself

Two deliberate asymmetries:

  * `agda-explore` is wired LIVE (`entries:` + `include:` + `out-dir:`), not
    pinned via `graph:`. Its graph path is `<out-dir>/deps.json`, so the daemon
    keeps the shared file fresh and the other four tools read what it last
    published. Pinning `graph:` instead would switch it to preloaded mode: no
    rebuilds, no watcher.
  * `agda-goals` consumes no graph (it drives `agda --interaction-json` over
    source files), so it gets `roots:` + `include-paths:` and an `agda`
    preflight — there is nothing to cross-check.

This script never builds the graph: it spawns no Agda work. It VERIFIES the
graph instead — that it exists, decodes as v2 expanded, carries the
capabilities the configs assume (signatures / edge provenance / subterm
hashes), and that every config resolves to the same file — then prints the
exact `agda-deps` command to build or refresh it.

Exit codes (same rule as `agda-explore doctor`: 0 iff no check failed):

  0  configs written or already current, and no failing check.
  1  a check FAILED: the configs disagree about which graph they read, or the
     graph exists but does not decode. A not-yet-built graph is a WARNING (the
     expected first-run state), as is a missing `agda-deps` / `agda` — nothing
     is built here, so those only block the command we print.
  2  usage / environment error: no tool binaries found at all, no detectable
     entry module, or an unwritable project directory.

Pure standard library (no PyYAML): every config is produced by line-level
edits over the tool's own `--show-defaults` text, which keeps its comments and
key ordering intact and makes re-runs byte-identical.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

# The producer always writes <out-dir>/deps.json, and agda-explore always reads
# <out-dir>/deps.json ('AgdaMcp.State.cfgGraphPath'). So the shared graph is
# identified by its DIRECTORY; the file name is not ours to choose.
GRAPH_FILE = "deps.json"
DEFAULT_GRAPH_DIR = ".agda-deps"

# Written in this order; agda-deps first because it is the recipe for the graph
# everything else reads.
TOOLS = ["agda-deps", "agda-unused", "agda-optimization", "agda-explore",
         "agda-auto", "agda-goals"]

# Tools whose config names the shared graph (agda-goals reads no graph;
# agda-deps writes it).
GRAPH_CONSUMERS = ["agda-unused", "agda-optimization", "agda-explore", "agda-auto"]

SOURCE_SUFFIXES = (".agda", ".lagda", ".lagda.md", ".lagda.rst", ".lagda.tex")

SKIP_DIRS = {".git", ".hg", ".svn", "_build", "dist-newstyle", "MAlonzo",
             "node_modules", ".stack-work", "__pycache__", ".agda-explore",
             ".agda-deps"}

# Preferred entry module base names, best first: a project with an Everything
# module means it for exactly this purpose.
ENTRY_PREFERENCE = ("Everything", "All", "Index", "index", "Main")

# Above this many independent root modules, guessing is worse than asking.
MAX_AUTO_ENTRIES = 8

STATUS_SYM = {"ok": "✓", "warn": "!", "fail": "✗", "skip": "–"}


class Fatal(Exception):
    """An environment / usage error: report and exit 2."""


# --------------------------------------------------------------------------
# YAML text surgery (comment-preserving, standard library only)
# --------------------------------------------------------------------------
#
# The `--show-defaults` payloads are hand-written, commented YAML. Rewriting
# them through a YAML round-trip would drop every comment, so instead each key
# is edited IN PLACE at the line level. Three spellings occur across the tools:
# an active `key: v`, a commented `# key: v` (this repo's five binaries), and a
# commented `#key: v` (agda-deps).


def _key_line_re(key: str) -> "re.Pattern[str]":
    return re.compile(r"^(?P<indent>[ \t]*)(?P<hash>#[ \t]*)?"
                      + re.escape(key) + r"[ \t]*:(?P<rest>.*)$")


def _section_span(lines, section):
    """`(body_start, body_end, child_indent)` for a top-level `section:` block.

    The body runs to the first line that starts at column 0 — including a
    comment, since in the `agda-optimization` skeleton each section is
    introduced by a column-0 `# name — desc` line that belongs to the NEXT
    section. Returns None when the section is absent.
    """
    header = re.compile(r"^" + re.escape(section) + r"[ \t]*:[ \t]*(#.*)?$")
    for i, line in enumerate(lines):
        if header.match(line):
            j = i + 1
            while j < len(lines):
                if lines[j].strip() == "" or lines[j][:1] in (" ", "\t"):
                    j += 1
                    continue
                break
            # Child indent: copy an existing child's, else two spaces.
            indent = "  "
            for k in range(i + 1, j):
                stripped = lines[k].lstrip(" \t")
                if stripped:
                    indent = lines[k][: len(lines[k]) - len(stripped)]
                    break
            return i + 1, j, indent
    return None


def _find_key(lines, key, lo, hi, section):
    """Index + match of `key` within `lines[lo:hi]`, preferring an active line.

    A key at the wrong nesting depth is ignored: top-level keys sit at column 0,
    section children are indented.
    """
    rx = _key_line_re(key)
    commented = None
    for i in range(lo, hi):
        m = rx.match(lines[i])
        if not m:
            continue
        nested = len(m.group("indent")) > 0
        if (section is None) == nested:
            continue
        if m.group("hash"):
            if commented is None:
                commented = (i, m)
            continue
        return i, m
    return commented


def set_key(text: str, key: str, value, section: str = None) -> str:
    """Return `text` with `key` set to `value`, in place, comments preserved.

    Replaces an active or commented `key:` line (uncommenting it), inserting at
    the end of the block when the key is absent and appending the whole section
    when that is absent too.
    """
    trailing_nl = text.endswith("\n")
    lines = text.splitlines()

    if section is None:
        lo, hi, indent = 0, len(lines), ""
    else:
        span = _section_span(lines, section)
        if span is None:
            lines += ["", "%s:" % section, "  %s: %s" % (key, yaml_scalar(value))]
            out = "\n".join(lines)
            return out + "\n" if trailing_nl else out
        lo, hi, indent = span

    rendered = "%s%s: %s" % (indent, key, yaml_scalar(value))
    hit = _find_key(lines, key, lo, hi, section)
    if hit is not None:
        i, _m = hit
        lines[i] = rendered
    else:
        at = hi
        while at > lo and lines[at - 1].strip() == "":
            at -= 1
        lines.insert(at, rendered)

    out = "\n".join(lines)
    return out + "\n" if trailing_nl else out


def read_key(text: str, key: str, section: str = None):
    """The ACTIVE value of `key` as a string, or None (commented counts as unset)."""
    lines = text.splitlines()
    if section is None:
        lo, hi = 0, len(lines)
    else:
        span = _section_span(lines, section)
        if span is None:
            return None
        lo, hi, _indent = span
    hit = _find_key(lines, key, lo, hi, section)
    if hit is None:
        return None
    _i, m = hit
    if m.group("hash"):
        return None
    return scalar_value(m.group("rest"))


def scalar_value(raw: str):
    """Unwrap one YAML scalar: strip a trailing comment, then quotes."""
    s = raw.strip()
    if s[:1] in ("'", '"'):
        quote = s[0]
        end = s.find(quote, 1)
        if end > 0:
            return s[1:end].replace(quote * 2, quote)
        return s[1:]
    s = re.split(r"\s+#", s, maxsplit=1)[0].strip()
    return s or None


_PLAIN = re.compile(r"^[A-Za-z0-9_./@~][A-Za-z0-9_./@~+-]*$")


def yaml_scalar(value) -> str:
    """Render a Python value as a YAML scalar (lists in flow style)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(yaml_scalar(v) for v in value) + "]"
    s = str(value)
    if _PLAIN.match(s):
        return s
    return "'" + s.replace("'", "''") + "'"


# --------------------------------------------------------------------------
# Binary discovery
# --------------------------------------------------------------------------


def env_var_for(tool: str) -> str:
    return "AGDA_" + tool.split("-", 1)[1].upper().replace("-", "_") + "_BIN"


def dist_newstyle_candidates(tool: str):
    """Binaries from a sibling `cabal build` tree, newest first.

    Convenience for developing inside this repo, where the executables are not
    on $PATH. Mirrors 'AgdaMcp.State.findBin''s newest-mtime-wins rule.
    """
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pattern = os.path.join(repo, "dist-newstyle", "build", "*", "*", "*", "x",
                           tool, "build", tool, tool)
    found = [p for p in glob.glob(pattern) if os.access(p, os.X_OK)]
    return sorted(found, key=lambda p: os.stat(p).st_mtime, reverse=True)


def resolve_bin(tool: str, bin_dirs):
    """`--bin-dir` > `$AGDA_<TOOL>_BIN` > $PATH > this repo's dist-newstyle."""
    for d in bin_dirs:
        cand = os.path.join(d, tool)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    env = os.environ.get(env_var_for(tool))
    if env and os.path.isfile(env) and os.access(env, os.X_OK):
        return env
    found = shutil.which(tool)
    if found:
        return found
    built = dist_newstyle_candidates(tool)
    return built[0] if built else None


def show_defaults(binary: str) -> str:
    """`<binary> --show-defaults` (a pure path in every tool: no graph needed)."""
    proc = subprocess.run([binary, "--show-defaults"], capture_output=True,
                          text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        lines = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise Fatal("%s --show-defaults failed (exit %d): %s"
                    % (binary, proc.returncode, lines[0] if lines else "no output"))
    return proc.stdout


# --------------------------------------------------------------------------
# Project layout detection
# --------------------------------------------------------------------------


class Layout:
    """Everything the configs need to know about one Agda project."""

    def __init__(self, project, graph_dir, entries, includes, roots, notes):
        self.project = project          # absolute
        self.graph_dir = graph_dir      # project-relative (or absolute)
        self.graph = posixpath.join(graph_dir, GRAPH_FILE)
        self.entries = entries          # project-relative source files
        self.includes = includes        # project-relative directories
        self.roots = roots              # project-relative dirs to source-scan
        self.notes = notes              # human notes about the detection

    @property
    def graph_abs(self):
        return os.path.normpath(os.path.join(self.project, self.graph))


def rel(project: str, path: str) -> str:
    """Project-relative POSIX path, falling back to absolute when outside."""
    ap = os.path.abspath(path)
    try:
        r = os.path.relpath(ap, project)
    except ValueError:
        return ap.replace(os.sep, "/")
    if r.startswith(".."):
        return ap.replace(os.sep, "/")
    return r.replace(os.sep, "/")


def parse_agda_lib_includes(path: str):
    """The `include:` field of an *.agda-lib, with indented continuations."""
    values, in_field = [], False
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.split("--", 1)[0].rstrip()
            if not line:
                continue
            m = re.match(r"^([A-Za-z-]+)\s*:(.*)$", line)
            if m:
                in_field = m.group(1) == "include"
                if in_field:
                    values += m.group(2).split()
                continue
            if in_field and line[:1].isspace():
                values += line.split()
    return values


def module_name_of(rel_path: str) -> str:
    base = rel_path
    for suffix in sorted(SOURCE_SUFFIXES, key=len, reverse=True):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    return base.replace("/", ".")


def scan_sources(project: str, includes):
    """`{module name -> project-relative path}` for every source under `includes`."""
    out = {}
    for inc in includes:
        base = os.path.join(project, inc)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in SKIP_DIRS and not d.startswith(".")]
            for fn in sorted(filenames):
                if not fn.endswith(SOURCE_SUFFIXES):
                    continue
                abs_path = os.path.join(dirpath, fn)
                within = os.path.relpath(abs_path, base).replace(os.sep, "/")
                out[module_name_of(within)] = rel(project, abs_path)
    return out


IMPORT_RE = re.compile(r"^\s*(?:open\s+)?import\s+([\w'.]+)")


def scan_imported(project: str, sources):
    """Every module name that some scanned source imports."""
    imported = set()
    for path in sources.values():
        try:
            with open(os.path.join(project, path), "r", encoding="utf-8",
                      errors="replace") as fh:
                for line in fh:
                    m = IMPORT_RE.match(line)
                    if m:
                        imported.add(m.group(1))
        except OSError:
            continue
    return imported


def detect_entries(project: str, includes, notes):
    """Root modules — imported by nothing else — as project-relative paths.

    One root is the answer. Several roots resolve by preferred name
    (`Everything`, `All`, …), and beyond `MAX_AUTO_ENTRIES` the guess is worse
    than an error telling the user to pass `--entry`.
    """
    sources = scan_sources(project, includes)
    if not sources:
        raise Fatal("no .agda / .lagda sources found under %s — pass --include DIR"
                    % ", ".join(includes))
    roots = sorted(m for m in sources if m not in scan_imported(project, sources))
    if not roots:
        # Every module is imported by another: an import cycle, or a library
        # whose modules cross-reference. Fall back to a preferred name.
        roots = sorted(sources)
        notes.append("no unimported root module (cyclic imports?) — "
                     "considered every module as a candidate")
    if len(roots) == 1:
        return [sources[roots[0]]]
    for want in ENTRY_PREFERENCE:
        hits = [m for m in roots if m.split(".")[-1] == want]
        if len(hits) == 1:
            notes.append("picked %s as the entry (%d root modules found; "
                         "pass --entry to override)" % (hits[0], len(roots)))
            return [sources[hits[0]]]
    if len(roots) > MAX_AUTO_ENTRIES:
        shown = ", ".join(roots[:10]) + (", …" if len(roots) > 10 else "")
        raise Fatal("found %d independent root modules (%s).\n"
                    "  Pass --entry FILE (repeatable) to choose, or add an "
                    "Everything.agda importing them." % (len(roots), shown))
    notes.append("multi-entry: %d root modules, all wired as agda-explore "
                 "entries (it unions their closures)" % len(roots))
    return [sources[m] for m in roots]


def detect_layout(args) -> Layout:
    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        raise Fatal("not a directory: %s" % args.project)
    if not os.access(project, os.W_OK):
        raise Fatal("project directory is not writable: %s" % project)

    notes = []
    if args.include:
        includes = [rel(project, os.path.join(project, i)) for i in args.include]
    else:
        libs = sorted(glob.glob(os.path.join(project, "*.agda-lib")))
        includes = []
        if libs:
            includes = [i for i in parse_agda_lib_includes(libs[0])
                        if os.path.isdir(os.path.join(project, i))]
            if includes:
                notes.append("include dirs from %s" % rel(project, libs[0]))
        if not includes:
            includes = [d for d in ("src", "lib")
                        if os.path.isdir(os.path.join(project, d))] or ["."]
            notes.append("include dirs guessed: %s" % ", ".join(includes))

    entries = ([rel(project, os.path.join(project, e)) for e in args.entry]
               if args.entry else detect_entries(project, includes, notes))
    for e in entries:
        if not os.path.isfile(os.path.join(project, e)):
            raise Fatal("entry file not found: %s" % e)

    graph_dir = rel(project, os.path.join(project, args.graph_dir))
    return Layout(project, graph_dir, entries, includes, includes, notes)


# --------------------------------------------------------------------------
# Per-tool config content
# --------------------------------------------------------------------------


def edits_for(tool: str, L: Layout):
    """`(note lines, [(section, key, value)])` — the overlay for one tool."""
    if tool == "agda-deps":
        # The producer recipe. Mirrors 'AgdaMcp.State.buildBaseArgs' (the flags
        # agda-explore passes when it regenerates the graph itself), so a hand
        # build and a daemon rebuild agree on the graph's shape.
        note = [
            "This is the RECIPE for the shared graph, mirroring the flags",
            "agda-explore passes when it regenerates the graph itself:",
            "  agda-deps --config .agda-deps.yml %s" % L.entries[0],
            "writes %s." % L.graph,
        ]
        if len(L.entries) > 1:
            note += [
                "This project has %d entries, and one agda-deps run covers ONE"
                % len(L.entries),
                "(each rewrites %s). To get the union, let" % L.graph,
                "agda-explore build it: `agda-explore query status`.",
            ]
        return (note, [
            (None, "out-dir", L.graph_dir),
            (None, "format", "json"),
            (None, "json-mode", "expanded"),
            (None, "with-signatures", True),
            (None, "with-term-hashes", True),
            (None, "min-term-depth", 3),
            (None, "no-externals", True),
            (None, "keep-going", True),
        ])
    if tool == "agda-unused":
        return ([
            "Reads the shared graph; `roots:` are the directories source-scanned",
            "for findings. Run it with no arguments.",
        ], [
            (None, "graph", L.graph),
            (None, "roots", L.roots),
        ])
    if tool == "agda-optimization":
        return ([
            "`global: graph:` is the input graph, so every subcommand runs",
            "without a path: `agda-optimization motif`. A positional",
            "<graph.json> or --graph FILE still wins over it.",
        ], [
            ("global", "graph", L.graph),
        ])
    if tool == "agda-explore":
        return ([
            "LIVE mode on purpose: `out-dir:` (not `graph:`) — agda-explore's",
            "graph path is <out-dir>/%s, so it REGENERATES the shared graph" % GRAPH_FILE,
            "via agda-deps and the other tools read what it last published.",
            "Setting `graph:` instead would pin a prebuilt graph and disable",
            "rebuilds + the watcher.",
        ], [
            (None, "entries", L.entries),
            (None, "include", L.includes),
            (None, "out-dir", L.graph_dir),
        ])
    if tool == "agda-auto":
        return ([
            "Reads the shared graph for lemma-hint ranking; needs `agda` on",
            "$PATH to fill holes.",
        ], [
            (None, "graph", L.graph),
            (None, "include-paths", L.includes),
        ])
    if tool == "agda-goals":
        return ([
            "Consumes NO graph: it drives `agda --interaction-json` over",
            "`roots:` (the graph entry points, so the scope matches).",
        ], [
            (None, "roots", L.entries),
            (None, "include-paths", L.includes),
        ])
    raise Fatal("unknown tool: %s" % tool)


def render_config(tool: str, defaults: str, L: Layout) -> str:
    """The tool's `--show-defaults` payload, overlaid + given a provenance header.

    Deterministic (no timestamps), so re-running produces byte-identical output
    and an unchanged file is reported as such instead of rewritten.
    """
    notes, edits = edits_for(tool, L)
    header = ["# Generated by scripts/zero-config.py from `%s --show-defaults`."
              % tool,
              "# Shared graph: %s — every tool in this project reads that one file."
              % L.graph]
    header += ["# " + n for n in notes]
    header += ["# Hand edits survive a plain re-run; --force overwrites them.", ""]
    text = defaults
    for section, key, value in edits:
        text = set_key(text, key, value, section)
    return "\n".join(header) + "\n" + text


def config_graph_of(tool: str, text: str):
    """Where `tool` will look for the shared graph, read back from its config."""
    if tool == "agda-optimization":
        return read_key(text, "graph", section="global")
    if tool in ("agda-unused", "agda-auto"):
        # `json:` is agda-unused's legacy alias for `graph:`.
        return read_key(text, "graph") or read_key(text, "json")
    if tool == "agda-explore":
        pinned = read_key(text, "graph")
        if pinned:
            return pinned
        out_dir = read_key(text, "out-dir")
        return posixpath.join(out_dir, GRAPH_FILE) if out_dir else None
    return None


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------


def check(label, status, detail, hint=None):
    return {"check": label, "status": status, "detail": detail, "hint": hint}


def doctor_checks(explore_bin: str, project: str):
    """Fold `agda-explore doctor --json` into our report.

    Reuses the daemon's own preflight (graph decode, node-key version, the three
    capability probes, agda-deps / agda resolution, out-dir writability) instead
    of reimplementing it. Run from the project so doctor discovers the
    `.agda-explore.yml` we just wrote; `--enable-interact` is passed on the CLI
    only, to make it probe `agda` (needed by agda-goals / agda-auto) without
    enabling the write bridge in the config.
    """
    keep = {"mode", "graph", "node-key version", "signatures", "edge provenance",
            "subterm hashes", "agda-deps", "agda", "out-dir"}
    try:
        proc = subprocess.run([explore_bin, "doctor", "--json", "--enable-interact"],
                              cwd=project, capture_output=True, text=True,
                              timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, [check("doctor", "warn", "could not run agda-explore doctor: %s" % exc)]
    payload = None
    for line in reversed((proc.stdout or "").strip().splitlines()):
        try:
            payload = json.loads(line)
            break
        except ValueError:
            continue
    if not isinstance(payload, dict) or "checks" not in payload:
        return None, [check("doctor", "warn",
                            "agda-explore doctor produced no JSON envelope (exit %d)"
                            % proc.returncode)]
    out = []
    for c in payload["checks"]:
        if c.get("check") not in keep:
            continue
        status = c.get("status", "warn")
        # A missing external binary fails `doctor` but is only a warning here:
        # this script writes configs and never builds, so a machine without
        # `agda-deps` / `agda` can still be configured correctly (it just can't
        # run the build command we print). Our ✗ bucket is reserved for what we
        # do assert — config disagreement and an undecodable graph. `doctor`
        # itself stays the authority on the toolchain.
        if c.get("check") in ("agda", "agda-deps") and status == "fail":
            status = "warn"
        out.append(check(c.get("check"), status, c.get("detail", ""), c.get("hint")))
    return payload, out


def local_graph_checks(graph_abs: str, graph_rel: str):
    """Graph verification without agda-explore: decode + capability probes."""
    if not os.path.isfile(graph_abs):
        return [check("graph", "warn", "not built yet: %s" % graph_rel,
                      "build it with the agda-deps command below")]
    size = os.path.getsize(graph_abs)
    if size > 32 * 1024 * 1024:
        with open(graph_abs, "r", encoding="utf-8", errors="replace") as fh:
            head = fh.read(8192)
        ok = '"mode":"expanded"' in head.replace(" ", "") \
            and '"v":2' in head.replace(" ", "")
        return [check("graph", "ok" if ok else "warn",
                      "%s (%.1f MiB; header-only check)" % (graph_rel, size / 1048576.0),
                      None if ok else "expected v2 expanded JSON — rebuild with "
                                      "--json-mode=expanded")]
    try:
        with open(graph_abs, "r", encoding="utf-8", errors="replace") as fh:
            g = json.load(fh)
    except ValueError as exc:
        return [check("graph", "fail", "%s: %s" % (graph_rel, exc),
                      "regenerate with agda-deps --json-mode=expanded")]
    out = []
    mode, v = g.get("mode"), g.get("v")
    if mode == "expanded" and v == 2:
        out.append(check("graph", "ok", "%s (%d defs, %d modules)"
                         % (graph_rel, len(g.get("definitions") or []),
                            len(g.get("modules") or []))))
    else:
        out.append(check("graph", "fail",
                         "%s: v=%r mode=%r (want v=2, mode=expanded)"
                         % (graph_rel, v, mode),
                         "rebuild with --format=json --json-mode=expanded"))
    caps = [("signatures", any(d.get("type") for d in (g.get("definitions") or [])),
             "type_of / find_lemma report elaborated types",
             "rebuild with --with-signatures"),
            ("edge provenance", bool(g.get("definitionEdgesProvenance")),
             "premise-select / silhouette available",
             "rebuild with a provenance-emitting agda-deps"),
            ("subterm hashes", bool(g.get("definitionSubtermHashes")),
             "similar_bodies / term-cluster available",
             "rebuild with --with-term-hashes")]
    for label, present, ok_detail, hint in caps:
        out.append(check(label, "ok", ok_detail) if present
                   else check(label, "warn", "absent in this graph", hint))
    return out


def agreement_checks(L: Layout, files, project: str):
    """Every graph consumer must resolve to the SAME graph file.

    Covers the configs on disk, not just the ones this run wrote: a `--skip`ped
    or hand-edited tool that reads a different graph breaks the invariant just
    as loudly.
    """
    seen, out = {}, []
    texts = {f["tool"]: f["text_on_disk"] for f in files if f["text_on_disk"]}
    for tool in GRAPH_CONSUMERS:
        text = texts.get(tool)
        if text is None:
            path = os.path.join(project, "." + tool + ".yml")
            if not os.path.isfile(path):
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        named = config_graph_of(tool, text)
        if named is None:
            out.append(check("graph ref: %s" % tool, "fail",
                             "config names no graph", "re-run with --force"))
            continue
        seen[tool] = os.path.normpath(os.path.join(project, named))
    if not seen:
        return out + [check("graph agreement", "skip", "no graph consumer configured")]
    want = L.graph_abs
    off = {t: p for t, p in seen.items() if p != want}
    if off:
        detail = "; ".join("%s -> %s" % (t, rel(project, p)) for t, p in sorted(off.items()))
        out.append(check("graph agreement", "fail",
                         "%d of %d configs read a different graph (%s)"
                         % (len(off), len(seen), detail),
                         "re-run with --force to repoint them at %s" % L.graph))
    else:
        out.append(check("graph agreement", "ok",
                         "%s read %s" % (" / ".join(sorted(seen)), L.graph)))
    return out


def deps_config_checks(deps_bin, project, L, wrote_deps_config):
    """The producer writes where the consumers read, and its config is valid."""
    out = []
    path = os.path.join(project, ".agda-deps.yml")
    if not os.path.isfile(path):
        return [check("producer target", "skip", "no .agda-deps.yml")]
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    out_dir = read_key(text, "out-dir")
    fmt, mode = read_key(text, "format"), read_key(text, "json-mode")
    target = os.path.normpath(os.path.join(project, out_dir or ".", GRAPH_FILE))
    if out_dir and target == L.graph_abs and fmt == "json" and mode == "expanded":
        out.append(check("producer target", "ok",
                         ".agda-deps.yml writes %s (json, expanded)" % L.graph))
    else:
        out.append(check("producer target", "fail",
                         ".agda-deps.yml writes %s (format=%s json-mode=%s)"
                         % (rel(project, target), fmt, mode),
                         "re-run with --force to repoint the producer"))
    if deps_bin and wrote_deps_config:
        proc = subprocess.run([deps_bin, "doctor", "--config", ".agda-deps.yml"],
                              cwd=project, capture_output=True, text=True)
        first = (proc.stdout or proc.stderr or "").strip().splitlines()
        out.append(check("producer config", "ok" if proc.returncode == 0 else "warn",
                         first[-1] if first else "agda-deps doctor exit %d" % proc.returncode,
                         None if proc.returncode == 0 else "run: agda-deps doctor --config .agda-deps.yml"))
    return out


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def next_commands(L: Layout, files):
    """The commands that build the graph and then use it."""
    cmds = []
    # `text_on_disk` is empty only when there is no .agda-deps.yml and no
    # agda-deps binary to generate one — then spell the flags out in full.
    have_deps_config = any(f["tool"] == "agda-deps" and f["text_on_disk"]
                           for f in files)
    if len(L.entries) == 1:
        build = ("agda-deps --config .agda-deps.yml %s" % L.entries[0]
                 if have_deps_config else
                 "agda-deps --format=json --json-mode=expanded --keep-going "
                 "--with-signatures --with-term-hashes --no-externals "
                 "-o %s %s" % (L.graph_dir, L.entries[0]))
        cmds.append((build, "build the shared graph"))
    else:
        cmds.append(("agda-explore query status",
                     "build + union all %d entries into %s (a single agda-deps "
                     "run covers one entry only)" % (len(L.entries), L.graph)))
    cmds.append(("agda-optimization motif", "any subcommand, no path needed"))
    cmds.append(("agda-unused", "graph + roots from the config"))
    cmds.append(("agda-explore doctor", "re-check the environment any time"))
    return cmds


def emit_human(L, files, checks, cmds, project):
    print("zero-config")
    print("")
    print("  project    %s" % project)
    print("  graph      %s" % L.graph)
    print("  entry      %s" % ", ".join(L.entries))
    print("  include    %s" % ", ".join(L.includes))
    for n in L.notes:
        print("  note       %s" % n)
    print("")
    print("  files")
    for f in files:
        print("    %-24s %s" % (f["path"], f["action"]))
    print("")
    print("  checks")
    for c in checks:
        print("    %s %-18s %s" % (STATUS_SYM.get(c["status"], "?"),
                                   c["check"], c["detail"]))
        if c["hint"] and c["status"] in ("warn", "fail"):
            print("        → %s" % c["hint"])
    print("")
    print("  next")
    for cmd, why in cmds:
        print("    %s" % cmd)
        print("        # %s" % why)
    print("")
    bad = sum(1 for c in checks if c["status"] == "fail")
    warn = sum(1 for c in checks if c["status"] == "warn")
    print("OK%s" % (" (%d warning(s))" % warn if warn else "") if bad == 0
          else "%d problem(s) found — see the ✗ lines above." % bad)


def emit_json(L, files, checks, cmds, project, ok):
    print(json.dumps({
        "ok": ok,
        "project": project,
        "graph": L.graph,
        "entries": L.entries,
        "includes": L.includes,
        "notes": L.notes,
        "files": [{k: f[k] for k in ("tool", "path", "action")} for f in files],
        "checks": checks,
        "next": [{"command": c, "why": w} for c, w in cmds],
    }, indent=2, sort_keys=True))


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="zero-config.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Generate a config file for every agda-graph-explorer tool, "
                    "all pointed at one shared agda-deps graph.",
        epilog="Exit codes: 0 = configs current, no failing check; "
               "1 = a check failed (configs disagree, or an undecodable graph); "
               "2 = usage / environment error.")
    p.add_argument("--project", default=".", metavar="DIR",
                   help="Agda project root; configs are written here (default: .)")
    p.add_argument("--entry", action="append", default=[], metavar="FILE",
                   help="entry module for the graph (repeatable; default: detected)")
    p.add_argument("--include", action="append", default=[], metavar="DIR",
                   help="Agda include dir (repeatable; default: from *.agda-lib)")
    p.add_argument("--graph-dir", default=DEFAULT_GRAPH_DIR, metavar="DIR",
                   help="directory holding the shared graph, which is always "
                        "DIR/%s (default: %s)" % (GRAPH_FILE, DEFAULT_GRAPH_DIR))
    p.add_argument("--bin-dir", action="append", default=[], metavar="DIR",
                   help="look for the tool binaries here first (repeatable)")
    p.add_argument("--only", action="append", default=[], metavar="TOOL",
                   help="only these tools (repeatable): " + ", ".join(TOOLS))
    p.add_argument("--skip", action="append", default=[], metavar="TOOL",
                   help="skip these tools (repeatable)")
    p.add_argument("--force", action="store_true",
                   help="overwrite existing config files")
    p.add_argument("--dry-run", action="store_true",
                   help="write nothing; report what would be written")
    p.add_argument("--json", action="store_true",
                   help="machine-readable envelope instead of the report")
    return p.parse_args(argv)


def selected_tools(args):
    for t in args.only + args.skip:
        if t not in TOOLS:
            raise Fatal("unknown tool: %s (want one of %s)" % (t, ", ".join(TOOLS)))
    tools = [t for t in TOOLS if not args.only or t in args.only]
    return [t for t in tools if t not in args.skip]


def write_configs(tools, args, L, bins):
    """Render + write each config; return one record per tool."""
    files = []
    for tool in tools:
        path = os.path.join(L.project, "." + tool + ".yml")
        record = {"tool": tool, "path": rel(L.project, path), "action": "",
                  "text_on_disk": ""}
        if not bins.get(tool):
            record["action"] = "missing binary"
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    record["text_on_disk"] = fh.read()
                record["action"] = "kept (binary not found — cannot regenerate)"
            files.append(record)
            continue
        wanted = render_config(tool, show_defaults(bins[tool]), L)
        existing = None
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                existing = fh.read()
        if existing == wanted:
            record["action"] = "current"
            record["text_on_disk"] = existing
        elif existing is not None and not args.force:
            record["action"] = "kept (differs — pass --force to overwrite)"
            record["text_on_disk"] = existing
        elif args.dry_run:
            record["action"] = "would %s" % ("overwrite" if existing else "write")
            record["text_on_disk"] = wanted
        else:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(wanted)
            record["action"] = "overwritten" if existing else "written"
            record["text_on_disk"] = wanted
        files.append(record)
    return files


def main(argv):
    args = parse_args(argv)
    tools = selected_tools(args)
    if not tools:
        raise Fatal("every tool was skipped — nothing to do")

    bins = {t: resolve_bin(t, args.bin_dir) for t in tools}
    if not any(bins.values()):
        raise Fatal("none of %s found on --bin-dir / $AGDA_*_BIN / $PATH.\n"
                    "  Build them (cabal build) or install them, then re-run."
                    % ", ".join(tools))

    L = detect_layout(args)
    files = write_configs(tools, args, L, bins)

    checks = [check("binaries", "ok" if all(bins.values()) else "warn",
                    ", ".join("%s%s" % (t, "" if bins[t] else " (not found)")
                              for t in tools),
                    None if all(bins.values())
                    else "install the missing tool(s) or pass --bin-dir")]

    # Graph verification: delegate to `agda-explore doctor` when we can (it
    # decodes the graph the daemon would read and probes every capability),
    # else do the same checks locally.
    used_doctor = False
    if bins.get("agda-explore") and not args.dry_run:
        payload, dchecks = doctor_checks(bins["agda-explore"], L.project)
        used_doctor = payload is not None
        checks += dchecks
    if not used_doctor:
        checks += local_graph_checks(L.graph_abs, L.graph)
        if bins.get("agda-explore") and args.dry_run:
            checks.append(check("doctor", "skip", "--dry-run: not run"))

    checks += agreement_checks(L, files, L.project)
    checks += deps_config_checks(bins.get("agda-deps"), L.project, L,
                                any(f["tool"] == "agda-deps" and
                                    f["action"] in ("written", "overwritten", "current")
                                    for f in files))

    cmds = next_commands(L, files)
    ok = not any(c["status"] == "fail" for c in checks)
    if args.json:
        emit_json(L, files, checks, cmds, L.project, ok)
    else:
        emit_human(L, files, checks, cmds, L.project)
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fatal as exc:
        sys.stderr.write("zero-config: %s\n" % exc)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
