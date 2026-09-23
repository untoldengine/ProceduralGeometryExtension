//
//  TubeEndpointDragTests.swift
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

/// `TubeEndpointDrag` has no XR/picking/rendering dependency of its own — these tests drive it
/// with synthetic raw positions, standing in for whatever an application's own input layer would
/// supply frame to frame (see the ProceduralGeometry demo for the XR-specific glue).
@MainActor
final class TubeEndpointDragTests: XCTestCase {
    private var renderer: UntoldRenderer!

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

    func testInit_returnsNilForEntityWithoutTubePathComponent() {
        let entityId = createEntity()
        XCTAssertNil(TubeEndpointDrag(tubeId: entityId, isStart: false))
    }

    func testUpdate_extendingAlongLockedAxis_movesTipWithoutInsertingABend() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // no bend — still a straight extension
        XCTAssertEqual(component.controlPoints[1], result)
        XCTAssertEqual(result.x, 2.5, accuracy: 1e-4)
    }

    func testUpdate_turningToADifferentAxis_insertsA90DegreeBend() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        // Settle the recent-position window along +X first (matches the already-locked axis —
        // no turn should be read from this).
        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // Then redirect to +Z. x stays fixed at 2.5 for every one of these frames, so whichever
        // frame the turn is actually detected on, the resulting bend's x is exactly 2.5 either
        // way — not dependent on nailing the precise trigger frame.
        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // original start + new bend + tip
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(2.5, 0, 0)), 1e-4)
        XCTAssertEqual(component.controlPoints[2], result)
        XCTAssertEqual(result.x, 2.5, accuracy: 1e-4)
        XCTAssertGreaterThan(result.z, 0.05) // actually followed the turn, not clamped near zero
    }

    func testUpdate_reversingDirection_neverInsertsABendAndClampsAtMinimumSegmentLength() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // Reverse hard, well past the neighbor's own position (0,0,0) — a straight-back reversal
        // isn't a 90-degree corner (see TubeEndpointDrag.update's reversal exclusion), so this
        // should never insert a bend, no matter how far back it's pulled.
        var result = SIMD3<Float>.zero
        for step in 1 ... 70 {
            result = drag.update(rawPosition: SIMD3(2.5 - Float(step) * 0.05, 0, 0))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // never grew — no spurious bend
        XCTAssertEqual(result.x, 0.05, accuracy: 1e-4) // floored, not driven to/past the neighbor
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_draggingStart_insertsBendAdjacentToIndexZero() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: true))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(-Float(step) * 0.05, 0, 0))
        }
        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(-0.5, 0, Float(step) * 0.05))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3)
        // The dragged tip stays at index 0 for the whole drag (isStart), the new bend lands at
        // index 1, and the original far end (2,0,0) is undisturbed at index 2.
        XCTAssertEqual(component.controlPoints[0], result)
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(-0.5, 0, 0)), 1e-4)
        XCTAssertEqual(component.controlPoints[2], SIMD3(2, 0, 0))
    }

    func testUpdate_returnValueAlwaysMatchesWhatWasWrittenToTheTube() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 5 {
            let result = drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
            let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
            XCTAssertEqual(component.controlPoints.last, result)
        }
    }
}
