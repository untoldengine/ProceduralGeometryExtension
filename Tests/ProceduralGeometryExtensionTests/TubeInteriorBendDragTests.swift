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

    func testUpdate_collapsingBackSegment_removesBendAndReconnectsPerfectlyAxisAligned() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        // Pull back nearly to (0,0,0) — the back segment (length 2) drops well below the 0.05
        // minimum.
        let result = drag.update(rawPosition: SIMD3(0.02, 0, 0))

        XCTAssertNil(result) // signals: this bend no longer exists
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3)
        // Reconnected by exactly the original forward vector (0,3,0) from (0,0,0) — not merely
        // "close" to axis-aligned, exactly so, confirming the exact-delta snap.
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 3, 0), SIMD3(3, 3, 0)])
    }

    func testUpdate_collapsingForwardSegment_removesBendAndReconnectsPerfectlyAxisAligned() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 2))

        // Pull index 2 nearly onto index 3 (5,3,0) — the forward segment (length 3) collapses.
        let result = drag.update(rawPosition: SIMD3(4.98, 3, 0))

        XCTAssertNil(result)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3)
        XCTAssertEqual(component.controlPoints, [SIMD3(3, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 3, 0)])
    }

    func testEnd_evenPastCollapseThreshold_neverRemoves() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeInteriorBendDrag(tubeId: entityId, index: 1))

        let result = drag.end(rawPosition: SIMD3(0.02, 0, 0)) // well past the collapse threshold

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 4) // untouched — no removal from end()
        XCTAssertEqual(component.controlPoints[1], result)
    }
}
