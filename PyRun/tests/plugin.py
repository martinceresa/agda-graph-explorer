"""Validate the Claude Code plugin under plugin/.

Covers: the .mcp.json server config, the .claude-plugin/plugin.json manifest,
the launcher script (syntax, shellcheck if present, the --version success path,
and the binary-not-found diagnostic path), and the YAML frontmatter of the
bundled skill + agents.
"""
from __future__ import annotations

import shutil
from harness import Case

# A tiny frontmatter validator (no PyYAML dependency): checks the file has a
# `---`-delimited frontmatter block whose top-level `key:` lines include all
# the required keys passed as argv.
FM_CHECK = r"""
import sys
path, req = sys.argv[1], sys.argv[2:]
text = open(path, encoding='utf-8').read()
if not text.lstrip().startswith('---'):
    print('no frontmatter block'); sys.exit(1)
body = text.lstrip()[3:]
end = body.find('\n---')
if end < 0:
    print('unterminated frontmatter'); sys.exit(1)
fm = body[:end]
keys = set()
for line in fm.splitlines():
    if line and not line[0].isspace() and ':' in line:
        keys.add(line.split(':', 1)[0].strip())
print('frontmatter keys:', sorted(keys))
missing = [k for k in req if k not in keys]
if missing:
    print('MISSING:', missing); sys.exit(1)
print('ok')
"""

JSON_CHECK = r"""
import json, sys
path, req = sys.argv[1], sys.argv[2:]
d = json.load(open(path, encoding='utf-8'))
print('top-level keys:', sorted(d) if isinstance(d, dict) else type(d).__name__)
missing = [k for k in req if k not in d]
if missing:
    print('MISSING:', missing); sys.exit(1)
print('ok')
"""

MCP_REFS_LAUNCHER = r"""
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
cmd = d['mcpServers']['agda-explore']['command']
print('command:', cmd)
sys.exit(0 if cmd.endswith('agda-explore-launch.sh') else 1)
"""


def cases(ctx):
    plug = ctx.repo / "plugin"
    mcp_json   = plug / ".mcp.json"
    manifest   = plug / ".claude-plugin" / "plugin.json"
    launcher   = plug / "bin" / "agda-explore-launch.sh"
    skill      = plug / "skills" / "agda-explore" / "SKILL.md"
    agents     = sorted((plug / "agents").glob("*.md"))
    exp        = str(ctx.bin("explore"))
    corpus     = str(ctx.corpus)

    cs = []

    def py(name, script, args, note, checks=None, expect_error=False, env=None, cmd0=None):
        return Case(area="plugin", name=name,
                    cmd=(cmd0 or ["python3", "-c", script]) + args,
                    note=note, env=env, expect_error=expect_error,
                    checks=checks if checks is not None
                           else [{"type": "exit_eq", "v": 0}, {"type": "no_crash"}])

    # --- JSON config + manifest -------------------------------------------
    cs.append(py("mcp-json-valid", JSON_CHECK, [str(mcp_json), "mcpServers"],
                 "plugin/.mcp.json is valid JSON with mcpServers"))
    cs.append(py("mcp-refs-launcher", MCP_REFS_LAUNCHER, [str(mcp_json)],
                 ".mcp.json command points at agda-explore-launch.sh"))
    cs.append(py("manifest-valid", JSON_CHECK, [str(manifest), "name", "version", "description"],
                 ".claude-plugin/plugin.json valid + has name/version/description"))

    # --- launcher script ---------------------------------------------------
    cs.append(Case(area="plugin", name="launcher-syntax",
                   cmd=["bash", "-n", str(launcher)], note="launcher passes `bash -n` syntax check",
                   checks=[{"type": "exit_eq", "v": 0}, {"type": "no_crash"}]))
    if shutil.which("shellcheck"):
        cs.append(Case(area="plugin", name="launcher-shellcheck",
                       cmd=["shellcheck", "-S", "warning", str(launcher)],
                       note="shellcheck the launcher (warnings+)",
                       checks=[{"type": "exit_in", "v": [0, 1]}, {"type": "no_crash"}]))

    # launcher --version success path: pin AGDA_EXPLORE_BIN at the real binary,
    # launcher execs `agda-explore --project <proj> --version`.
    cs.append(Case(area="plugin", name="launcher-version-ok",
                   cmd=["bash", str(launcher), "--version"],
                   env={"AGDA_EXPLORE_BIN": exp, "CLAUDE_PROJECT_DIR": corpus},
                   note="launcher resolves + execs agda-explore --version",
                   timeout=60,
                   checks=[{"type": "exit_eq", "v": 0}, {"type": "no_crash"},
                           {"type": "stdout_contains", "v": "agda-explore"}]))

    # launcher binary-not-found diagnostic: copy the launcher into an isolated
    # temp dir (so its script_dir/../.. has no dist-newstyle), run with a PATH
    # that lacks agda-explore and no AGDA_EXPLORE_BIN -> exit 127 + diagnostic.
    # Nest the launcher deep + run from an empty cwd, so the launcher's own
    # `find $script_dir/../..` and `$PWD` roots stay inside an empty sandbox
    # (a shallow temp dir would make $script_dir/../.. == / and scan the whole
    # filesystem — a test artifact, not launcher behaviour).
    isolated = (
        'base=$(mktemp -d); mkdir -p "$base/p/bin" "$base/empty"; '
        'cp "$1" "$base/p/bin/agda-explore-launch.sh"; cd "$base/empty"; '
        'env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PROJECT_DIR="$base/empty" '
        'bash "$base/p/bin/agda-explore-launch.sh" --version; rc=$?; '
        'cd /; rm -rf "$base"; exit $rc'
    )
    cs.append(Case(area="plugin", name="launcher-notfound-diagnostic",
                   cmd=["bash", "-c", isolated, "_", str(launcher)],
                   note="launcher with no resolvable binary -> clean diagnostic + exit 127",
                   expect_error=True,
                   checks=[{"type": "exit_eq", "v": 127},
                           {"type": "stderr_contains", "v": "could not find"},
                           {"type": "stderr_contains", "v": "AGDA_EXPLORE_BIN"}]))

    # --- skill + agents frontmatter ---------------------------------------
    if skill.exists():
        cs.append(py("skill-frontmatter", FM_CHECK, [str(skill), "name", "description"],
                     "skills/agda-explore/SKILL.md frontmatter has name + description"))
    for a in agents:
        cs.append(py(f"agent-frontmatter.{a.stem}", FM_CHECK, [str(a), "name", "description"],
                     f"agents/{a.name} frontmatter has name + description"))

    return cs
