# ProceduralGeometryExtension

An `EngineExtension` that turns a path of 3D control points into a renderable
tube mesh, built on [UntoldEngine](https://github.com/untoldengine/UntoldEngine)'s
public API as a standalone Swift package (no engine-internal access required
beyond the `Mesh.makeMesh` factory).

## Features

- **TubeGeometryGenerator** — pure CPU sweep along the path using a
  rotation-minimizing frame, with mitered joins at turns.
- **TubePathComponent + ProceduralGeometryExtension** — entity creation, an
  editing API (`setControlPoints`/`setRadius`/`setRadialSegments`/`setCaps`),
  and a per-tick safety net that catches component changes made outside the
  editing API.
- **Interactive fast path** — same-topology updates (the common case while
  dragging a control point) write new vertex data directly into the existing
  GPU buffer instead of rebuilding the mesh, for XR editing without
  per-frame allocation.
- **Scene persistence** via `encodeCustomComponent`, bypassing the engine's
  lossy generic `.procedural` asset-name restore path.

## Requirements

This package depends on a sibling checkout of UntoldEngine at
`../../UntoldEngine` (see `Package.swift`). If you move this package
elsewhere, update the dependency path or switch to the canonical repository
URL.

- Swift tools 6.0
- macOS 14+, iOS 17+, visionOS 2+

## Testing

```sh
swift test
```

29 tests cover geometry math, entity integration, editing, the fast path,
and save/load round-trips.
