//
//  TubeInteriorBendDragTests.swift
//  ProceduralGeometryExtensionTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import ProceduralGeometryExtension
import simd
@testable import UntoldEngine
import XCTest

@MainActor
final class TubeInteriorBendDragTests: XCTestCase {
    private var renderer: UntoldRenderer!

    /// Two interior corners: index 1 (back +X, forward +Y), index 2 (back +Y, forward +X).
    private let path: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 3, 0), SIMD3(5, 3, 0),
    ]

    override func setUp() async throws {
        try await super.setUp()
        renderer = UntoldRenderer.create()
        XCTAssertNotNil(renderer)
        ProceduralGeometryExtension.shared.install()
    }

    override func tearDown() async throws {
        destroyAllEntities()
        EngineExtensionRegistry.shared.unregister(id: ProceduralGeometryExtension.shared.id)
        try await super.tearDown()
    }

    func testInit_returnsNilForEndpointIndices() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        XCTAssertNil(TubeInteriorBendDrag(tubeId: entityId, index: 0))
        XCTAssertNil(TubeInteriorBendDrag(tubeId: entityId, index: path.count - 1))
    }

    func testInit_returnsNilForOutOfRangeIndex() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        XCTAssertNil(TubeInteriorBendDrag(tubeId: entityId, index: -1))
        XCTAssertNil(TubeInteriorBendDrag(tubeId: entityId, index: path.count))
    }

    /// Regression coverage for a real on-device bug: a U-shaped tube (`A` top-left, `B`
    /// bottom-left bend, `C` bottom-right bend, `D` top-right), dragging `B` straight toward `C`
    /// along their shared (locked) axis. `TubeGeometryGenerator`'s own miter clamp bounds any one
    /// ring to at most half of its shortest adjacent segment, but floors that at the tube's
    /// nominal radius — so as the `B`-`C` segment shrinks past the tube's diameter, both of its
    /// end rings sit at the full nominal radius while closer together than that radius allows,
    /// which self-intersects into a twisted sweep no per-ring clamp can undo after the fact. The
    /// fix is clamping `B`'s movement *before* the segment ever gets that short — this is what
    /// `effectiveMinimumSegmentLength` (floored at the tube's own diameter, not the fixed 0.05
    /// default) exists to guarantee, for whatever radius a caller picks, not just this demo's.
    /// `B` is never removed by this drag — see the type's own doc comment for why automatic
    /// topology changes on proximity are gone entirely, not just rebalanced.
    func testUpdate_danglingSegmentShorterThanDiameter_neverOccurs_forAnyRadius() throws {
        for radius: Float in [0.03, 0.1, 0.25] {
            let uShape: [SIMD3<Float>] = [
                SIMD3(0, 3, 0), SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 3, 0),
            ]
            let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
                controlPoints: uShape, radius: radius, radialSegments: 8
            ))
            var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

            // Drag B (index 1) toward C (index 2) in small steps, well past the point where the
            // segment between them would hit the floor.
            var step: Float = 0
            while step < 2.1 {
                step += 0.02
                let rawPosition = SIMD3<Float>(step, 0, 0)
                // Never removed — update() always returns a position now, never nil.
                XCTAssertNotNil(drag.update(rawPosition: rawPosition), "radius \(radius), step \(step)")

                // At every single frame, whatever control points currently exist must produce
                // finite, non-degenerate geometry — the bug reproduced here is a standing
                // distortion that persists frame over frame, not a one-time glitch.
                let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
                XCTAssertEqual(component.controlPoints.count, 4, "radius \(radius), step \(step)")
                let output = try XCTUnwrap(TubeGeometryGenerator.generate(
                    controlPoints: component.controlPoints, radius: radius, radialSegments: 8
                ))
                for position in output.positions {
                    XCTAssertTrue(
                        position.x.isFinite && position.y.isFinite && position.z.isFinite,
                        "radius \(radius), step \(step): non-finite vertex in \(component.controlPoints)"
                    )
                }

                // The segment between B and C must never be shorter than the tube's own
                // diameter — the actual condition that lets adjacent rings overlap into a
                // twisted sweep.
                let segmentLength = simd_distance(component.controlPoints[1], component.controlPoints[2])
                XCTAssertGreaterThanOrEqual(
                    segmentLength, radius * 2 - 1e-4,
                    "radius \(radius), step \(step): B-C segment thinner than the tube's own diameter"
                )

                // The actual regression this task reports: B and C's own rings must stay at the
                // exact, uncompressed 90-degree miter radius throughout the whole approach — never
                // shrunk to fit the shrinking segment between them, right up to (and including)
                // the frame where the clamp floor holds them at their closest.
                let expectedRingRadius = radius / Float(cos(Double.pi / 4))
                for (ringStart, center) in [(8, component.controlPoints[1]), (16, component.controlPoints[2])] {
                    for index in ringStart ..< ringStart + 8 {
                        let distance = simd_distance(output.positions[index], center)
                        XCTAssertEqual(
                            distance, expectedRingRadius, accuracy: 1e-3,
                            "radius \(radius), step \(step): ring at \(center) was shrunk below the tube's actual diameter"
                        )
                    }
                }
            }

            // The drag must have actually resolved the approach by holding B away from C, never
            // by silently leaving a corrupted tube — and never by removing B.
            let finalComponent = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
            XCTAssertEqual(finalComponent.controlPoints.count, 4)
        }
    }

    /// Same U-shape bug as `testUpdate_danglingSegmentShorterThanDiameter_neverOccurs_forAnyRadius`,
    /// but ending the drag with a single `end()` call well past the collapse point instead of a
    /// long run of `update()` calls — the actual shape of a real gesture, which typically ends in
    /// one release sample, not dozens of intermediate frames. `end()` deliberately never removes
    /// a bend (release jitter shouldn't delete structure), but before this fix it also never
    /// floored the locked segment's length the way `update()` does, so a release landing past the
    /// collapse point left the self-intersecting segment permanently in place with nothing left
    /// to fix it — exactly the on-device report this task describes.
    func testEnd_draggedBTowardC_neverLeavesSegmentShorterThanDiameter_forAnyRadius() throws {
        for radius: Float in [0.03, 0.1, 0.25] {
            let uShape: [SIMD3<Float>] = [
                SIMD3(0, 3, 0), SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 3, 0),
            ]
            let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
                controlPoints: uShape, radius: radius, radialSegments: 8
            ))
            var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

            // A single release sample almost on top of C (index 2) — well past where the segment
            // would naturally collapse.
            _ = drag.end(rawPosition: SIMD3(1.999, 0, 0))

            let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
            let output = try XCTUnwrap(TubeGeometryGenerator.generate(
                controlPoints: component.controlPoints, radius: radius, radialSegments: 8
            ))
            for position in output.positions {
                XCTAssertTrue(
                    position.x.isFinite && position.y.isFinite && position.z.isFinite,
                    "radius \(radius): non-finite vertex in \(component.controlPoints)"
                )
            }

            XCTAssertEqual(component.controlPoints.count, 4) // end() never removes
            let segmentLength = simd_distance(component.controlPoints[1], component.controlPoints[2])
            XCTAssertGreaterThanOrEqual(
                segmentLength, radius * 2 - 1e-4,
                "radius \(radius): B-C segment thinner than the tube's own diameter after end()"
            )
        }
    }

    func testUpdate_withReferenceRotation_locksToTheRotatedFrameNotWorldAxes() throws {
        // Same 90-degrees-around-Y rotation as the equivalent TubeEndpointDrag test — local +X
        // maps to world (0, 0, -1); local +Y is unaffected (it's the rotation axis). This is
        // `path` (see the class-level doc comment) with that rotation applied to every point, so
        // segment directions are this tube's own rotated local axes, not raw world ones.
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let rotatedPath: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, -2), SIMD3(0, 3, -2), SIMD3(0, 3, -5),
        ]
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: rotatedPath, radius: 0.1, radialSegments: 8, referenceRotation: rotation
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        // Small pull toward the back neighbor (index 0), along the rotated back axis (world
        // (0, 0, -1), not raw world +X or +Z) — same shape as
        // testUpdate_smallPullTowardBackNeighbor_locksBackAxisNotForward, just in this tube's
        // rotated frame instead of world space.
        let result = try XCTUnwrap(drag.update(rawPosition: SIMD3(0, 0, -1.7)))

        // Moved along the rotated back axis (approximate: sin/cos of a right-angle rotation
        // aren't exactly 0/1 in float32).
        XCTAssertLessThan(simd_distance(result, SIMD3(0, 0, -1.7)), 1e-6)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        // The forward chain (indices 2, 3) shifted rigidly by the same (0, 0, 0.3) delta.
        let expected: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 0, -1.7), SIMD3(0, 3, -1.7), SIMD3(0, 3, -4.7)]
        for (actual, expectedPoint) in zip(component.controlPoints, expected) {
            XCTAssertLessThan(simd_distance(actual, expectedPoint), 1e-6)
        }
    }

    func testUpdate_belowIntentThreshold_holdsAtOrigin() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))
        let result = drag.update(rawPosition: SIMD3(2.001, 0, 0))
        XCTAssertEqual(result, SIMD3(2, 0, 0))
    }

    func testUpdate_smallPullTowardBackNeighbor_locksBackAxisNotForward() throws {
        // Regression coverage: a raw signed dot-product comparison (dot(pull, back) vs
        // dot(pull, forward)) picks the WRONG axis here — pulling toward this bend's own back
        // neighbor gives dot(pull, back) == -1, which loses to the perpendicular forward axis's
        // dot of 0. This is exactly the motion collapsing a segment requires, so getting it wrong
        // would break bend removal far more often than not. The fix compares abs() of both.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        // Small pull back toward (0,0,0) — not enough to collapse, just to check which axis locked.
        let result = try XCTUnwrap(drag.update(rawPosition: SIMD3(1.7, 0, 0)))

        XCTAssertEqual(result, SIMD3(1.7, 0, 0)) // moved along X (back axis), not Y

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        // The forward chain (indices 2, 3) shifted rigidly by the same (-0.3, 0, 0) delta.
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(1.7, 0, 0), SIMD3(1.7, 3, 0), SIMD3(4.7, 3, 0)])
    }

    func testUpdate_slideAlongForwardAxis_shiftsBackChainRigidly() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        let result = try XCTUnwrap(drag.update(rawPosition: SIMD3(2, 0.5, 0)))

        XCTAssertEqual(result, SIMD3(2, 0.5, 0)) // moved along Y (forward axis)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        // Only index 0 (the back side) shifts; indices 2, 3 (beyond the locked forward segment)
        // are untouched.
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0.5, 0), SIMD3(2, 0.5, 0), SIMD3(2, 3, 0), SIMD3(5, 3, 0)])
    }

    func testUpdate_pullingPastCollapse_onBackSegment_clampsInsteadOfRemoving() throws {
        // radius 0.1, both ends of this segment are 90-degree corners... except index 0 (the
        // back-side far end here) is the path's own open end, not a corner — so its clearance is
        // zero, and effectiveMinimumSegmentLength.back = max(0.05, ownClearance(0.1) + 0) = 0.1,
        // not the tube's diameter (0.2). See `TubeGeometryGenerator.requiredMiterClearance`.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        // Pull back nearly to (0,0,0) — well past where the back segment (length 2) would drop
        // below the 0.1 floor.
        let result = try XCTUnwrap(drag.update(rawPosition: SIMD3(0.02, 0, 0)))

        // Never removed — clamped so the back segment holds at exactly the floor (0.1) instead,
        // with the non-locked (forward) side rigidly translated by the same delta, same as any
        // other point on this axis.
        XCTAssertEqual(result.x, 0.1, accuracy: 1e-4)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 4)
        XCTAssertEqual(component.controlPoints[0], SIMD3(0, 0, 0))
        XCTAssertEqual(component.controlPoints[1].x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[2].x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[2].y, 3, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[3].x, 3.1, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[3].y, 3, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[3].z, 0, accuracy: 1e-4)
    }

    func testUpdate_pullingPastCollapse_onForwardSegment_clampsInsteadOfRemoving() throws {
        // index 3 (the forward-side far end here) is also the path's own open end — same
        // reasoning as the back-segment test above: floor = max(0.05, 0.1 + 0) = 0.1.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 2))

        // Pull index 2 nearly onto index 3 (5,3,0) — well past where the forward segment
        // (length 3) would drop below the 0.1 floor.
        let result = try XCTUnwrap(drag.update(rawPosition: SIMD3(4.98, 3, 0)))

        XCTAssertEqual(result.x, 4.9, accuracy: 1e-4)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 4)
        XCTAssertEqual(component.controlPoints[0].x, 2.9, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[0].y, 0, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[1].x, 4.9, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[1].y, 0, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[2].x, 4.9, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[2].y, 3, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[3], SIMD3(5, 3, 0))
    }

    func testEnd_evenPastCollapseThreshold_neverRemovesButClampsToTheFloor() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        let result = drag.end(rawPosition: SIMD3(0.02, 0, 0)) // well past the collapse threshold

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 4) // untouched — no removal from end()
        // Floored at 0.1 (this bend's own 90-degree clearance against the path's open end at
        // index 0, which needs none of its own) — not driven to the raw input. `end()` never
        // removes a bend, but it must still floor the locked segment the same way `update()`
        // does, or a release lands on a self-intersecting segment with nothing left to fix it.
        // See `TubeInteriorBendDrag.clampedScalar`.
        XCTAssertEqual(result.x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(component.controlPoints[1], result)
    }
}
