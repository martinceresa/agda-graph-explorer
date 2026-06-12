"""BattleTest matrix for the ``agda-optimization`` executable.

Exhaustive coverage of all 18 subcommands plus the global flag surface.
The subcommands (and their flags) are derived from
``src/AgdaOptimization/CLI.hs`` (the subcommand table + single-pass global
scanner) and each analysis module's declarative ``flagSpecs :: [FlagSpec
Options]`` list.

Invocation shape (from CLI.hs):

    agda-optimization [GLOBAL...] <subcommand> <graph.json> [SUBFLAGS...]

GLOBAL flags (--json / --out / --config) are peeled BEFORE the subcommand
and so must precede it. The token right after the subcommand is taken
verbatim as the graph path; globals after that are peeled again (so a
trailing ``--json`` is honoured, but a trailing bare ``--out`` is a
deferred error — see ``ordering`` cases).

Graphs:
  * ctx.graph_full — 5858-node project-only graph WITH signatures +
    term-hashes + provenance + externals_summary. Default for most cases
    (faster + has every feature term-cluster / silhouette / ledger need).
  * ctx.graph_base — 15346-node full-stdlib closure, PLAIN (no signatures
    / term-hashes) but has edge provenance. ~135MB; used for the
    scale-stress subset only.

Feature notes:
  * term-cluster requires term-hashes -> graph_full only.
  * fiedler shells out to scripts/fiedler_helper.py + scipy, which is
    likely NOT installed -> exit_in [0,2,3] and we do not require stdout.
  * ledger / debt read externals_summary (present in graph_full).
"""
from __future__ import annotations

from harness import Case

# Module-level paths written once for the --config case (created lazily on
# import — cheap, deterministic temp files).
import textwrap
from pathlib import Path

_CFG_PATH = Path("/tmp/age_opt_config.yml")
_OUT_PATH = "/tmp/age_opt_out.txt"


def _write_config() -> str:
    """Write a tiny YAML config exercising the nested per-subcommand layout.

    AgdaOptimization.Config: top-level keys are 'global:' plus one
    kebab-case section per subcommand; field names are the CLI flag names
    minus the leading '--'. Here we set motif's top-n via the 'motif:'
    section, which the run will pick up (and stderr will breadcrumb).
    """
    _CFG_PATH.write_text(textwrap.dedent("""\
        global:
          json: false
        motif:
          top-n: 7
          min-support: 4
        debt:
          top-n: 12
        """))
    return str(_CFG_PATH)


# Standard check bundles ------------------------------------------------------

def _human(maxs: int = 120) -> list:
    return [
        {"type": "exit_eq", "v": 0},
        {"type": "stdout_nonempty"},
        {"type": "no_crash"},
        {"type": "max_seconds", "v": maxs},
    ]


def _json_checks() -> list:
    return [
        {"type": "exit_eq", "v": 0},
        {"type": "stdout_json"},
        {"type": "no_crash"},
    ]


def _err_checks() -> list:
    return [
        {"type": "exit_in", "v": [1, 2]},
        {"type": "no_crash"},
    ]


def _help_checks() -> list:
    return [
        {"type": "exit_eq", "v": 0},
        {"type": "stdout_nonempty"},
    ]


# Per-subcommand flag matrix --------------------------------------------------
#
# Each entry is (subcommand, [flag-token-list]) where each flag-token is a
# single "--flag=value" / "--switch" string. These mirror the flagSpecs of
# the corresponding analysis module. Enum flags get one case per valid
# token. fiedler is handled specially (no scipy).

# Subcommands whose default human run is cheap enough to also carry a
# determinism check (representative spread, > 6).
_DETERMINISM_SUBS = {
    "load-bearing", "polyglot", "debt", "ledger",
    "horizon", "strata", "concept-bundle", "silhouette",
}


def cases(ctx) -> list[Case]:
    opt = str(ctx.bin("opt"))
    gfull = str(ctx.graph_full)
    gbase = str(ctx.graph_base)
    cs: list[Case] = []

    # ---- Global surface -----------------------------------------------------
    cs.append(Case("opt", "global.help", [opt, "--help"],
                   note="top-level --help",
                   checks=_help_checks()))
    cs.append(Case("opt", "global.help-short", [opt, "-h"],
                   note="top-level -h",
                   checks=_help_checks()))
    cs.append(Case("opt", "global.version", [opt, "--version"],
                   note="--version prints agda-optimization X.Y.Z",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_contains", "v": "agda-optimization"},
                           {"type": "no_crash"}]))
    cs.append(Case("opt", "global.version-short", [opt, "-V"],
                   note="-V version alias",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"}, {"type": "no_crash"}]))
    cs.append(Case("opt", "global.numeric-version", [opt, "--numeric-version"],
                   note="--numeric-version prints bare semver",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"}, {"type": "no_crash"}]))
    cs.append(Case("opt", "global.no-subcommand", [opt],
                   note="missing subcommand -> error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "stderr_contains", "v": "missing subcommand"},
                           {"type": "no_crash"}]))
    cs.append(Case("opt", "global.unknown-subcommand", [opt, "bogus-sub", gfull],
                   note="unknown subcommand -> error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "stderr_contains", "v": "unknown subcommand"},
                           {"type": "no_crash"}]))
    cs.append(Case("opt", "global.missing-graph", [opt, "motif"],
                   note="subcommand with no graph path -> error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "stderr_contains", "v": "missing"},
                           {"type": "no_crash"}]))

    # --out=FILE: human report is redirected to the file, so stdout is empty.
    cs.append(Case("opt", "global.out-file",
                   [opt, f"--out={_OUT_PATH}", "motif", gfull],
                   note="--out=FILE redirects report; stdout empty",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_empty"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 120}]))
    # bare --out as a leading global with no FILE -> immediate unscoped error.
    cs.append(Case("opt", "global.out-missing-arg",
                   [opt, "--out", "motif", gfull],
                   note="bare --out before subcommand consumes 'motif' as FILE then errors on path",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "no_crash"}]))

    # --config with a YAML we write to /tmp (motif: top-n: 7).
    cfg = _write_config()
    cs.append(Case("opt", "global.config-file",
                   [opt, f"--config={cfg}", "motif", gfull],
                   note="--config applies motif: section; stderr breadcrumb",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"},
                           {"type": "stderr_contains", "v": "applied config"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 120}]))
    cs.append(Case("opt", "global.config-json-no-breadcrumb",
                   [opt, "--json", f"--config={cfg}", "debt", gfull],
                   note="--json suppresses the config breadcrumb; still valid JSON",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_json"},
                           {"type": "no_crash"}]))
    cs.append(Case("opt", "global.config-missing-file",
                   [opt, "--config=/tmp/age_opt_does_not_exist.yml", "motif", gfull],
                   note="--config pointing at a missing file -> hard error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "no_crash"}]))

    # Ordering: trailing --json AFTER the path is peeled and honoured.
    cs.append(Case("opt", "ordering.trailing-json",
                   [opt, "motif", gfull, "--json"],
                   note="positional/global ordering: trailing --json is honoured (peeled post-path)",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_json"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 120}]))
    # Ordering: --json IMMEDIATELY after subcommand sits in path slot ->
    # treated as the graph path -> load failure (NOT honoured as global).
    cs.append(Case("opt", "ordering.json-in-path-slot",
                   [opt, "motif", "--json", gfull],
                   note="--json in the path slot is taken as path verbatim (not a global) -> load error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "no_crash"}]))
    # Ordering: bare trailing --out -> deferred subcommand-scoped error.
    cs.append(Case("opt", "ordering.trailing-out-missing-arg",
                   [opt, "motif", gfull, "--out"],
                   note="bare trailing --out -> deferred scoped 'missing FILE' error",
                   expect_error=True,
                   checks=[{"type": "exit_in", "v": [1, 2]},
                           {"type": "no_crash"}]))

    # ---- Per-subcommand: default human + --json + --help --------------------
    all_subs = [
        "motif", "load-bearing", "polyglot", "fingerprint", "debt", "basket",
        "ledger", "echo", "gravity", "pyre", "chokepoint", "silhouette",
        "entwine", "fiedler", "horizon", "strata", "term-cluster",
        "concept-bundle",
    ]

    for sub in all_subs:
        san = sub.replace("-", "_") if False else sub  # names allow [a-z0-9._-]
        if sub == "fiedler":
            # fiedler shells out to scipy; likely not installed. Do NOT
            # require stdout; accept clean diagnostic exits 2 (missing
            # helper) / 3 (missing scipy) as well as 0 (present).
            cs.append(Case("opt", f"{san}.default",
                           [opt, sub, gfull],
                           note="fiedler default (scipy may be absent: exit 0/2/3 all ok, stdout not required)",
                           checks=[{"type": "exit_in", "v": [0, 2, 3]},
                                   {"type": "no_crash"},
                                   {"type": "max_seconds", "v": 120}]))
            cs.append(Case("opt", f"{san}.json",
                           [opt, "--json", sub, gfull],
                           note="fiedler --json (scipy may be absent: exit 0/2/3, no_crash only)",
                           checks=[{"type": "exit_in", "v": [0, 2, 3]},
                                   {"type": "no_crash"}]))
        else:
            cs.append(Case("opt", f"{san}.default",
                           [opt, sub, gfull],
                           note=f"{sub} default human run on graph_full",
                           checks=_human()))
            cs.append(Case("opt", f"{san}.json",
                           [opt, "--json", sub, gfull],
                           note=f"{sub} --json (global flag precedes subcommand)",
                           checks=_json_checks()))
        # Per-subcommand --help (derived from flagSpecs via renderFlagHelp).
        cs.append(Case("opt", f"{san}.help",
                       [opt, sub, "--help"],
                       note=f"{sub} --help lists its flagSpecs",
                       checks=_help_checks()))

    # ---- Determinism (representative spread, > 6) ---------------------------
    for sub in sorted(_DETERMINISM_SUBS):
        cs.append(Case("opt", f"{sub}.determinism",
                       [opt, sub, gfull],
                       note=f"{sub} byte-identical under +RTS -N1 vs -N4",
                       checks=[{"type": "exit_eq", "v": 0},
                               {"type": "determinism"},
                               {"type": "no_crash"},
                               {"type": "max_seconds", "v": 120}]))
    # one determinism case in JSON mode too.
    cs.append(Case("opt", "polyglot.determinism-json",
                   [opt, "--json", "polyglot", gfull],
                   note="polyglot --json determinism (parallel reduction must be order-stable)",
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "determinism"},
                           {"type": "no_crash"}]))

    # ---- Per-subcommand flag exercises --------------------------------------

    # motif: ints (min-support/min-size/max-size/top-n/max-fan-out/
    # min-label-distinct), doubles (exclude-hub-pct/budget), switch
    # (per-module).
    cs += [
        Case("opt", "motif.flag-min-support",
             [opt, "motif", gfull, "--min-support=5"],
             note="motif --min-support int", checks=_human()),
        Case("opt", "motif.flag-sizes",
             [opt, "motif", gfull, "--min-size=2", "--max-size=5", "--max-fan-out=4"],
             note="motif heavy --max-size warns (P4); --max-fan-out bounds per-seed cost so it completes",
             timeout=60,
             checks=[{"type": "exit_eq", "v": 0}, {"type": "stdout_nonempty"},
                     {"type": "no_crash"}, {"type": "stderr_contains", "v": "max-size=5"}]),
        Case("opt", "motif.flag-top-n",
             [opt, "motif", gfull, "--top-n=10"],
             note="motif --top-n int", checks=_human()),
        Case("opt", "motif.flag-exclude-hub-pct",
             [opt, "motif", gfull, "--exclude-hub-pct=1.0"],
             note="motif --exclude-hub-pct double", checks=_human()),
        Case("opt", "motif.flag-max-fan-out",
             [opt, "motif", gfull, "--max-fan-out=20"],
             note="motif --max-fan-out int", checks=_human()),
        Case("opt", "motif.flag-budget",
             [opt, "motif", gfull, "--budget=30"],
             note="motif --budget double (wall-clock cap)", checks=_human()),
        Case("opt", "motif.flag-min-label-distinct",
             [opt, "motif", gfull, "--min-label-distinct=2"],
             note="motif --min-label-distinct int", checks=_human()),
        Case("opt", "motif.flag-per-module",
             [opt, "motif", gfull, "--per-module"],
             note="motif --per-module switch (warns + falls back)", checks=_human()),
        Case("opt", "motif.flag-json-combo",
             [opt, "--json", "motif", gfull, "--top-n=5", "--min-support=4"],
             note="motif --json + multiple flags", checks=_json_checks()),
    ]

    # load-bearing: enums results{tagged,exported,terminals},
    # weight{unit,loc}; int top-n; regex exclude.
    cs += [
        Case("opt", "load-bearing.results-tagged",
             [opt, "load-bearing", gfull, "--results=tagged"],
             note="load-bearing --results=tagged", checks=_human()),
        Case("opt", "load-bearing.results-exported",
             [opt, "load-bearing", gfull, "--results=exported"],
             note="load-bearing --results=exported", checks=_human()),
        Case("opt", "load-bearing.results-terminals",
             [opt, "load-bearing", gfull, "--results=terminals"],
             note="load-bearing --results=terminals", checks=_human()),
        Case("opt", "load-bearing.weight-unit",
             [opt, "load-bearing", gfull, "--weight=unit"],
             note="load-bearing --weight=unit", checks=_human()),
        Case("opt", "load-bearing.weight-loc",
             [opt, "load-bearing", gfull, "--weight=loc"],
             note="load-bearing --weight=loc", checks=_human()),
        Case("opt", "load-bearing.top-n",
             [opt, "load-bearing", gfull, "--top-n=15"],
             note="load-bearing --top-n int", checks=_human()),
        Case("opt", "load-bearing.exclude-name-regex",
             [opt, "load-bearing", gfull, "--exclude-name-regex=^test"],
             note="load-bearing --exclude-name-regex POSIX-ERE", checks=_human()),
    ]

    # polyglot: int min-uses, top-n; double threshold.
    cs += [
        Case("opt", "polyglot.min-uses",
             [opt, "polyglot", gfull, "--min-uses=3"],
             note="polyglot --min-uses int", checks=_human()),
        Case("opt", "polyglot.threshold",
             [opt, "polyglot", gfull, "--threshold=2.0"],
             note="polyglot --threshold double", checks=_human()),
        Case("opt", "polyglot.top-n",
             [opt, "polyglot", gfull, "--top-n=20"],
             note="polyglot --top-n int", checks=_human()),
    ]

    # fingerprint: double jaccard; ints min-size/wl-k/wl-depth/top-n;
    # enum direction{outgoing,incoming,both,bidirectional}.
    cs += [
        Case("opt", "fingerprint.jaccard",
             [opt, "fingerprint", gfull, "--jaccard=0.7"],
             note="fingerprint --jaccard double", checks=_human()),
        Case("opt", "fingerprint.min-size",
             [opt, "fingerprint", gfull, "--min-size=4"],
             note="fingerprint --min-size int", checks=_human()),
        Case("opt", "fingerprint.wl-k",
             [opt, "fingerprint", gfull, "--wl-k=3"],
             note="fingerprint --wl-k int", checks=_human()),
        Case("opt", "fingerprint.wl-depth",
             [opt, "fingerprint", gfull, "--wl-depth=2"],
             note="fingerprint --wl-depth int", checks=_human()),
        Case("opt", "fingerprint.direction-outgoing",
             [opt, "fingerprint", gfull, "--direction=outgoing"],
             note="fingerprint --direction=outgoing", checks=_human()),
        Case("opt", "fingerprint.direction-incoming",
             [opt, "fingerprint", gfull, "--direction=incoming"],
             note="fingerprint --direction=incoming", checks=_human()),
        Case("opt", "fingerprint.direction-both",
             [opt, "fingerprint", gfull, "--direction=both"],
             note="fingerprint --direction=both", checks=_human()),
        Case("opt", "fingerprint.top-n",
             [opt, "fingerprint", gfull, "--top-n=10"],
             note="fingerprint --top-n int", checks=_human()),
    ]

    # debt: int top-n; pre-guard switches include-foundational,
    # no-include-postulates, no-foundational-inventory.
    cs += [
        Case("opt", "debt.top-n",
             [opt, "debt", gfull, "--top-n=20"],
             note="debt --top-n int", checks=_human()),
        Case("opt", "debt.include-foundational",
             [opt, "debt", gfull, "--include-foundational"],
             note="debt --include-foundational switch", checks=_human()),
        Case("opt", "debt.no-include-postulates",
             [opt, "debt", gfull, "--no-include-postulates"],
             note="debt --no-include-postulates switch", checks=_human()),
        Case("opt", "debt.no-foundational-inventory",
             [opt, "debt", gfull, "--no-foundational-inventory"],
             note="debt --no-foundational-inventory switch", checks=_human()),
    ]

    # basket: doubles (min-support/min-confidence/min-lift/
    # exclude-top-frequency/budget/forced-fraction); int top-n;
    # switches forced-suppress / no-forced-suppress.
    cs += [
        Case("opt", "basket.min-support",
             [opt, "basket", gfull, "--min-support=0.02"],
             note="basket --min-support double", checks=_human()),
        Case("opt", "basket.min-confidence",
             [opt, "basket", gfull, "--min-confidence=0.4"],
             note="basket --min-confidence double", checks=_human()),
        Case("opt", "basket.min-lift",
             [opt, "basket", gfull, "--min-lift=1.2"],
             note="basket --min-lift double", checks=_human()),
        Case("opt", "basket.exclude-top-frequency",
             [opt, "basket", gfull, "--exclude-top-frequency=3.0"],
             note="basket --exclude-top-frequency double", checks=_human()),
        Case("opt", "basket.top-n",
             [opt, "basket", gfull, "--top-n=30"],
             note="basket --top-n int", checks=_human()),
        Case("opt", "basket.budget",
             [opt, "basket", gfull, "--budget=30"],
             note="basket --budget double", checks=_human()),
        Case("opt", "basket.no-forced-suppress",
             [opt, "basket", gfull, "--no-forced-suppress"],
             note="basket --no-forced-suppress switch", checks=_human()),
        Case("opt", "basket.forced-suppress",
             [opt, "basket", gfull, "--forced-suppress"],
             note="basket --forced-suppress switch", checks=_human()),
        Case("opt", "basket.forced-fraction",
             [opt, "basket", gfull, "--forced-fraction=0.6"],
             note="basket --forced-fraction double", checks=_human()),
    ]

    # ledger: ints top-n/min-axioms/cohort-min-size; pre-guard switch
    # no-foundational; enum axiom-source{postulate,record-field,both};
    # repeatable axiom-module-prefix + theorem-prefix.
    cs += [
        Case("opt", "ledger.top-n",
             [opt, "ledger", gfull, "--top-n=20"],
             note="ledger --top-n int", checks=_human()),
        Case("opt", "ledger.min-axioms",
             [opt, "ledger", gfull, "--min-axioms=1"],
             note="ledger --min-axioms int", checks=_human()),
        Case("opt", "ledger.cohort-min-size",
             [opt, "ledger", gfull, "--cohort-min-size=3"],
             note="ledger --cohort-min-size int", checks=_human()),
        Case("opt", "ledger.no-foundational",
             [opt, "ledger", gfull, "--no-foundational"],
             note="ledger --no-foundational switch", checks=_human()),
        Case("opt", "ledger.axiom-source-postulate",
             [opt, "ledger", gfull, "--axiom-source=postulate"],
             note="ledger --axiom-source=postulate", checks=_human()),
        Case("opt", "ledger.axiom-source-record-field",
             [opt, "ledger", gfull, "--axiom-source=record-field"],
             note="ledger --axiom-source=record-field", checks=_human()),
        Case("opt", "ledger.axiom-source-both",
             [opt, "ledger", gfull, "--axiom-source=both"],
             note="ledger --axiom-source=both", checks=_human()),
        Case("opt", "ledger.theorem-prefix-repeatable",
             [opt, "ledger", gfull, "--theorem-prefix=Main", "--theorem-prefix=Network"],
             note="ledger --theorem-prefix repeatable (appends)", checks=_human()),
        Case("opt", "ledger.axiom-module-prefix-repeatable",
             [opt, "ledger", gfull,
              "--axiom-source=record-field",
              "--axiom-module-prefix=Agda", "--axiom-module-prefix=Data"],
             note="ledger --axiom-module-prefix repeatable", checks=_human()),
    ]

    # echo: int wl-k/min-size/wl-depth/top-n; double jaccard/
    # max-cluster-spread; reject-value switch delta-only.
    cs += [
        Case("opt", "echo.wl-k",
             [opt, "echo", gfull, "--wl-k=3"],
             note="echo --wl-k int", checks=_human()),
        Case("opt", "echo.jaccard",
             [opt, "echo", gfull, "--jaccard=0.7"],
             note="echo --jaccard double", checks=_human()),
        Case("opt", "echo.min-size",
             [opt, "echo", gfull, "--min-size=4"],
             note="echo --min-size int", checks=_human()),
        Case("opt", "echo.wl-depth",
             [opt, "echo", gfull, "--wl-depth=2"],
             note="echo --wl-depth int", checks=_human()),
        Case("opt", "echo.delta-only",
             [opt, "echo", gfull, "--delta-only"],
             note="echo --delta-only switch (rejects attached value)", checks=_human()),
        Case("opt", "echo.max-cluster-spread",
             [opt, "echo", gfull, "--max-cluster-spread=0.4"],
             note="echo --max-cluster-spread double", checks=_human()),
        Case("opt", "echo.delta-only-takes-no-value",
             [opt, "echo", gfull, "--delta-only=yes"],
             note="echo --delta-only=VALUE is a hard error (SwitchRejectValue)",
             expect_error=True, checks=_err_checks()),
    ]

    # gravity: double damping/tolerance; ints iters/top-n/top-theorems;
    # enum results{public,tagged,terminals}.
    cs += [
        Case("opt", "gravity.damping",
             [opt, "gravity", gfull, "--damping=0.9"],
             note="gravity --damping double", checks=_human()),
        Case("opt", "gravity.iters",
             [opt, "gravity", gfull, "--iters=30"],
             note="gravity --iters int", checks=_human()),
        Case("opt", "gravity.tolerance",
             [opt, "gravity", gfull, "--tolerance=1e-5"],
             note="gravity --tolerance double (sci notation)", checks=_human()),
        Case("opt", "gravity.top-n",
             [opt, "gravity", gfull, "--top-n=20"],
             note="gravity --top-n int", checks=_human()),
        Case("opt", "gravity.results-public",
             [opt, "gravity", gfull, "--results=public"],
             note="gravity --results=public", checks=_human()),
        Case("opt", "gravity.results-tagged",
             [opt, "gravity", gfull, "--results=tagged"],
             note="gravity --results=tagged", checks=_human()),
        Case("opt", "gravity.results-terminals",
             [opt, "gravity", gfull, "--results=terminals"],
             note="gravity --results=terminals", checks=_human()),
        Case("opt", "gravity.top-theorems",
             [opt, "gravity", gfull, "--top-theorems=32"],
             note="gravity --top-theorems int (PPR seed count)", checks=_human()),
    ]

    # pyre: int top-n; doubles w1..w4/ridge-lambda; regex exclude;
    # str profile; switches calibrate/levers.
    cs += [
        Case("opt", "pyre.top-n",
             [opt, "pyre", gfull, "--top-n=20"],
             note="pyre --top-n int", checks=_human()),
        Case("opt", "pyre.weights",
             [opt, "pyre", gfull, "--w1=1.5", "--w2=0.4", "--w3=2.5", "--w4=8.0"],
             note="pyre --w1..--w4 doubles", checks=_human()),
        Case("opt", "pyre.exclude-name-regex",
             [opt, "pyre", gfull, "--exclude-name-regex=^_"],
             note="pyre --exclude-name-regex POSIX-ERE", checks=_human()),
        Case("opt", "pyre.levers",
             [opt, "pyre", gfull, "--levers"],
             note="pyre --levers switch (lever table)", checks=_human()),
        Case("opt", "pyre.ridge-lambda",
             [opt, "pyre", gfull, "--ridge-lambda=2.0"],
             note="pyre --ridge-lambda double", checks=_human()),
        # --calibrate needs --profile; without it the run should still not
        # crash (it warns / degrades). Accept exit 0 or 1.
        Case("opt", "pyre.calibrate-no-profile",
             [opt, "pyre", gfull, "--calibrate"],
             note="pyre --calibrate without --profile (degrades cleanly)",
             checks=[{"type": "exit_in", "v": [0, 1]},
                     {"type": "no_crash"},
                     {"type": "max_seconds", "v": 120}]),
    ]

    # chokepoint: int top-n; enum sources{exported,public,terminals};
    # enum sinks{postulates-axioms,terminal-leaves}; regex exclude.
    cs += [
        Case("opt", "chokepoint.top-n",
             [opt, "chokepoint", gfull, "--top-n=20"],
             note="chokepoint --top-n int", checks=_human()),
        Case("opt", "chokepoint.sources-exported",
             [opt, "chokepoint", gfull, "--sources=exported"],
             note="chokepoint --sources=exported", checks=_human()),
        Case("opt", "chokepoint.sources-public",
             [opt, "chokepoint", gfull, "--sources=public"],
             note="chokepoint --sources=public", checks=_human()),
        Case("opt", "chokepoint.sources-terminals",
             [opt, "chokepoint", gfull, "--sources=terminals"],
             note="chokepoint --sources=terminals", checks=_human()),
        Case("opt", "chokepoint.sinks-postulates-axioms",
             [opt, "chokepoint", gfull, "--sinks=postulates-axioms"],
             note="explicit postulate sinks are honoured: 0 if disjoint axioms exist, else a clean exit-1 with the combo-probe (U1)",
             checks=[{"type": "exit_in", "v": [0, 1]}, {"type": "no_crash"}]),
        Case("opt", "chokepoint.sinks-terminal-leaves",
             [opt, "chokepoint", gfull, "--sinks=terminal-leaves"],
             note="chokepoint --sinks=terminal-leaves", checks=_human()),
        Case("opt", "chokepoint.exclude-name-regex",
             [opt, "chokepoint", gfull, "--exclude-name-regex=^_"],
             note="chokepoint --exclude-name-regex POSIX-ERE", checks=_human()),
    ]

    # silhouette: ints wl-k/min-size/min-cluster-size/top-n; doubles
    # high-overlap/low-overlap. Uses provenance (present in full).
    cs += [
        Case("opt", "silhouette.wl-k",
             [opt, "silhouette", gfull, "--wl-k=3"],
             note="silhouette --wl-k int", checks=_human()),
        Case("opt", "silhouette.min-size",
             [opt, "silhouette", gfull, "--min-size=4"],
             note="silhouette --min-size int", checks=_human()),
        Case("opt", "silhouette.min-cluster-size",
             [opt, "silhouette", gfull, "--min-cluster-size=3"],
             note="silhouette --min-cluster-size int", checks=_human()),
        Case("opt", "silhouette.overlaps",
             [opt, "silhouette", gfull, "--high-overlap=0.6", "--low-overlap=0.15"],
             note="silhouette --high-overlap/--low-overlap doubles", checks=_human()),
        Case("opt", "silhouette.top-n",
             [opt, "silhouette", gfull, "--top-n=20"],
             note="silhouette --top-n int", checks=_human()),
    ]

    # entwine: int min-co-callers/top-n; double min-iqr/min-g-stat;
    # pre-guard switch transitive; regex exclude.
    cs += [
        Case("opt", "entwine.min-co-callers",
             [opt, "entwine", gfull, "--min-co-callers=4"],
             note="entwine --min-co-callers int", checks=_human()),
        Case("opt", "entwine.min-iqr",
             [opt, "entwine", gfull, "--min-iqr=0.4"],
             note="entwine --min-iqr double", checks=_human()),
        Case("opt", "entwine.min-g-stat",
             [opt, "entwine", gfull, "--min-g-stat=5.0"],
             note="entwine --min-g-stat double", checks=_human()),
        Case("opt", "entwine.top-n",
             [opt, "entwine", gfull, "--top-n=50"],
             note="entwine --top-n int", checks=_human()),
        Case("opt", "entwine.transitive",
             [opt, "entwine", gfull, "--transitive"],
             note="entwine --transitive switch (ancestor baskets)", checks=_human()),
        Case("opt", "entwine.exclude-name-regex",
             [opt, "entwine", gfull, "--exclude-name-regex=^_"],
             note="entwine --exclude-name-regex POSIX-ERE", checks=_human()),
    ]

    # fiedler: ints top-n/eig-k; str helper/python. scipy likely absent ->
    # use the no-scipy check bundle on all of them.
    _fiedler_ok = [{"type": "exit_in", "v": [0, 2, 3]},
                   {"type": "no_crash"},
                   {"type": "max_seconds", "v": 120}]
    cs += [
        Case("opt", "fiedler.top-n",
             [opt, "fiedler", gfull, "--top-n=20"],
             note="fiedler --top-n int (scipy may be absent)", checks=list(_fiedler_ok)),
        Case("opt", "fiedler.eig-k",
             [opt, "fiedler", gfull, "--eig-k=3"],
             note="fiedler --eig-k int (scipy may be absent)", checks=list(_fiedler_ok)),
        Case("opt", "fiedler.bad-helper",
             [opt, "fiedler", gfull, "--helper=/tmp/age_no_such_helper.py"],
             note="fiedler --helper to a missing script -> clean diag (exit 2), no crash",
             checks=[{"type": "exit_in", "v": [2, 3]},
                     {"type": "no_crash"}]),
        Case("opt", "fiedler.bad-python",
             [opt, "fiedler", gfull, "--python=/tmp/age_no_such_python"],
             note="fiedler --python to a missing interpreter -> clean diag, no crash",
             checks=[{"type": "exit_in", "v": [0, 2, 3]},
                     {"type": "no_crash"}]),
    ]

    # horizon: enums leaves{postulates-axioms,terminal-leaves},
    # roots{public-theorems,terminals}; pre-guard switch no-module-hist;
    # int top-n; regex exclude.
    cs += [
        Case("opt", "horizon.leaves-postulates-axioms",
             [opt, "horizon", gfull, "--leaves=postulates-axioms"],
             note="horizon --leaves=postulates-axioms", checks=_human()),
        Case("opt", "horizon.leaves-terminal-leaves",
             [opt, "horizon", gfull, "--leaves=terminal-leaves"],
             note="horizon --leaves=terminal-leaves", checks=_human()),
        Case("opt", "horizon.roots-public-theorems",
             [opt, "horizon", gfull, "--roots=public-theorems"],
             note="horizon --roots=public-theorems", checks=_human()),
        Case("opt", "horizon.roots-terminals",
             [opt, "horizon", gfull, "--roots=terminals"],
             note="horizon --roots=terminals", checks=_human()),
        Case("opt", "horizon.no-module-hist",
             [opt, "horizon", gfull, "--no-module-hist"],
             note="horizon --no-module-hist switch", checks=_human()),
        Case("opt", "horizon.top-n",
             [opt, "horizon", gfull, "--top-n=20"],
             note="horizon --top-n int", checks=_human()),
        Case("opt", "horizon.exclude-name-regex",
             [opt, "horizon", gfull, "--exclude-name-regex=^_"],
             note="horizon --exclude-name-regex POSIX-ERE", checks=_human()),
    ]

    # strata: ints top-n/min-size; regex exclude-module-regex.
    cs += [
        Case("opt", "strata.top-n",
             [opt, "strata", gfull, "--top-n=20"],
             note="strata --top-n int", checks=_human()),
        Case("opt", "strata.min-size",
             [opt, "strata", gfull, "--min-size=2"],
             note="strata --min-size int", checks=_human()),
        Case("opt", "strata.exclude-module-regex",
             [opt, "strata", gfull, "--exclude-module-regex=^Agda\\."],
             note="strata --exclude-module-regex POSIX-ERE on full module", checks=_human()),
    ]

    # term-cluster: needs term-hashes (graph_full). ints min-cluster/top-n/
    # max-defs/span-modules/min-mean-depth; enum sort{score,log-score,size};
    # double min-diversity; regex exclude-module-regex.
    cs += [
        Case("opt", "term-cluster.min-cluster",
             [opt, "term-cluster", gfull, "--min-cluster=3"],
             note="term-cluster --min-cluster int (needs term-hashes)", checks=_human()),
        Case("opt", "term-cluster.top-n",
             [opt, "term-cluster", gfull, "--top-n=20"],
             note="term-cluster --top-n int", checks=_human()),
        Case("opt", "term-cluster.max-defs",
             [opt, "term-cluster", gfull, "--max-defs=5"],
             note="term-cluster --max-defs int", checks=_human()),
        Case("opt", "term-cluster.span-modules",
             [opt, "term-cluster", gfull, "--span-modules=2"],
             note="term-cluster --span-modules int", checks=_human()),
        Case("opt", "term-cluster.sort-score",
             [opt, "term-cluster", gfull, "--sort=score"],
             note="term-cluster --sort=score", checks=_human()),
        Case("opt", "term-cluster.sort-log-score",
             [opt, "term-cluster", gfull, "--sort=log-score"],
             note="term-cluster --sort=log-score", checks=_human()),
        Case("opt", "term-cluster.sort-size",
             [opt, "term-cluster", gfull, "--sort=size"],
             note="term-cluster --sort=size", checks=_human()),
        Case("opt", "term-cluster.min-mean-depth",
             [opt, "term-cluster", gfull, "--min-mean-depth=2"],
             note="term-cluster --min-mean-depth int", checks=_human()),
        Case("opt", "term-cluster.min-diversity",
             [opt, "term-cluster", gfull, "--min-diversity=0.7"],
             note="term-cluster --min-diversity double", checks=_human()),
        Case("opt", "term-cluster.exclude-module-regex",
             [opt, "term-cluster", gfull, "--exclude-module-regex=^Agda\\."],
             note="term-cluster --exclude-module-regex POSIX-ERE", checks=_human()),
        # term-cluster on the PLAIN base graph: no term-hashes -> should not
        # crash; likely empty/diagnostic. Accept 0/1.
        Case("opt", "term-cluster.no-term-hashes",
             [opt, "term-cluster", gbase],
             note="term-cluster on plain graph (no term-hashes) degrades cleanly",
             timeout=300,
             checks=[{"type": "exit_in", "v": [0, 1]},
                     {"type": "no_crash"},
                     {"type": "max_seconds", "v": 300}]),
    ]

    # concept-bundle: ints min-support/min-span/top-n/k-max/max-basket-size;
    # doubles min-lift/exclude-top-frequency/forced-fraction; switches
    # forced-suppress/no-forced-suppress. Uses provenance.
    cs += [
        Case("opt", "concept-bundle.min-support",
             [opt, "concept-bundle", gfull, "--min-support=4"],
             note="concept-bundle --min-support int", checks=_human()),
        Case("opt", "concept-bundle.min-lift",
             [opt, "concept-bundle", gfull, "--min-lift=1.5"],
             note="concept-bundle --min-lift double", checks=_human()),
        Case("opt", "concept-bundle.min-span",
             [opt, "concept-bundle", gfull, "--min-span=2"],
             note="concept-bundle --min-span int", checks=_human()),
        Case("opt", "concept-bundle.top-n",
             [opt, "concept-bundle", gfull, "--top-n=20"],
             note="concept-bundle --top-n int", checks=_human()),
        Case("opt", "concept-bundle.k-max",
             [opt, "concept-bundle", gfull, "--k-max=3"],
             note="concept-bundle --k-max int", checks=_human()),
        Case("opt", "concept-bundle.exclude-top-frequency",
             [opt, "concept-bundle", gfull, "--exclude-top-frequency=3.0"],
             note="concept-bundle --exclude-top-frequency double", checks=_human()),
        Case("opt", "concept-bundle.no-forced-suppress",
             [opt, "concept-bundle", gfull, "--no-forced-suppress"],
             note="concept-bundle --no-forced-suppress switch", checks=_human()),
        Case("opt", "concept-bundle.forced-suppress",
             [opt, "concept-bundle", gfull, "--forced-suppress"],
             note="concept-bundle --forced-suppress switch", checks=_human()),
        Case("opt", "concept-bundle.forced-fraction",
             [opt, "concept-bundle", gfull, "--forced-fraction=0.6"],
             note="concept-bundle --forced-fraction double", checks=_human()),
        Case("opt", "concept-bundle.max-basket-size",
             [opt, "concept-bundle", gfull, "--max-basket-size=32"],
             note="concept-bundle --max-basket-size int", checks=_human()),
    ]

    # ---- Error cases (per spec): bad enum, bad int, unknown flag ------------
    # Bad enum tokens (one each across enum-bearing subcommands).
    bad_enum = [
        ("load-bearing", "--results=bogus"),
        ("load-bearing", "--weight=bogus"),
        ("fingerprint", "--direction=sideways"),
        ("ledger", "--axiom-source=bogus"),
        ("gravity", "--results=bogus"),
        ("chokepoint", "--sources=bogus"),
        ("chokepoint", "--sinks=bogus"),
        ("horizon", "--leaves=bogus"),
        ("horizon", "--roots=bogus"),
        ("term-cluster", "--sort=bogus"),
    ]
    for i, (sub, flag) in enumerate(bad_enum):
        key = flag.split("=")[0].lstrip("-")
        cs.append(Case("opt", f"err.{sub}.bad-enum-{key}",
                       [opt, sub, gfull, flag],
                       note=f"{sub} {flag} bad enum token -> error",
                       expect_error=True, checks=_err_checks()))

    # Bad int (--top-n=abc) across a spread of subcommands.
    for sub in ["motif", "polyglot", "debt", "ledger", "gravity",
                "concept-bundle"]:
        cs.append(Case("opt", f"err.{sub}.bad-int-top-n",
                       [opt, sub, gfull, "--top-n=abc"],
                       note=f"{sub} --top-n=abc non-integer -> error",
                       expect_error=True, checks=_err_checks()))
    # Bad double.
    cs.append(Case("opt", "err.basket.bad-double-min-support",
                   [opt, "basket", gfull, "--min-support=notanumber"],
                   note="basket --min-support=notanumber non-number -> error",
                   expect_error=True, checks=_err_checks()))
    cs.append(Case("opt", "err.gravity.bad-double-damping",
                   [opt, "gravity", gfull, "--damping=xyz"],
                   note="gravity --damping=xyz non-number -> error",
                   expect_error=True, checks=_err_checks()))

    # Unknown flag across a spread of subcommands.
    for sub in ["motif", "load-bearing", "fingerprint", "debt", "basket",
                "gravity", "horizon", "term-cluster"]:
        cs.append(Case("opt", f"err.{sub}.unknown-flag",
                       [opt, sub, gfull, "--no-such-flag=1"],
                       note=f"{sub} unknown flag -> error",
                       expect_error=True, checks=_err_checks()))
    # Unknown bare flag (no value).
    cs.append(Case("opt", "err.motif.unknown-bare-flag",
                   [opt, "motif", gfull, "--frobnicate"],
                   note="motif unknown bare flag -> error",
                   expect_error=True, checks=_err_checks()))
    # Int flag given no value at end of argv.
    cs.append(Case("opt", "err.motif.top-n-missing-value",
                   [opt, "motif", gfull, "--top-n"],
                   note="motif --top-n with no value -> 'expects a value' error",
                   expect_error=True, checks=_err_checks()))
    # Nonexistent graph path.
    cs.append(Case("opt", "err.motif.missing-graph-file",
                   [opt, "motif", "/tmp/age_no_such_graph.json"],
                   note="motif on a nonexistent graph file -> load error",
                   expect_error=True, checks=_err_checks()))

    # ---- Scale stress on graph_base (15346 nodes, ~135MB) -------------------
    # motif can be slow on a big graph: give it room + a soft budget so we
    # FLAG slowness rather than fail. Cap its search with a budget flag too.
    cs.append(Case("opt", "scale.motif-base",
                   [opt, "motif", gbase, "--budget=120", "--top-n=20"],
                   note="motif on 15k-node base graph (heavy; budget-capped, soft max_seconds)",
                   timeout=300,
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 240}]))
    cs.append(Case("opt", "scale.gravity-base",
                   [opt, "gravity", gbase],
                   note="gravity (PageRank/PPR) on 15k-node base graph",
                   timeout=300,
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 240}]))
    cs.append(Case("opt", "scale.load-bearing-base",
                   [opt, "load-bearing", gbase],
                   note="load-bearing on 15k-node base graph",
                   timeout=300,
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 240}]))
    cs.append(Case("opt", "scale.horizon-base",
                   [opt, "horizon", gbase],
                   note="horizon (eccentricity/diameter) on 15k-node base graph",
                   timeout=300,
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 240}]))
    cs.append(Case("opt", "scale.debt-base-json",
                   [opt, "--json", "debt", gbase],
                   note="debt --json on 15k-node base graph (JSON well-formed at scale)",
                   timeout=300,
                   checks=[{"type": "exit_eq", "v": 0},
                           {"type": "stdout_json"},
                           {"type": "no_crash"},
                           {"type": "max_seconds", "v": 240}]))

    return cs
