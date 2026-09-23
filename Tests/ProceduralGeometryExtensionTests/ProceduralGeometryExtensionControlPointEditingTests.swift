//
//  ProceduralGeometryExtensionControlPointEditingTests.swift
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
final class ProceduralGeometryExtensionControlPointEditingTests: XCTestCase {
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

    // MARK: - Insert

    func testInsertControlPoint_atStart_updatesArrayAndMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 0, SIMD3(0, 0, -5)
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, -5), SIMD3(0, 0, 0), SIMD3(0, 0, 5)])

        let transform = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entityId))
        XCTAssertLessThanOrEqual(transform.boundingBox.min.z, -4.9)
    }

    func testInsertControlPoint_atMiddle_updatesArrayAndMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 1, SIMD3(3, 0, 5)
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(3, 0, 5), SIMD3(0, 0, 10)])

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 24) // 3 rings * 8 segments
    }

    func testInsertControlPoint_atEnd_appendsAndUpdatesMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 2, SIMD3(0, 0, 10)
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 0, 5), SIMD3(0, 0, 10)])
    }

    func testInsertControlPoint_onExistingStraightRun_doesNotChangeRenderedShape() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        // A point exactly on the existing straight run: still collinear, so the tube should
        // remain a straight cylinder with the same extent and radius, just with an extra ring.
        XCTAssertTrue(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 1, SIMD3(0, 0, 5)
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        let bounds = renderComponent.mesh[0].localBounds
        XCTAssertEqual(bounds.min.z, 0, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.z, 10, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.x, 0.2, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.y, 0.2, accuracy: 1e-4)
    }

    func testInsertControlPoint_outOfRangeIndex_returnsFalse() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertFalse(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: -1, SIMD3(0, 0, 0)
        ))
        XCTAssertFalse(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 99, SIMD3(0, 0, 0)
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2)
    }

    // MARK: - Remove

    func testRemoveControlPoint_atStart_updatesArrayAndMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, -5), SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 0))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 0, 5)])
    }

    func testRemoveControlPoint_atMiddle_removesTheBendApex() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(3, 0, 5), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 1))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 0, 10)])

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 16) // back to 2 rings * 8 segments
    }

    func testRemoveControlPoint_atEnd_updatesArrayAndMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 2))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 0, 5)])
    }

    func testRemoveControlPoint_refusesWhenAtMinimum() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertFalse(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 0))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(0, 0, 5)])
    }

    func testRemoveControlPoint_outOfRangeIndex_returnsFalse() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertFalse(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: -1))
        XCTAssertFalse(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 99))
    }

    // MARK: - Missing component

    func testInsertAndRemove_returnFalseForEntityWithoutTubePathComponent() {
        let entityId = createEntity()
        XCTAssertFalse(ProceduralGeometryExtension.shared.insertControlPoint(entityId: entityId, at: 0, SIMD3(0, 0, 0)))
        XCTAssertFalse(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 0))
    }
}
