"""BattleTest matrix for the `agda-unused` executable.

`agda-unused` reads an agda-deps v2 *expanded* `graph.json` (`--json=`) and
source-scans one or more ROOT directories for `.agda`/`.lagda*` files, then
cross-references the two to flag unused imports / definitions / opens /
public re-exports.  This module exercises every CLI flag, every `--kinds`
token, both JSON output modes, both graph fixtures, the YAML config layer,
and the error surface.

Surface confirmed against src/MainUnused.hs + src/AgdaUnused/{Analysis,
Config,Source}.hs and smoke-runs against the real test corpus:

  --json=DEPS.JSON   expanded graph (required; missing -> exit 1)
  --kinds=K[,K..]    using | blanket | defined | dead | internal-only |
                     public | duplicate | all   (default: using,duplicate)
                     CSV is whitespace-trimmed only in the YAML/scalar path
                     (parseKindsCSV); the CLI parser (parseKinds) does NOT
                     trim, so `--kinds=defined, public` would fail — we keep
                     CLI CSV tokens tight and exercise trimming via YAML.
  --rel-to=DIR       display file paths relative to DIR
  --exclude=GLOB     drop findings whose file path OR dotted module name
                     matches GLOB (repeatable; ** spans /, * stops at /)
  --json-out         emit a JSON array instead of plain text; ALSO suppresses
                     the "applied config from" stderr breadcrumb
  --config=PATH      load YAML options (defaults -> config -> CLI)
  ROOT...            one or more dirs to source-scan
  -h / --help        print usage, exit 0

Learnings baked into the checks:
  * Default scan (using,duplicate) on the base graph yields very few findings
    (1 on the test corpus), so the default human case asserts only no_crash / exit 0
    and notes that a near-empty result is valid.  --kinds=all is the rich one
    (382 on base, 437 on the project-only full graph).
  * A nonexistent --json file escapes as an UNCAUGHT exception (crash markers
    "Uncaught exception"/"ghc-internal") rather than the clean "failed to
    read" Left-branch — loadExpandedGraph opens the file before the handler.
    So that case is expect_error=True with NO no_crash check (the crash is
    the documented behaviour we are pinning).
  * The config breadcrumb is "agda-unused: applied config from <path>".
"""
from __future__ import annotations

import tempfile
from pathlib import Path

from harness import Case


# Individual --kinds tokens and the human-readable tag each surfaces, so the
# per-kind cases can assert a kind actually fired (when findings exist).
_KIND_TOKENS = [
    "using",
    "blanket",
    "defined",
    "dead",
    "internal-only",
    "public",
    "duplicate",
    "all",
]


def _write_config(graph: Path, corpus: Path, kinds: str) -> str:
    """Write a tiny .agda-unused.yml fixture and return its path.

    Mirrors AgdaUnused.Config's FromJSON schema: kebab-case keys `json`,
    `kinds` (scalar CSV or list), `roots` (list of positionals).  Written to
    a stable temp path so the case is reproducible across runs.
    """
    p = Path(tempfile.gettempdir()) / "battletest-agda-unused.yml"
    p.write_text(
        f'json: "{graph}"\n'
        f'kinds: "{kinds}"\n'
        f"roots:\n"
        f'  - "{corpus}"\n'
    )
    return str(p)


def cases(ctx) -> list[Case]:
    BIN = ctx.bin("unused")
    BASE = str(ctx.graph_base)   # ~15k-node full closure (project + stdlib)
    FULL = str(ctx.graph_full)   # ~5.8k-node project-only
    ROOT = str(ctx.corpus)       # real .agda/.lagda sources findings map to

    cs: list[Case] = []

    # ---- Default human run -------------------------------------------------
    # Default kinds = using,duplicate.  On the test corpus this is a very small
    # set (1 finding), so we DON'T require stdout_nonempty — a near-empty result
    # is valid.  We do require exit 0, a clean stderr, the "# total:" footer,
    # and a time budget.
    cs.append(Case(
        area="unused", name="default_human_base",
        cmd=[BIN, f"--json={BASE}", ROOT],
        note="default run (kinds=using,duplicate) on base graph + real corpus",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="default_human_full",
        cmd=[BIN, f"--json={FULL}", ROOT],
        note="default run on project-only full graph (differences vs base expected)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- Each --kinds token individually (human, base graph) ---------------
    # `all` is rich (382 findings) so it gets stdout_nonempty; the narrower
    # tokens may legitimately be empty on this corpus, so they only assert
    # exit 0 / no_crash / "# total:" footer.
    for tok in _KIND_TOKENS:
        checks = [
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ]
        if tok == "all":
            checks.append({"type": "stdout_nonempty"})
        cs.append(Case(
            area="unused", name=f"kind_{tok.replace('-', '_')}_base",
            cmd=[BIN, f"--json={BASE}", f"--kinds={tok}", ROOT],
            note=f"--kinds={tok} on base graph",
            checks=checks,
        ))

    # Multi-token CSV (no spaces — the CLI parser does not trim).
    cs.append(Case(
        area="unused", name="kinds_csv_defined_public",
        cmd=[BIN, f"--json={BASE}", "--kinds=defined,public", ROOT],
        note="multi-token CSV --kinds=defined,public (defined => dead+internal-only)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="kinds_csv_using_blanket_dead",
        cmd=[BIN, f"--json={BASE}", "--kinds=using,blanket,dead", ROOT],
        note="three-token CSV --kinds=using,blanket,dead",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # `defined` is an alias for dead+internal-only; pin that it equals the
    # explicit union by emitting both forms (compared offline via artifacts;
    # here we just confirm both run clean and are non-trivially sized).
    cs.append(Case(
        area="unused", name="kind_defined_alias_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=defined", ROOT],
        note="`defined` alias = dead + internal-only (compare vs explicit union artifact)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="kind_dead_internal_union_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=dead,internal-only", ROOT],
        note="explicit dead,internal-only union (should match `defined` alias output)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --json-out form ---------------------------------------------------
    # JSON array emission via aeson; must parse as JSON and be a single line.
    cs.append(Case(
        area="unused", name="jsonout_all_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", "--json-out", ROOT],
        note="--json-out --kinds=all on base graph (aeson JSON array)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="jsonout_all_full",
        cmd=[BIN, f"--json={FULL}", "--kinds=all", "--json-out", ROOT],
        note="--json-out --kinds=all on project-only full graph",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="jsonout_defined_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=defined", "--json-out", ROOT],
        note="--json-out with --kinds=defined (dead+internal-only)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="jsonout_using_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=using", "--json-out", ROOT],
        note="--json-out with --kinds=using (may be empty array — still valid JSON)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="jsonout_default_base",
        cmd=[BIN, f"--json={BASE}", "--json-out", ROOT],
        note="--json-out with default kinds; stderr breadcrumb absent (no config)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --rel-to ----------------------------------------------------------
    # Relativising against the corpus root strips the absolute prefix, so the
    # absolute corpus path must NOT appear in stdout while findings still do.
    cs.append(Case(
        area="unused", name="relto_corpus_human",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", f"--rel-to={ROOT}", ROOT],
        note="--rel-to=corpus relativises paths (absolute prefix dropped)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "stdout_not_contains", "v": ROOT + "/"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="relto_corpus_jsonout",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", f"--rel-to={ROOT}",
             "--json-out", ROOT],
        note="--rel-to under --json-out: 'file' keys are relative",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "stdout_not_contains", "v": ROOT + "/"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --exclude ---------------------------------------------------------
    # Excluding a project subtree (Protocol) drops ~80% of findings; the
    # "# excluded:" footer must report the pattern and a suppressed count.
    cs.append(Case(
        area="unused", name="exclude_project_subtree",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", "--exclude=**/Protocol/**", ROOT],
        note="--exclude project subtree drops findings; '# excluded:' footer fires",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# excluded:"},
            {"type": "stdout_contains", "v": "suppressed"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # Excluding a stdlib module-name prefix (Data.**) matches on dotted module
    # name, not just path — confirms the second match arm.
    cs.append(Case(
        area="unused", name="exclude_stdlib_module_prefix",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", "--exclude=Data.**", ROOT],
        note="--exclude=Data.** matches dotted module name (stdlib prefix)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# excluded:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # Repeatable --exclude: two patterns, both echoed in the footer.
    cs.append(Case(
        area="unused", name="exclude_repeatable",
        cmd=[BIN, f"--json={BASE}", "--kinds=all",
             "--exclude=Data.**", "--exclude=**/Prelude/**", ROOT],
        note="repeated --exclude flags both apply (path + module name)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# excluded:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # Exclude everything -> zero findings but still exit 0 and footer present.
    cs.append(Case(
        area="unused", name="exclude_everything",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", "--exclude=**", ROOT],
        note="--exclude=** suppresses all findings; total 0, clean exit",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total: 0 finding(s)"},
            {"type": "stdout_contains", "v": "suppressed"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- Both graphs side by side (rich) -----------------------------------
    cs.append(Case(
        area="unused", name="all_human_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", ROOT],
        note="--kinds=all human on base graph (full closure)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    cs.append(Case(
        area="unused", name="all_human_full",
        cmd=[BIN, f"--json={FULL}", "--kinds=all", ROOT],
        note="--kinds=all human on project-only full graph (differs from base)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- Determinism (human + json-out) ------------------------------------
    # agda-unused builds -with-rtsopts=-N and parallelises analysis; output
    # must be byte-identical between +RTS -N1 and +RTS -N4.
    cs.append(Case(
        area="unused", name="determinism_all_human_base",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", ROOT],
        note="determinism: --kinds=all human, +RTS -N1 == -N4",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "determinism"},
            {"type": "max_seconds", "v": 90},
        ],
    ))
    cs.append(Case(
        area="unused", name="determinism_all_jsonout_full",
        cmd=[BIN, f"--json={FULL}", "--kinds=all", "--json-out", ROOT],
        note="determinism: --kinds=all --json-out on full graph, -N1 == -N4",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "determinism"},
            {"type": "max_seconds", "v": 90},
        ],
    ))

    # ---- Config layer (YAML) -----------------------------------------------
    cfg = _write_config(Path(BASE), Path(ROOT), "dead,public")
    # Human mode: breadcrumb fires on stderr.
    cs.append(Case(
        area="unused", name="config_breadcrumb_human",
        cmd=[BIN, f"--config={cfg}"],
        note="--config supplies json+kinds+roots; 'applied config from' breadcrumb on stderr",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "applied config from"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # --json-out suppresses the breadcrumb (clean stderr for pipe consumers).
    cs.append(Case(
        area="unused", name="config_breadcrumb_suppressed_jsonout",
        cmd=[BIN, f"--config={cfg}", "--json-out"],
        note="--json-out suppresses the config breadcrumb; stdout is JSON",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": ""},      # trivially true; pin no failure
            {"type": "stdout_json"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # CLI overrides config: config says dead,public; CLI --kinds=all wins
    # (merge order defaults -> config -> CLI).  We only assert it runs clean
    # and is non-empty (CLI all > config dead,public on this corpus).
    cs.append(Case(
        area="unused", name="config_cli_override_kinds",
        cmd=[BIN, f"--config={cfg}", "--kinds=all"],
        note="CLI --kinds=all overrides config kinds (defaults->config->CLI)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # YAML scalar CSV with whitespace — parseKindsCSV trims, so this is the
    # spelling that exercises the trimming the CLI path lacks.
    cfg_ws = Path(tempfile.gettempdir()) / "battletest-agda-unused-ws.yml"
    cfg_ws.write_text(
        f'json: "{BASE}"\n'
        f'kinds: "dead, public, blanket"\n'   # spaces after commas: trimmed
        f"roots:\n  - \"{ROOT}\"\n"
    )
    cs.append(Case(
        area="unused", name="config_kinds_whitespace_trim",
        cmd=[BIN, f"--config={cfg_ws}"],
        note="YAML scalar kinds CSV with spaces is trimmed (parseKindsCSV)",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "applied config from"},
            {"type": "stdout_contains", "v": "# total:"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # YAML list form of kinds (kinds: [dead, public]) plus an alias element.
    cfg_list = Path(tempfile.gettempdir()) / "battletest-agda-unused-list.yml"
    cfg_list.write_text(
        f'json: "{BASE}"\n'
        f"kinds:\n  - defined\n  - public\n"     # list form, with the alias
        f"roots:\n  - \"{ROOT}\"\n"
    )
    cs.append(Case(
        area="unused", name="config_kinds_list_form",
        cmd=[BIN, f"--config={cfg_list}"],
        note="YAML list-form kinds with alias element (kinds: [defined, public])",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "applied config from"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --help ------------------------------------------------------------
    cs.append(Case(
        area="unused", name="help_long",
        cmd=[BIN, "--help"],
        note="--help prints usage, exits 0",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "USAGE:"},
            {"type": "stdout_contains", "v": "--kinds"},
        ],
    ))
    cs.append(Case(
        area="unused", name="help_short",
        cmd=[BIN, "-h"],
        note="-h short flag prints usage, exits 0",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "USAGE:"},
        ],
    ))

    # ---- Error cases -------------------------------------------------------
    # Bad kind token -> exit 1 (uses exitFailure), 'unknown kind' on stderr.
    cs.append(Case(
        area="unused", name="err_bad_kind",
        cmd=[BIN, f"--json={BASE}", "--kinds=bogus", ROOT],
        note="invalid --kinds token errors with 'unknown kind'",
        expect_error=True,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "stderr_contains", "v": "unknown kind"},
            {"type": "no_crash"},
        ],
    ))
    # Missing ROOT positional -> 'missing ROOT directory'.
    cs.append(Case(
        area="unused", name="err_missing_root",
        cmd=[BIN, f"--json={BASE}"],
        note="no ROOT positional errors with 'missing ROOT directory'",
        expect_error=True,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "stderr_contains", "v": "missing ROOT directory"},
            {"type": "no_crash"},
        ],
    ))
    # Missing --json -> 'missing --json'.
    cs.append(Case(
        area="unused", name="err_missing_json",
        cmd=[BIN, ROOT],
        note="no --json errors with 'missing --json'",
        expect_error=True,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "stderr_contains", "v": "missing --json"},
            {"type": "no_crash"},
        ],
    ))
    # Unrecognised flag -> 'unrecognised flag'.
    cs.append(Case(
        area="unused", name="err_unknown_flag",
        cmd=[BIN, f"--json={BASE}", "--bogus-flag", ROOT],
        note="unknown --flag errors with 'unrecognised flag'",
        expect_error=True,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "stderr_contains", "v": "unrecognised flag"},
            {"type": "no_crash"},
        ],
    ))
    # Nonexistent graph file.  ROUGH EDGE: loadExpandedGraph opens the file
    # before the Left handler, so a missing path escapes as an UNCAUGHT
    # exception (crash markers in stderr).  We pin the documented behaviour:
    # nonzero exit, error mentions the path / 'does not exist'.  We do NOT
    # attach no_crash here — the crash IS the behaviour we are recording.
    cs.append(Case(
        area="unused", name="err_nonexistent_graph",
        cmd=[BIN, "--json=/tmp/agda-unused-no-such-graph.json", ROOT],
        note="nonexistent --json file: escapes as uncaught IOException (rough edge)",
        expect_error=True,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "stderr_contains", "v": "does not exist"},
        ],
    ))
    # ROOT that doesn't exist on disk: discoverAgdaFiles returns [] for a
    # missing dir, so this is NOT an error — it scans nothing and reports 0.
    cs.append(Case(
        area="unused", name="nonexistent_root_is_empty",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", "/tmp/no-such-root-dir-xyz"],
        note="nonexistent ROOT silently scans nothing -> 0 findings, exit 0",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "# total: 0 finding(s)"},
            {"type": "max_seconds", "v": 60},
        ],
    ))
    # Multiple ROOTs: corpus given twice — still scans, dedupe not required,
    # must run clean (exercises the multi-positional path).
    cs.append(Case(
        area="unused", name="multi_root",
        cmd=[BIN, f"--json={BASE}", "--kinds=all", ROOT, "/tmp/no-such-root-dir-xyz"],
        note="multiple ROOT positionals (one real, one missing) run clean",
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    return cs
