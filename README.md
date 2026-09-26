# ProceduralGeometryExtension

A reusable [UntoldEngine](https://github.com/untoldengine/UntoldEngine) extension for procedural pipe/duct-style geometry: define a shape as a path of 3D control points, get a renderable tube mesh, and edit it — reshape, extend, bend, undo — at runtime, including live during XR interaction.

Ships as a standalone Swift package with no engine-internal access beyond public API (`Mesh.makeMesh(positions:...)`, `boundingBox`, `markEntityPickingDirty`). It has no knowledge of picking, gestures, hand tracking, or any particular application — see [Interactive dragging](#interactive-dragging) below.

For a complete, working XR integration example, see the [`ProceduralGeometry` demo app](https://github.com/untoldengine/UntoldArcade/tree/main/ProceduralGeometry).

## Requirements

- Swift tools 6.0, macOS 14+ / iOS 17+ / visionOS 2+.
- `UntoldEngine` on its `develop` branch. This package uses a few APIs (`Mesh.makeMesh(positions:...)`, `boundingBox`, `markEntityPickingDirty`) added by [PR #1214](https://github.com/untoldengine/UntoldEngine/pull/1214), which merged into `develop` but hasn't shipped in a tagged release yet — switch to a version requirement once it has.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/untoldengine/UntoldEngine.git", branch: "develop"),
    .package(url: "https://github.com/untoldengine/ProceduralGeometryExtension.git", branch: "main"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "UntoldEngineXR", package: "UntoldEngine"), // or UntoldEngineAR
            .product(name: "ProceduralGeometryExtension", package: "ProceduralGeometryExtension"),
        ]
    ),
]
```

## Quick start

```swift
// Once, at startup:
ProceduralGeometryExtension.shared.install()

// Create a tube:
let tubeId = ProceduralGeometryExtension.shared.createTubeEntity(
    controlPoints: [SIMD3(0, 1, -1), SIMD3(0.5, 1, -1), SIMD3(0.5, 1, -1.5)], // path, world space, meters — min 2 points
    radius: 0.03,
    radialSegments: 16,
    capStart: true,
    capEnd: true,
    bendRadius: 0.08, // optional — rounds interior corners instead of a sharp miter joint
    name: "MyPipe"
)
```

## Features

- **`TubeGeometryGenerator`** — pure CPU sweep along a path using a rotation-minimizing (parallel-transport) frame, so the cross-section doesn't twist along the length. Sharp miter joints by default; tangent-arc rounded corners via `PathCornerRounding` when `bendRadius` is set. Both are hardened against degenerate near-180-degree corners (found through real interactive testing, not just inspection — see `TubeGeometryGeneratorTests`/`PathCornerRoundingTests`).
- **`TubePathComponent` + `ProceduralGeometryExtension`** — entity creation and a full editing API (below), plus a per-tick safety net that catches component changes made outside that API (e.g. a scene load).
- **Interactive fast path** — same-topology updates (the common case while dragging a control point) write new vertex data directly into the existing GPU buffer instead of rebuilding the mesh, for XR editing without per-frame allocation.
- **`TubeEndpointDrag` / `TubeInteriorBendDrag` / `TubeTranslationDrag`** — ready-to-use interactive editing logic: extend an endpoint with automatic 90-degree bend creation on turn and undo-by-reversal, reshape/remove an existing bend by sliding it along one of its two segments, or move an entire tube as a rigid body. None of the three knows anything about picking or rendering — see below.
- **Scene persistence** via `encodeCustomComponent`, bypassing the engine's lossy generic `.procedural` asset-name restore path.

## Editing API

All calls return `Bool` (`false` = no-op, e.g. an invalid index) and update the mesh immediately — same-topology edits take the in-place fast path automatically, topology changes trigger a full rebuild.

| Call | What it does |
|---|---|
| `setControlPoints(entityId:_:)` | Replace the whole path |
| `insertControlPoint(entityId:at:_:)` | Insert a new point at an index |
| `removeControlPoint(entityId:at:)` | Remove a point (refuses if it would drop below 2) |
| `setRadius(entityId:_:)` | Change the uniform cross-section radius |
| `setBendRadius(entityId:_:)` | Set (or clear, with `nil`) corner rounding |
| `setRadialSegments(entityId:_:)` | Change cross-section resolution |
| `setCaps(entityId:capStart:capEnd:)` | Toggle end caps |

The underlying data lives in `TubePathComponent` (`controlPoints`, `radius`, `radialSegments`, `capStart`, `capEnd`, `bendRadius`), readable via `scene.get(component: TubePathComponent.self, for: tubeId)`.

## Interactive dragging

`TubeEndpointDrag`, `TubeInteriorBendDrag`, and `TubeTranslationDrag` implement the actual axis-locking/turn-detection/undo/rigid-shift logic behind interactive editing. Each consumes a raw 3D position every frame — from wherever you get one: XR pinch tracking, a mouse, a game controller, a test — and reports back where the dragged point (or, for `TubeTranslationDrag`, the whole tube) should now be. None of the three creates entities, does picking, or knows your app exists; how you decide *what's* being dragged (a picking proxy, a gizmo, proximity-based selection) is entirely up to the consuming app.

**`TubeEndpointDrag`** — drag a tube's start or end:

```swift
var drag = TubeEndpointDrag(tubeId: tubeId, isStart: false) // nil if the tube doesn't exist

// Every frame the gesture continues:
let position = drag?.update(rawPosition: currentHandPosition)

// On the frame the gesture ends — see the doc comment on `end` for why this
// isn't just the last `update` call: release is commonly accompanied by a
// small involuntary movement that `update`'s turn detection would otherwise
// treat as deliberate.
let finalPosition = drag?.end(rawPosition: currentHandPosition)
```

**`TubeInteriorBendDrag`** — reshape or remove an existing bend:

```swift
var bendDrag = TubeInteriorBendDrag(tubeId: tubeId, index: bendIndex)

if let position = bendDrag?.update(rawPosition: currentHandPosition) {
    // still exists — move your visual representation here
} else {
    // this call removed the bend (a segment collapsed) — stop the drag
}
```

**`TubeTranslationDrag`** — move an entire tube as a rigid body, unconstrained (no axis locking — moving a tube doesn't change any angle *between* its own segments, so there's no structural reason to restrict it):

```swift
var moveDrag = TubeTranslationDrag(tubeId: tubeId, dragOrigin: currentHandPosition)

// Every frame the gesture continues — no `end` call needed, since a rigid
// shift has no structural change for release jitter to spuriously trigger:
moveDrag?.update(rawPosition: currentHandPosition)
```

`TubeEndpointDrag` and `TubeInteriorBendDrag` also expose a `Configuration` struct for tuning sensitivity/thresholds without forking the type — see their doc comments for defaults and what each knob controls.

## Testing

```sh
swift test
```

89 tests cover geometry math (including degenerate-corner hardening), entity integration, the full editing API, all three interactive drag types (driven with synthetic positions, no XR required), the fast path, and save/load round-trips.
