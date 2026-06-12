"""Battle-test matrix for the `agda-explore` MCP stdio server.

Each Case spawns the daemon fresh, feeds a newline-delimited JSON-RPC sequence
(initialize -> notifications/initialized -> tools/call...) on stdin, and lets
the daemon exit on EOF. The daemon writes one JSON object per line to stdout;
we assert with stdout_contains on the (JSON-escaped) tool-result text. A clean
RPC-level error still exits 0 with isError in the payload — so error cases
assert the daemon stays up and emits the error text, not a process failure.

Tools (from src/AgdaMcp/Tools.hs): locate callers callees impact path roots
type_of similar_types similar_bodies search unused rebuild status.
"""
from __future__ import annotations

import json
from harness import Case

# The corpus-specific example identifiers (a function, a second function in the
# same module, a postulate, a module prefix, a substring query, a guaranteed-
# absent name) come from the project descriptor (config.Ctx.ex_*), supplied per
# corpus via the AGE_EX_* env vars. They must match real nodes in the graph
# fixture, so they are read from ctx inside cases() rather than hardcoded here.

PROTO = "2025-06-18"


def _rpc(*calls) -> bytes:
    """Build a JSON-RPC stdin blob: handshake + the given tools/call dicts.

    Each call is (tool_name, arguments_dict). Returns bytes ending in newline.
    """
    seq = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": PROTO, "capabilities": {},
                    "clientInfo": {"name": "battletest", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
    ]
    for i, (tool, args) in enumerate(calls, start=2):
        seq.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                    "params": {"name": tool, "arguments": args}})
    return ("\n".join(json.dumps(m) for m in seq) + "\n").encode()


def _raw(*lines: str) -> bytes:
    """Build a raw stdin blob from verbatim lines (for malformed-input tests)."""
    return ("\n".join(lines) + "\n").encode()


def cases(ctx):
    exp   = str(ctx.bin("explore"))
    deps  = str(ctx.bin("deps"))
    unbin = str(ctx.bin("unused"))
    gfull = str(ctx.graph_full)
    gbase = str(ctx.graph_base)
    corpus = str(ctx.corpus)

    # Corpus-specific example identifiers (from the descriptor; AGE_EX_* env).
    FN       = ctx.ex_fn               # a Defined function
    FN2      = ctx.ex_fn2              # another function in the same module
    POST     = ctx.ex_postulate       # a postulate
    MODPFX   = ctx.ex_module_prefix   # a module subtree
    MISSING  = ctx.ex_missing         # a guaranteed-absent name
    SEARCH   = ctx.ex_search          # a substring that matches something
    FN_MODULE  = FN.rsplit(".", 1)[0] if "." in FN else FN     # module path of FN
    FN2_SUFFIX = FN2.rsplit(".", 1)[-1]                         # dotted-suffix of FN2

    # Preloaded launch: serve graph-full, point project at the corpus so the
    # `unused` tool resolves scope, and wire the helper binaries so `unused`
    # (and any rebuild) can find them.
    pre = [exp, "--graph", gfull, "--project", corpus,
           "--agda-deps-bin", deps, "--agda-unused-bin", unbin]
    pre_base = [exp, "--graph", gbase, "--project", corpus,
                "--agda-unused-bin", unbin]

    def C(name, args_seq, note, cmd=None, stdin=None, timeout=120,
          contains=None, exit0=True, extra=None):
        checks = [{"type": "no_crash"}]
        if exit0:
            checks.append({"type": "exit_eq", "v": 0})
        checks.append({"type": "stdout_nonempty"})
        for s in (contains or []):
            checks.append({"type": "stdout_contains", "v": s})
        checks += (extra or [])
        return Case(area="explore", name=name, cmd=cmd or pre,
                    stdin=stdin if stdin is not None else _rpc(*args_seq),
                    note=note, timeout=timeout, checks=checks)

    cs = []

    # --- lifecycle ---------------------------------------------------------
    cs.append(C("init-only", [], "initialize handshake (no tool call)",
                stdin=_rpc(), contains=['"serverInfo"', "agda-explore"]))
    cs.append(C("tools-list", [], "tools/list advertises all 13 tools",
                stdin=_raw(
                    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": {"protocolVersion": PROTO, "capabilities": {},
                                           "clientInfo": {"name": "bt", "version": "1"}}}),
                    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})),
                contains=['"locate"', '"callers"', '"callees"', '"impact"', '"path"',
                          '"roots"', '"type_of"', '"similar_types"', '"similar_bodies"',
                          '"search"', '"unused"', '"rebuild"', '"status"']))
    cs.append(C("ping", [], "ping replies",
                stdin=_raw(
                    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": {"protocolVersion": PROTO, "capabilities": {},
                                           "clientInfo": {"name": "bt", "version": "1"}}}),
                    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"})),
                contains=['"id":2']))
    cs.append(C("status", [("status", {})], "status reports config + snapshot",
                contains=["agda-explore status", "project root", "graph file"]))

    # --- locate ------------------------------------------------------------
    cs.append(C("locate-fqn", [("locate", {"name": FN})],
                "locate by fully-qualified name", contains=[FN_MODULE]))
    cs.append(C("locate-suffix", [("locate", {"name": FN2_SUFFIX})],
                "locate by dotted-suffix", contains=[FN2_SUFFIX]))
    cs.append(C("locate-postulate", [("locate", {"name": POST})],
                "locate a postulate", contains=["DebugTrace"]))

    # --- callers / callees (params: transitive, module_prefix, provenance, by_module, limit)
    cs.append(C("callers-direct", [("callers", {"name": FN})], "direct callers"))
    cs.append(C("callers-transitive", [("callers", {"name": FN, "transitive": True})],
               "transitive callers"))
    cs.append(C("callers-bymodule", [("callers", {"name": FN, "by_module": True})],
               "callers per-module summary"))
    cs.append(C("callers-prov-body", [("callers", {"name": FN, "provenance": "body"})],
               "callers filtered to body-provenance edges"))
    cs.append(C("callers-modprefix", [("callers", {"name": FN, "module_prefix": "Protocol"})],
               "callers under a module prefix"))
    cs.append(C("callers-limit", [("callers", {"name": FN, "limit": 3})], "callers with small limit"))
    cs.append(C("callees-direct", [("callees", {"name": FN2})], "direct callees"))
    cs.append(C("callees-transitive", [("callees", {"name": FN2, "transitive": True})],
               "transitive callees"))
    cs.append(C("callees-bymodule", [("callees", {"name": FN2, "by_module": True})],
               "callees per-module summary"))
    cs.append(C("callees-prov-sig", [("callees", {"name": FN2, "provenance": "signature"})],
               "callees filtered to signature-provenance edges"))

    # --- impact ------------------------------------------------------------
    cs.append(C("impact", [("impact", {"name": FN})], "impact / blast radius by module"))
    cs.append(C("impact-limit", [("impact", {"name": FN, "limit": 5})], "impact with limit"))

    # --- path --------------------------------------------------------------
    cs.append(C("path", [("path", {"from": FN2, "to": FN})], "shortest dependency chain"))
    cs.append(C("path-k", [("path", {"from": FN2, "to": FN, "k": 3})], "k distinct paths"))
    cs.append(C("path-nopath", [("path", {"from": FN, "to": FN2})],
                "reverse direction (likely no forward path) handled cleanly"))

    # --- roots -------------------------------------------------------------
    cs.append(C("roots", [("roots", {"name": FN})], "transitive postulate/primitive roots"))
    cs.append(C("roots-bymodule", [("roots", {"name": FN, "by_module": True})],
               "roots per-module summary"))
    cs.append(C("roots-nochains", [("roots", {"name": FN, "chains": False})], "roots without witness chains"))
    cs.append(C("roots-kind", [("roots", {"name": FN, "kind": "postulate"})], "roots restricted to postulates"))

    # --- type_of (needs signatures = graph-full) ---------------------------
    cs.append(C("type_of", [("type_of", {"name": FN})], "elaborated type signature",
               contains=[":"]))
    cs.append(C("type_of-source", [("type_of", {"name": FN, "source": True})],
               "as-written source signature"))

    # --- similar_types / similar_bodies (graph-full) -----------------------
    cs.append(C("similar_types", [("similar_types", {"name": FN, "limit": 5})],
               "type-shape neighbours (WL fingerprints)"))
    cs.append(C("similar_types-minsim", [("similar_types", {"name": FN, "min_sim": 0.9})],
               "similar_types high threshold"))
    cs.append(C("similar_bodies", [("similar_bodies", {"name": FN, "limit": 5})],
               "body subterm-hash neighbours"))

    # --- search ------------------------------------------------------------
    cs.append(C("search-substr", [("search", {"query": SEARCH, "limit": 5})],
               "search by substring", contains=["match", SEARCH]))
    cs.append(C("search-empty-kind", [("search", {"query": "", "kind": "postulate"})],
               "list-all-of-kind via empty query", contains=["postulate"]))
    cs.append(C("search-state", [("search", {"query": "", "state": "defined", "limit": 5})],
               "filter by lifecycle state"))
    cs.append(C("search-modprefix", [("search", {"query": "", "module_prefix": MODPFX, "limit": 10})],
               "list a module subtree"))
    cs.append(C("search-toplevel", [("search", {"query": "", "module_prefix": MODPFX,
                                                 "top_level_only": True, "limit": 10})],
               "drop where/anon locals"))

    # --- unused (shells to agda-unused) ------------------------------------
    cs.append(C("unused-default", [("unused", {})], "unused tool, default scope",
               timeout=180, contains=["scope:"]))
    cs.append(C("unused-kinds", [("unused", {"kinds": "all", "scope": MODPFX})],
               "unused tool scoped to a module, kinds=all", timeout=180, contains=["kinds: all"]))

    # --- rebuild / status in preloaded mode --------------------------------
    cs.append(C("rebuild-preloaded", [("rebuild", {})],
               "rebuild in preloaded mode (no entry) — must fail cleanly, not crash",
               contains=[]))

    # --- graph-base (plain: no signatures, no term hashes) -----------------
    cs.append(C("base-search", [("search", {"query": SEARCH, "limit": 3})],
               "search on the plain 15k-node base graph", cmd=pre_base))
    cs.append(C("base-locate", [("locate", {"name": FN})],
               "locate on base graph", cmd=pre_base))
    cs.append(C("base-type_of-degrade", [("type_of", {"name": FN})],
               "type_of on a graph WITHOUT signatures — must degrade gracefully, not crash",
               cmd=pre_base))
    cs.append(C("base-similar_bodies-degrade", [("similar_bodies", {"name": FN})],
               "similar_bodies on a graph WITHOUT term hashes — must degrade gracefully",
               cmd=pre_base))

    # --- error / edge handling (daemon stays up, exits 0, emits error text) -
    cs.append(C("err-unknown-tool",
               stdin=_rpc(("no_such_tool", {})), args_seq=None,
               note="unknown tool name -> clean RPC error",
               contains=["unknown tool"]))
    cs.append(C("err-locate-notfound", [("locate", {"name": MISSING})],
               "locate a nonexistent name -> clean not-found, not crash"))
    cs.append(C("err-missing-name", [("locate", {})],
               "locate with no `name` arg -> clean error", contains=["name"]))
    cs.append(C("err-path-missing-arg", [("path", {"from": FN})],
               "path missing `to` -> clean error", contains=["path requires"]))
    cs.append(C("err-malformed-json",
               args_seq=None,
               stdin=_raw(
                   json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                               "params": {"protocolVersion": PROTO, "capabilities": {},
                                          "clientInfo": {"name": "bt", "version": "1"}}}),
                   "{ this is not valid json",
                   json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                               "params": {"name": "search", "arguments": {"query": SEARCH}}})),
               note="malformed JSON line -> parse error, daemon keeps serving",
               contains=["parse error", "match"]))
    cs.append(C("err-call-before-init",
               args_seq=None,
               stdin=_raw(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": {"name": "search", "arguments": {"query": SEARCH}}})),
               note="tools/call before initialize (daemon does not enforce ordering)"))

    # --- live mode (regenerates the graph by running agda-deps) -------------
    live_cmd = [exp, "--entry", corpus + "/" + ctx.corpus_main, "-i", corpus,
                "--project", corpus, "--agda-deps-bin", deps,
                "--no-term-hashes", "--no-signatures",
                "--out-dir", "/tmp/age_live_out"]
    cs.append(Case(area="explore", name="live-regenerate",
                   cmd=live_cmd, stdin=_rpc(("search", {"query": SEARCH, "limit": 3}),
                                            ("status", {})),
                   note="LIVE mode: spawn agda-deps to (re)generate the graph, then query (slow)",
                   timeout=600,
                   checks=[{"type": "no_crash"}, {"type": "exit_eq", "v": 0},
                           {"type": "stdout_nonempty"}, {"type": "stdout_contains", "v": "match"},
                           {"type": "max_seconds", "v": 300}]))

    return cs
