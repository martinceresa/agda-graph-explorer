#!/usr/bin/env bash
# Summarize agda-explore query-log.jsonl into a per-tool usage table:
# call count (descending), error %, stale %, and dur_ms p50 / p95.
#
#   scripts/tool-usage-report.sh <out-dir>/query-log.jsonl [more.jsonl ...]
#   cat ~/.../.agda-explore/query-log.jsonl | scripts/tool-usage-report.sh
#
# Turns any deployment's log into the tool-tiering decision table (which tools
# are actually used, how often, how reliably) without transcript archaeology.
# One dependency: jq. Each log line is {ts,tool,args,dur_ms,ok,stale}.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "tool-usage-report: needs 'jq' on PATH" >&2; exit 2; }

report=$(cat "$@" 2>/dev/null | jq -s -r '
  map(select(.tool != null))
  | if length == 0 then empty else
      ( group_by(.tool)
        | map({
            tool:  .[0].tool,
            n:     length,
            errs:  (map(select(.ok    == false)) | length),
            stale: (map(select(.stale == true))  | length),
            durs:  (map(.dur_ms // 0) | sort)
          })
        | map(. + { p50: .durs[((.n-1)*0.50)|floor],
                    p95: .durs[((.n-1)*0.95)|floor] })
        | sort_by(-.n) ) as $rows
      | ($rows | map(.n) | add) as $total
      | (["TOOL","CALLS","ERR%","STALE%","p50ms","p95ms"] | @tsv),
        ($rows[] | [ .tool, .n,
                     ((.errs*100/.n)|floor), ((.stale*100/.n)|floor),
                     .p50, .p95 ] | @tsv),
        (["(total)", $total, "", "", "", ""] | @tsv)
    end
')

if [ -z "$report" ]; then
  echo "tool-usage-report: no tool-call lines found (empty or non-query-log input)." >&2
  exit 1
fi

# Align into columns when `column` is available; otherwise print raw TSV.
if command -v column >/dev/null 2>&1; then
  printf '%s\n' "$report" | column -t -s "$(printf '\t')"
else
  printf '%s\n' "$report"
fi
