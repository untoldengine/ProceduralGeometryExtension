//
//  ProceduralGeometryExtensionRuntimeTests.swift
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
final class ProceduralGeometryExtensionRuntimeTests: XCTestCase {
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

    func testCreateTubeEntity_attachesRenderComponentWithExpectedMesh() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8,
            name: "TestTube"
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh.count, 1)
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 16)
        XCTAssertEqual(renderComponent.assetName, "TestTube")
    }

    func testCreateTubeEntity_boundingBoxCoversControlPoints() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        let transform = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entityId))
        XCTAssertLessThanOrEqual(transform.boundingBox.min.z, 0.01)
        XCTAssertGreaterThanOrEqual(transform.boundingBox.max.z, 4.99)
    }

    func testCreateTubeEntity_attachesTubePathComponentWithGivenParameters() throws {
        let controlPoints = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, 1)]
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: controlPoints,
            radius: 0.3,
            radialSegments: 10,
            capStart: true,
            capEnd: true
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, controlPoints)
        XCTAssertEqual(component.radius, 0.3)
        XCTAssertEqual(component.radialSegments, 10)
        XCTAssertTrue(component.capStart)
        XCTAssertTrue(component.capEnd)
        XCTAssertEqual(component.contentVersion, 0)
    }

    func testCreateTubeEntity_returnsNilForInvalidInput() {
        let entityId = ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0)],
            radius: 0.2,
            radialSegments: 8
        )
        XCTAssertNil(entityId)
    }
}
