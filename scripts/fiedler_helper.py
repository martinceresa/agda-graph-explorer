#!/usr/bin/env python3
"""Sparse spectral helper for AgdaOptimization.Fiedler.

Reads a JSON graph description, computes the smallest k+1 eigenpairs of
the normalised Laplacian L = I - D^(-1/2) A D^(-1/2), and writes the
eigenvalues / Fiedler vector / higher eigenvectors plus a per-module
restricted-Laplacian lambda_2 table.

Wire format
-----------

Input (--input PATH):
    {
      "n":       int,                       # number of nodes
      "edges":   [[u, v], ...],             # symmetrised pairs (both u->v and
                                            # v->u included, no self-loops)
      "modules": { "<int-id-as-str>": "<module-name>", ... }
    }

Output (--output PATH):
    {
      "n_total":              int,          # nodes in the input graph
      "n_component":          int,          # nodes in the largest connected
                                            # component (= length of vectors)
      "component_node_ids":   [int],        # original ids of those nodes,
                                            # in vector order
      "disconnected":         bool,         # True iff n_component < n_total
      "eigvals":              [float],      # k+1 ascending; eigvals[0] ~ 0
      "v2":                   [float],      # Fiedler vector (over component)
      "vk":                   [[float]],    # rows: v_3, v_4, ..., v_{k+1}
      "modules_lambda2":      { name: float }
                                            # per-module restricted L's lambda_2
                                            # (computed on the module's induced
                                            #  subgraph, largest component);
                                            # absent modules had < 2 nodes
                                            # or a single edge.
    }

Errors are reported with a clear stderr message; we exit with a non-zero
status so the Haskell driver can surface "is scipy installed?".

Exit codes:
    0  success
    1  generic helper error (bad input, eigsh failure, etc.)
    2  reserved — Python interpreter itself returns 2 for "file not
       found", so the Haskell driver should NOT use this code in
       fiedler_helper.py to avoid ambiguity.
    3  required Python dependency missing (numpy or scipy not importable)

Requires Python 3, numpy, scipy.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from typing import Any


def _die(msg: str, code: int = 1) -> None:
    print(f"fiedler_helper: {msg}", file=sys.stderr)
    sys.exit(code)


def _require_scipy() -> Any:
    try:
        import numpy as np  # noqa: F401
        import scipy.sparse as sp  # noqa: F401
        import scipy.sparse.linalg as spla  # noqa: F401
    except ImportError as e:
        # Exit code 3 = "Python dependency missing". The Haskell driver
        # discriminates this from a missing-helper-file (exit 2 from the
        # Python interpreter) and a generic helper failure (exit 1).
        _die(
            f"missing required Python dependency: {e}. "
            f"Install with: pip install scipy numpy",
            code=3,
        )
    import numpy as np
    import scipy.sparse as sp
    import scipy.sparse.linalg as spla

    return np, sp, spla


def _largest_component(np, sp, n: int, edges: list[list[int]]) -> tuple[list[int], list[list[int]]]:
    """Return (node_ids_in_LCC, edges_remapped_to_0..len(LCC)-1).

    Uses scipy.sparse.csgraph.connected_components on the symmetrised
    adjacency matrix.
    """
    from scipy.sparse.csgraph import connected_components

    if n == 0:
        return [], []
    if not edges:
        # Every node is its own component; pick node 0 as the LCC.
        return [0], []

    rows = np.array([u for u, _ in edges], dtype=np.int32)
    cols = np.array([v for _, v in edges], dtype=np.int32)
    data = np.ones(len(edges), dtype=np.float64)
    a = sp.csr_matrix((data, (rows, cols)), shape=(n, n))

    n_comp, labels = connected_components(a, directed=False, return_labels=True)
    if n_comp == 1:
        node_ids = list(range(n))
        return node_ids, edges

    # Pick the biggest component.
    counts = np.bincount(labels)
    biggest = int(np.argmax(counts))
    mask = labels == biggest
    node_ids = [int(i) for i in np.nonzero(mask)[0]]
    remap = {old: new for new, old in enumerate(node_ids)}
    new_edges = [[remap[u], remap[v]] for u, v in edges if mask[u] and mask[v]]
    return node_ids, new_edges


def _normalised_laplacian(np, sp, n: int, edges: list[list[int]]):
    """Build L = I - D^(-1/2) A D^(-1/2) as a CSR matrix.

    Isolated nodes get a row/column of zeros (and the diagonal stays 1 from
    the identity contribution) so eigsh stays well-defined.
    """
    if not edges:
        return sp.eye(n, format="csr", dtype=np.float64)

    rows = np.array([u for u, _ in edges], dtype=np.int32)
    cols = np.array([v for _, v in edges], dtype=np.int32)
    data = np.ones(len(edges), dtype=np.float64)
    a = sp.csr_matrix((data, (rows, cols)), shape=(n, n))

    # Make sure A is symmetric (caller should already symmetrise, but be safe).
    a = (a + a.T) * 0.5

    deg = np.asarray(a.sum(axis=1)).ravel()
    # D^(-1/2). For isolated nodes (deg=0) use 0 so the row vanishes.
    with np.errstate(divide="ignore"):
        d_inv_sqrt = np.where(deg > 0, 1.0 / np.sqrt(deg), 0.0)

    d_mat = sp.diags(d_inv_sqrt)
    norm_a = d_mat @ a @ d_mat
    eye = sp.eye(n, format="csr", dtype=np.float64)
    return (eye - norm_a).tocsr()


def _smallest_eigpairs(np, sp, spla, lap, k: int) -> tuple[Any, Any]:
    """Compute the k smallest eigenpairs of (symmetric) `lap`.

    Returns (eigvals_ascending, eigvecs_with_columns_matching_eigvals).
    Uses shift-invert when n is large enough for it to pay off; otherwise
    a dense fallback (n <= 200) is faster and more numerically robust.
    """
    n = lap.shape[0]
    k = min(k, max(1, n - 1))

    if n <= 200:
        # Dense fallback. Symmetric eigendecomposition.
        dense = lap.toarray()
        vals, vecs = np.linalg.eigh(dense)
        return vals[:k], vecs[:, :k]

    # eigsh with sigma=0 ("shift-invert mode") targets the smallest
    # eigenvalues directly. Fall back to plain `which='SM'` if that fails.
    try:
        vals, vecs = spla.eigsh(lap, k=k, sigma=0.0, which="LM")
        order = np.argsort(vals)
        return vals[order], vecs[:, order]
    except Exception:
        pass
    try:
        vals, vecs = spla.eigsh(lap, k=k, which="SM", tol=1e-6, maxiter=2000)
        order = np.argsort(vals)
        return vals[order], vecs[:, order]
    except Exception as e:
        _die(f"eigsh failed: {e}")


def _per_module_lambda2(
    np, sp, spla,
    n_total: int,
    edges: list[list[int]],
    modules: dict[str, str],
) -> dict[str, float]:
    """Compute lambda_2 of the normalised Laplacian of each module's
    induced subgraph (restricted to its largest connected component).

    Modules with fewer than 2 nodes or whose induced subgraph has no
    edges are omitted: lambda_2 is not meaningful there.
    """
    # Group node ids by module.
    by_mod: dict[str, list[int]] = defaultdict(list)
    for k, v in modules.items():
        try:
            nid = int(k)
        except ValueError:
            continue
        if 0 <= nid < n_total:
            by_mod[v].append(nid)

    # Build an adjacency set for fast edge restriction.
    adj: dict[int, set[int]] = defaultdict(set)
    for u, v in edges:
        adj[u].add(v)
        adj[v].add(u)

    result: dict[str, float] = {}
    for modname, members in by_mod.items():
        if len(members) < 2:
            continue
        member_set = set(members)
        # Build local edge list (already symmetric since we did adj symmetric).
        local_edges_set: set[tuple[int, int]] = set()
        for u in members:
            for v in adj.get(u, ()):
                if v in member_set:
                    a, b = (u, v) if u < v else (v, u)
                    local_edges_set.add((a, b))
        if not local_edges_set:
            continue

        # Re-index members to [0..len(members)-1].
        remap = {old: new for new, old in enumerate(members)}
        local_edges = []
        for a, b in local_edges_set:
            local_edges.append([remap[a], remap[b]])
            local_edges.append([remap[b], remap[a]])

        # Restrict to largest component within the module.
        _ids, comp_edges = _largest_component(np, sp, len(members), local_edges)
        if len(_ids) < 2 or not comp_edges:
            continue

        lap = _normalised_laplacian(np, sp, len(_ids), comp_edges)
        try:
            vals, _ = _smallest_eigpairs(np, sp, spla, lap, 2)
        except SystemExit:
            # Skip modules that blow up; don't take the whole run down.
            continue
        if len(vals) >= 2:
            # Clamp tiny negatives from numerical noise.
            l2 = float(max(0.0, vals[1]))
            result[modname] = l2

    return result


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", required=True, help="path to input JSON")
    p.add_argument("--output", required=True, help="path to output JSON")
    p.add_argument("--k", type=int, default=5,
                   help="number of non-trivial eigenpairs (excl. lambda_1=0)")
    args = p.parse_args()

    np, sp, spla = _require_scipy()

    with open(args.input, "r") as fh:
        try:
            payload = json.load(fh)
        except json.JSONDecodeError as e:
            _die(f"could not parse input JSON: {e}")

    n_total = int(payload.get("n", 0))
    edges = payload.get("edges", [])
    modules = payload.get("modules", {}) or {}

    if n_total <= 0:
        _die("input graph has zero nodes")

    # Drop self-loops (they don't contribute to a normalised Laplacian
    # under our edge convention) and dedup.
    edge_set: set[tuple[int, int]] = set()
    for e in edges:
        if not isinstance(e, list) or len(e) != 2:
            continue
        u, v = int(e[0]), int(e[1])
        if u == v:
            continue
        if not (0 <= u < n_total and 0 <= v < n_total):
            continue
        edge_set.add((u, v))
        edge_set.add((v, u))
    sym_edges = [[a, b] for a, b in sorted(edge_set)]

    # Restrict to the largest connected component for the global spectrum.
    comp_ids, comp_edges = _largest_component(np, sp, n_total, sym_edges)
    if not comp_ids:
        _die("largest component is empty")
    n_comp = len(comp_ids)
    disconnected = n_comp < n_total

    if disconnected:
        print(
            f"fiedler_helper: graph is disconnected; using largest "
            f"component ({n_comp}/{n_total} nodes).",
            file=sys.stderr,
        )

    if n_comp < 3:
        # We still emit something so the Haskell side can render a degenerate
        # "the component is too small to spectrally bisect" report.
        out = {
            "n_total": n_total,
            "n_component": n_comp,
            "component_node_ids": comp_ids,
            "disconnected": disconnected,
            "eigvals": [0.0] * max(1, n_comp),
            "v2": [],
            "vk": [],
            "modules_lambda2": {},
        }
        with open(args.output, "w") as fh:
            json.dump(out, fh)
        return 0

    lap = _normalised_laplacian(np, sp, n_comp, comp_edges)
    # We want k+1 eigenpairs: the trivial lambda_1 + k non-trivial ones.
    k_total = max(2, int(args.k) + 1)
    vals, vecs = _smallest_eigpairs(np, sp, spla, lap, k_total)

    # eigvals[0] should be ~ 0 (connected component); v2 is column 1.
    eigvals = [float(x) for x in vals]
    if len(eigvals) < 2:
        _die("could not extract a non-trivial eigenpair")

    v2 = [float(x) for x in vecs[:, 1]]
    vk: list[list[float]] = []
    # vecs[:, 2..k_total-1] are v_3 onward; package as a list of rows.
    for j in range(2, vecs.shape[1]):
        vk.append([float(x) for x in vecs[:, j]])

    modules_lambda2 = _per_module_lambda2(np, sp, spla, n_total, sym_edges, modules)

    out = {
        "n_total": n_total,
        "n_component": n_comp,
        "component_node_ids": comp_ids,
        "disconnected": disconnected,
        "eigvals": eigvals,
        "v2": v2,
        "vk": vk,
        "modules_lambda2": modules_lambda2,
    }
    with open(args.output, "w") as fh:
        json.dump(out, fh)
    return 0


if __name__ == "__main__":
    sys.exit(main())
