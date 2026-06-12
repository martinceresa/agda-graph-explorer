"""Test matrix for the `agda-goals` executable.

`agda-goals` drives `agda --interaction-json` as a SUBPROCESS per file,
captures the `AllGoalsWarnings` reply, canonicalises each `?`-hole's goal
type, and buckets the canonical forms by hash. It links no Agda; it just
shells out to the `agda` on $PATH (2.9.0 here).

Target selection (kept deliberately small — every case spawns a real agda
load, which is slow on a cold interface cache):

  * The corpus (an external `--safe` Agda development; set via AGE_CORPUS) is
    finished with NO unsolved `?` holes anywhere, and its interfaces are
    already cached under `_build/2.9.0/agda`. So driving agda over a corpus
    file is FAST (~0.1-2.5s) but always yields ZERO buckets
    ("# 0 buckets (no goals found).") — the fully-solved baseline.
    Chosen corpus targets, smallest-load first:
      - DebugTrace.agda      (14 lines, no Prelude import -> ~0.1s)
      - Prelude/Initial.agda (8 lines, only Prelude.Init -> ~2s)
      - DummyHashing.agda    (imports Prelude -> ~2.5s)

  * To exercise the NON-empty bucketing path we synthesise a tiny
    self-contained module under a temp dir with two `Nat`-typed holes; both
    holes canonicalise to "Nat" and land in ONE bucket of size 2. Driven with
    `--agda-arg=--allow-unsolved-metas` so the holes don't error the load.

Exit-code contract (from MainGoals.usage):
  0 success | 1 CLI/usage error | 2 agda binary missing/unexec'able |
  3 agda exited non-zero | 4 unparseable output | 5 no AllGoalsWarnings |
  6 agda reported a structured error before the goal pass.

No determinism check for goals (the harness model excludes it here).
"""
from __future__ import annotations

import tempfile
from pathlib import Path

from harness import Case


# --- fixtures created once at cases()-build time ----------------------------
# Written to a stable temp dir so artifact paths are reproducible within a run.
# These are NOT corpus files; they are throwaway inputs the harness drives.
_FIX = Path(tempfile.gettempdir()) / "agda_goals_battletest"
_FIX.mkdir(parents=True, exist_ok=True)

# Two holes, both of goal type `Nat` -> one bucket, size 2.
_HOLES = _FIX / "Holes.agda"
_HOLES.write_text(
    "module Holes where\n"
    "open import Agda.Builtin.Nat\n"
    "foo : Nat → Nat\n"
    "foo x = ?\n"
    "bar : Nat → Nat\n"
    "bar y = ?\n"
)

# A tiny config: kebab-case mirrors of the CLI flags (AgdaGoals.Config schema).
# Supplies include-paths + top-n + format; the positional FILE still comes from
# the CLI. We pass it explicitly via --config= (the walk-up-to-*.agda-lib
# discovery would not find anything above /tmp).
_CFG = _FIX / "goals-config.yml"


def cases(ctx) -> list[Case]:
    goals = ctx.bin("goals")
    corpus = str(ctx.corpus)

    debug_trace = str(ctx.corpus / "DebugTrace.agda")        # lightest, ~0.1s
    initial = str(ctx.corpus / "Prelude" / "Initial.agda")   # ~2s
    dummy = str(ctx.corpus / "DummyHashing.agda")            # ~2.5s

    holes = str(_HOLES)
    holes_dir = str(_FIX)

    # Write the config fixture now (include path -> corpus so imports resolve).
    _CFG.write_text(
        "include-paths:\n"
        f"  - {corpus}\n"
        "top-n: 3\n"
        "format: human\n"
    )
    cfg = str(_CFG)

    cs: list[Case] = []

    # ---- happy path: small solved corpus files, human format ----------------
    cs.append(Case(
        area="goals", name="human_debugtrace",
        cmd=[goals, "--format=human", "-i", corpus, debug_trace],
        note="drive smallest leaf file (DebugTrace), human; solved => 0 buckets",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "stdout_contains", "v": "0 buckets"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    cs.append(Case(
        area="goals", name="human_initial",
        cmd=[goals, "--format=human", "--include=" + corpus, initial],
        note="drive Prelude/Initial (8 lines, --include= long form), human",
        timeout=240,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 120},
        ],
    ))

    # ---- same, json format --------------------------------------------------
    cs.append(Case(
        area="goals", name="json_debugtrace",
        cmd=[goals, "--format=json", "-i", corpus, debug_trace],
        note="DebugTrace, json: must be valid JSON with buckets/errors arrays",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "stdout_contains", "v": "\"buckets\""},
            {"type": "stdout_contains", "v": "\"errors\""},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    cs.append(Case(
        area="goals", name="json_dummyhashing",
        cmd=[goals, "--format=json", "-i", corpus, dummy],
        note="DummyHashing (imports Prelude, heavier load), json validity",
        timeout=300,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "max_seconds", "v": 180},
        ],
    ))

    # ---- NON-empty buckets: synthetic two-hole module -----------------------
    # Both holes are `Nat` -> a single bucket of size 2. Needs
    # --allow-unsolved-metas (forwarded to agda) or the load would error.
    cs.append(Case(
        area="goals", name="holes_json_buckets",
        cmd=[goals, "--format=json", "--agda-arg=--allow-unsolved-metas",
             "-i", holes_dir, holes],
        note="synthetic file with two Nat holes -> one non-empty bucket (size 2)",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_json"},
            {"type": "stdout_contains", "v": "\"size\":2"},
            {"type": "stdout_contains", "v": "\"canonical\":\"Nat\""},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    cs.append(Case(
        area="goals", name="holes_human_buckets",
        cmd=[goals, "--format=human", "--agda-arg=--allow-unsolved-metas",
             "-i", holes_dir, holes],
        note="same synthetic holes, human: '1 bucket(s), 2 goal occurrence(s)'",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "stdout_contains", "v": "1 bucket(s)"},
            {"type": "stdout_contains", "v": "2 goal occurrence(s)"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --top-n variation (human only; JSON emits every bucket regardless) -
    cs.append(Case(
        area="goals", name="holes_topn1",
        cmd=[goals, "--format=human", "--top-n=1",
             "--agda-arg=--allow-unsolved-metas", "-i", holes_dir, holes],
        note="--top-n=1 on the synthetic holes; single bucket still shown",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_contains", "v": "bucket #1"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --quiet and --verbose ----------------------------------------------
    cs.append(Case(
        area="goals", name="quiet_debugtrace",
        cmd=[goals, "--format=human", "--quiet", "-i", corpus, debug_trace],
        note="--quiet suppresses the applied-config breadcrumb (none here anyway)",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stdout_nonempty"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    cs.append(Case(
        area="goals", name="verbose_debugtrace",
        cmd=[goals, "--format=human", "--verbose", "-i", corpus, debug_trace],
        note="--verbose echoes the IOTCM command + agda raw output to stderr",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "IOTCM"},
            {"type": "stderr_contains", "v": "Cmd_load"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- --config= (tiny YAML supplies include-paths + top-n) ---------------
    cs.append(Case(
        area="goals", name="config_breadcrumb",
        cmd=[goals, "--config=" + cfg, debug_trace],
        note="config supplies include-paths/top-n; breadcrumb on stderr; exit 0",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "applied config from"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    cs.append(Case(
        area="goals", name="config_quiet_no_breadcrumb",
        cmd=[goals, "--config=" + cfg, "--quiet", debug_trace],
        note="--quiet over a config: breadcrumb suppressed, still exit 0",
        timeout=180,
        checks=[
            {"type": "exit_eq", "v": 0},
            {"type": "no_crash"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # ---- error cases --------------------------------------------------------
    # Spawn failure: agda binary doesn't exist -> MissingBinary -> exit 2.
    cs.append(Case(
        area="goals", name="err_bad_agda_bin",
        cmd=[goals, "--format=human", "--agda-bin=/no/such/agda",
             "-i", corpus, debug_trace],
        note="--agda-bin=/no/such/agda: subprocess spawn failure -> exit 2",
        expect_error=True,
        timeout=60,
        checks=[
            {"type": "exit_in", "v": [1, 2]},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "could not exec"},
        ],
    ))

    # No positional FILE -> CLI usage error -> exit 1.
    cs.append(Case(
        area="goals", name="err_missing_file",
        cmd=[goals, "--format=human", "-i", corpus],
        note="no FILE positional argument -> usage error, exit 1",
        expect_error=True,
        timeout=60,
        checks=[
            {"type": "exit_eq", "v": 1},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "missing FILE argument"},
        ],
    ))

    # Nonexistent .agda file. agda reports the read failure via the JSON
    # protocol channel (often exiting zero), so the driver classifies it as
    # AgdaReportedError -> exit 6. Accept the broader error band defensively.
    cs.append(Case(
        area="goals", name="err_nonexistent_file",
        cmd=[goals, "--format=human", "-i", corpus,
             str(ctx.corpus / "DoesNotExist.agda")],
        note="nonexistent .agda file -> fail-fast exit 2 + direct message (U3 fix; was exit 6 via the protocol)",
        expect_error=True,
        timeout=120,
        checks=[
            {"type": "exit_eq", "v": 2},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "DoesNotExist.agda"},
            {"type": "max_seconds", "v": 60},
        ],
    ))

    # Malformed --format value -> CLI parse error -> exit 1.
    cs.append(Case(
        area="goals", name="err_bad_format",
        cmd=[goals, "--format=bogus", "-i", corpus, debug_trace],
        note="--format=bogus: rejected at CLI parse, exit 1, no agda spawn",
        expect_error=True,
        timeout=60,
        checks=[
            {"type": "exit_eq", "v": 1},
            {"type": "no_crash"},
            {"type": "stderr_contains", "v": "unknown --format value"},
        ],
    ))

    return cs
