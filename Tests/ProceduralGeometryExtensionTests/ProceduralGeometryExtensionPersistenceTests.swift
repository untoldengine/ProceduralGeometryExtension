//
//  ProceduralGeometryExtensionPersistenceTests.swift
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
final class ProceduralGeometryExtensionPersistenceTests: XCTestCase {
    private var renderer: UntoldRenderer!

    private let idleContext = EngineExtensionUpdateContext(
        viewport: SIMD2(1920, 1080),
        immersionStyle: .none,
        frameIndex: 0,
        currentEye: 0,
        isPrimaryEye: true
    )

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

    func testSceneRoundTrip_restoresControlPointsAndRegeneratesMesh() throws {
        let originalControlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 3),
        ]
        let originalEntityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: originalControlPoints,
            radius: 0.35,
            radialSegments: 10,
            capStart: true,
            capEnd: true,
            name: "PersistedTube"
        ))
        // Move it after creation, so the round trip also proves this isn't just re-reading the
        // creation-time arguments.
        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: originalEntityId,
            [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 0, 6)]
        ))
        let finalControlPoints = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: originalEntityId))
            .controlPoints

        let sceneData = serializeScene()

        destroyAllEntities()

        let expectation = XCTestExpectation(description: "Scene deserialized")
        deserializeScene(sceneData: sceneData, completion: {
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 10.0)

        // Not a mesh yet — the decoder only restores the component; the mesh comes back on the
        // extension's next per-tick pass, exactly like any other out-of-band component change.
        let restoredEntityId = try XCTUnwrap(
            scene.getAllEntities().first { getEntityName(entityId: $0) == "PersistedTube" }
        )
        let restoredComponent = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: restoredEntityId))
        XCTAssertEqual(restoredComponent.controlPoints, finalControlPoints)
        XCTAssertEqual(restoredComponent.radius, 0.35, accuracy: 1e-6)
        XCTAssertEqual(restoredComponent.radialSegments, 10)
        XCTAssertTrue(restoredComponent.capStart)
        XCTAssertTrue(restoredComponent.capEnd)

        ProceduralGeometryExtension.shared.update(deltaTime: 1 / 60, context: idleContext)

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: restoredEntityId))
        let expectedGeometry = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: finalControlPoints,
            radius: 0.35,
            radialSegments: 10,
            capStart: true,
            capEnd: true
        ))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, expectedGeometry.positions.count)
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.submeshes[0].indexCount, expectedGeometry.indices.count)
    }

    func testSceneRoundTrip_doesNotFallBackToGenericProceduralCubeRestore() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8,
            name: "PersistedTube2"
        ))
        let originalVertexCount = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexCount

        let sceneData = serializeScene()
        destroyAllEntities()

        let expectation = XCTestExpectation(description: "Scene deserialized")
        deserializeScene(sceneData: sceneData, completion: {
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 10.0)

        let restoredEntityId = try XCTUnwrap(
            scene.getAllEntities().first { getEntityName(entityId: $0) == "PersistedTube2" }
        )
        ProceduralGeometryExtension.shared.update(deltaTime: 1 / 60, context: idleContext)

        // If this had round-tripped through the engine's generic `.procedural` asset-name
        // mechanism instead, an unrecognized name falls back to a unit cube — a different
        // vertex count than the tube it should be.
        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: restoredEntityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, originalVertexCount)
    }
}
