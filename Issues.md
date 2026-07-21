# Issues

Open defects on the graph consumers. Resolved issues live in
[Changelog.md](Changelog.md). For forward-looking work see [TODO.md](TODO.md);
for deferred/refused ideas see [Backlog.md](Backlog.md) and
[Deferred.md](Deferred.md).

---

## Open

### I7 — `agda-optimization` parallel subcommands crash under `-N` on large graphs

The `parListChunk rdeepseq` reductions in the analyses corrupt the heap when run
multicore on a stdlib-scale graph. Not Phase-1-specific: reproduced on both the
existing `polyglot` and the new `hint-bench` subcommand.

Repro (GHC 9.12.4, `agda-optimization` built `-threaded -with-rtsopts=-N`, on a
~5–7k-def expanded sig graph such as MCPBenchArena's `live-sig.json` /
`midproj-sig.json`):

```
agda-optimization polyglot   <large-sig>.json          # SIGSEGV (exit 139)
agda-optimization hint-bench <large-sig>.json --strategy all   # RTS abort:
    internal error: ARR_WORDS object (0x…) entered!  (SIGABRT, exit 134)
```

Both faults are the same class (heap object entered as a closure). `+RTS -N1`
runs clean and deterministic on the identical input, so it is a
parallel-runtime interaction, not a decode or logic error (a schema mismatch
would be a clean decode failure). The small committed fixtures (`test/deps.json`,
`.agda-explore/deps.json`) do not trigger it — it is scale-gated.

Scope: `agda-optimization` only (the `agda-explore` daemon and the offline test
suite are single-threaded here and unaffected). Workaround: run the affected
subcommands with `+RTS -N1`. Root cause unconfirmed — either a GHC 9.12 `-N`
bug on this heap shape or an unsafe sharing pattern in the shared reduction
helpers; needs bisection (try a narrower `-N2`, a newer GHC, and `-fno-omit-yields`)
before deciding between an upstream GHC report and a code fix.

### I3 — where grep+agda beat the MCP (the "anti-benchmark")

Not a single defect — a documented trade-off of a snapshot graph index. An
agent with `rg` + `agda` + Read beats one using the MCP on small, single-file,
fast-changing work, across four clusters:

1. **Snapshot staleness.** A fixed `--graph` never reflects the working tree and
   even a live graph lags: renames/additions/deletions can be stale until a
   rebuild fires. Mitigated by the staleness footers (`# stale:` / `# partial:`)
   and content-hash in `status`, but the underlying lag is inherent. `rg`/`agda`
   always read current bytes.
2. **Definition+edge index only.** The graph models Agda defs and their edges —
   nothing else. Misses `rg` finds instantly: defs outside the entry closure,
   text in comments/strings/pragmas, import/`using` lists, non-Agda manifests,
   numeric literals, regex/alternation queries. The closure blind spot matters
   most for a soundness audit (partial coverage is flagged, not silent).
3. **Round-trip + build tax.** A `type_of`/`locate` query is ~250× the latency
   of `rg` for an already-located single-file lookup, and the initial graph
   build costs seconds-to-minutes. The MCP only amortizes on large, stable,
   multi-file codebases reused across many cross-file queries.

**Takeaway:** the MCP earns its keep on **large, stable, multi-file** codebases
with **iterative proof development** — not on small fast-changing single files.

Harness (in the sibling VerinaAgda repo): `scripts/anti_bench.py`; the
complementary "where the MCP wins" benches are `scripts/micro_bench.py` (read
tools) and `scripts/micro_bench_live.py` (interactive).

### I6c — producer should distinguish a parse-dropped def set from a trustworthy partial

Cross-repo, filed for `agda-deps`. Under default `--keep-going` a parse error
emits a *partial* graph; the consumer infers trouble from `ldFailed` + the
content hash and flags every affected answer (`# partial:` footer), but cannot
tell "partial-but-trustworthy" from "defs silently dropped". The producer
recording parse failures distinctly would make this first-class. See
[Changelog.md](Changelog.md) for the consumer-side mitigation (I6).
