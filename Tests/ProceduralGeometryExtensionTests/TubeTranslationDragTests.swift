//
//  TubeTranslationDragTests.swift
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
final class TubeTranslationDragTests: XCTestCase {
    private var renderer: UntoldRenderer!

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

    func testInit_returnsNilForEntityWithoutTubePathComponent() throws {
        let entityId = createEntity()
        XCTAssertNil(TubeTranslationDrag(tubeId: entityId, dragOrigin: .zero))
    }

    func testUpdate_shiftsEveryControlPointByTheSameDelta() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeTranslationDrag(tubeId: entityId, dragOrigin: SIMD3(1, 1, 1)))

        let delta = drag.update(rawPosition: SIMD3(1, 1, 1) + SIMD3(0.5, -0.2, 0.3))

        XCTAssertEqual(simd_length(delta - SIMD3(0.5, -0.2, 0.3)), 0, accuracy: 1e-5)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        for (actual, expected) in zip(component.controlPoints, path.map({ $0 + SIMD3(0.5, -0.2, 0.3) })) {
            XCTAssertEqual(simd_length(actual - expected), 0, accuracy: 1e-5)
        }
    }

    func testUpdate_calledRepeatedly_alwaysMeasuresFromTheOriginalShapeNotTheLastFrame() throws {
        // Every update recomputes from the drag's fixed origin/original points, not from
        // whatever the previous update already wrote — otherwise repeated per-frame calls during
        // one continuous gesture would compound the shift far beyond the actual hand motion.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeTranslationDrag(tubeId: entityId, dragOrigin: .zero))

        _ = drag.update(rawPosition: SIMD3(1, 0, 0))
        _ = drag.update(rawPosition: SIMD3(1, 0, 0))
        _ = drag.update(rawPosition: SIMD3(1, 0, 0))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, path.map { $0 + SIMD3(1, 0, 0) })
    }

    func testUpdate_zeroDelta_leavesShapeUnchanged() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path, radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeTranslationDrag(tubeId: entityId, dragOrigin: SIMD3(3, 3, 3)))

        _ = drag.update(rawPosition: SIMD3(3, 3, 3))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, path)
    }
}
