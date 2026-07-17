# Packed graph form — layout and why the consumers can't use it (yet)

`agda-deps`' v2 `graph.json` has two shapes. The **expanded** form is what
every analysis here consumes (`AgdaGraph.Schema`). The **packed** form
(`--json-mode=packed`, the producer's *default*) is ~5× smaller on a large
corpus — base64-encoded little-endian typed arrays + CSR edges — and is
**oriented at the HTML viewer**, not the analyses.

`Nat.packed.json` / `Nat.expanded.json` here are the two forms of the same
tiny corpus (producer `test/Nat.agda`), kept as a concrete example.

## The gap (why `AgdaGraph.Schema` refuses packed with a pointer here)

The packed `defs` object carries only **`names`, `modules`, `states`, `x`,
`y`**. It does **not** carry the per-definition fields the analyses need:

| Field (expanded) | Used by | In packed? |
|------------------|---------|-----------|
| `kind`           | `search`/`roots --kind`, `locate`, primitive detection | ✗ |
| `line`           | `locate` file:line, the where-helper owner map | ✗ |
| `access`         | `unused` public/private | ✗ |
| `type` (sig)     | `type_of`, `find_lemma`, `similar_types` | ✗ |
| subterm hashes/depths | `similar_bodies`, `term-cluster` | ✗ |

Loading packed and defaulting those fields would **silently degrade**
`type_of` / `similar_*` / `find_lemma` / `unused` / `locate`-line /
`search --kind`. So the consumer refuses packed with an actionable error
rather than serving a crippled graph.

## Packed wire layout (for whoever implements the producer fix)

Top-level keys (no `mode`/`schemaVersion`): `v`, `nodeKeyVersion`,
`producer`, `modules` (JSON `[string]`), `files`, `moduleToFile` (b64 i32),
`defs {names:[string], modules:b64 i32, states:b64 i8, x:b64 f32, y:b64
f32}`, `edges {outOffsets, outTargets, inOffsets, inTargets}` (CSR, b64
i32), `definitionEdgesProvenance` (b64 i8, parallel to `outTargets`),
`moduleStates` (b64 i8, 1=failed), `entryModule`, `externalModules` (b64
i32 indices), plus viewer-only `searchIndex` / `fileTree` / `moduleTree` /
`modulePodLayout` / `moduleEdges` / `transitive*`.

- Typed arrays: base64 (RFC 4648) of **little-endian** Int32 / Int8 /
  Float32.
- Definitions are indexed `0..nDefs-1` by position in `defs.names` (sorted
  by `hashQName`); CSR `outTargets` reference those indices.
- CSR: `outTargets[outOffsets[i] .. outOffsets[i+1])` are def `i`'s out-edges.
- States: `0=Defined 1=Postulate 2=Hole 3=Failed`. Provenance:
  `0=signature 1=body 2=where 3=with 4=unknown`.

## The real fix (producer-side)

A **`packed-complete`** producer mode that keeps the compact CSR + base64
encoding but *adds* the analytical fields (`kind` / `line` / `access` /
`type` and the subterm hashes). The consumer side is then a small
base64-LE + CSR decoder into `ExpandedGraph`. Tracked in `Backlog.md`.
