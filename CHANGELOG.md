# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- `ProceduralGeometryExtension`: procedural tube generation.
  - `TubeGeometryGenerator`: pure CPU sweep along a path of 3D control
    points using a rotation-minimizing frame, with mitered joins at turns.
  - `TubePathComponent` + `ProceduralGeometryExtension`: entity creation,
    an editing API (`setControlPoints`/`setRadius`/`setRadialSegments`/
    `setCaps`), and a per-tick safety net that catches component changes
    made outside the editing API.
  - Interactive fast path: same-topology updates write new vertex data
    directly into the existing GPU buffer instead of rebuilding the mesh,
    for XR editing without per-frame allocation.
  - Scene persistence via `encodeCustomComponent`, bypassing the engine's
    lossy generic `.procedural` asset-name restore path.
  - 29 tests covering geometry math, entity integration, editing, the
    fast path, and save/load round-trips.
