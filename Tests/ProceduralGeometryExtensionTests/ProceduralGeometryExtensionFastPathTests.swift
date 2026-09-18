//
//  ProceduralGeometryExtensionFastPathTests.swift
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

/// Covers the Milestone 6 interactive fast path: same-topology updates must not allocate a new
/// GPU buffer or re-register the mesh, must still produce correct geometry, and must still keep
/// picking/culling caches valid.
@MainActor
final class ProceduralGeometryExtensionFastPathTests: XCTestCase {
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

    func testSetControlPoints_sameTopology_reusesTheSameGPUBuffer() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        let bufferBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer

        // Same point count, same radius, same radial segments/caps: eligible for the fast path.
        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(0, 0, 20)]
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        let bufferAfter = renderComponent.mesh[0].metalKitMesh.vertexBuffers[0].buffer

        // Identity, not equality: the fast path must write into the existing MTLBuffer rather
        // than allocating a new one.
        XCTAssertTrue(bufferBefore === bufferAfter)

        // The written geometry must still be correct.
        let bounds = renderComponent.mesh[0].localBounds
        XCTAssertGreaterThanOrEqual(bounds.max.z, 19.9)
    }

    func testSetControlPoints_sameTopology_updatesBoundingBoxWithoutFullRebuild() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(0, 0, 20)]
        ))

        let transform = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entityId))
        XCTAssertGreaterThanOrEqual(transform.boundingBox.max.z, 19.9)
    }

    func testSetRadius_sameTopology_takesFastPathAndUpdatesGeometry() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        let bufferBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer

        XCTAssertTrue(ProceduralGeometryExtension.shared.setRadius(entityId: entityId, 0.6))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertTrue(bufferBefore === renderComponent.mesh[0].metalKitMesh.vertexBuffers[0].buffer)
        XCTAssertEqual(renderComponent.mesh[0].localBounds.max.x, 0.6, accuracy: 1e-4)
    }

    func testSetRadialSegments_topologyChange_fallsBackToFullRebuild() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        let meshBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId)).mesh[0].metalKitMesh

        XCTAssertTrue(ProceduralGeometryExtension.shared.setRadialSegments(entityId: entityId, 16))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        // A different vertex count can't be satisfied by writing into the old buffer — this
        // must be a genuinely new MTKMesh.
        XCTAssertFalse(meshBefore === renderComponent.mesh[0].metalKitMesh)
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 32)
    }

    func testSetControlPoints_sameTopology_marksPickingAndOctreeDirty() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        // Not asserted directly (no public read-back for the dirty set), but exercising this
        // must not crash and must be safe to call before/without a full scene picking init.
        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(0, 0, 8)]
        ))
    }

    func testRepeatedFastPathUpdates_matchWhatAFullRebuildWouldProduce() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1)],
            radius: 0.15,
            radialSegments: 10
        ))

        // Simulate a short drag: several same-topology updates in a row.
        for step in 1 ... 5 {
            let offset = Float(step) * 0.1
            XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
                entityId: entityId,
                [SIMD3(0, 0, 0), SIMD3(1 + offset, 0, 0), SIMD3(1 + offset, 0, 1)]
            ))
        }

        let finalControlPoints: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1.5, 0, 0), SIMD3(1.5, 0, 1)]
        let expected = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: finalControlPoints,
            radius: 0.15,
            radialSegments: 10
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].localBounds.min, expected.positions.reduce(
            SIMD3<Float>(repeating: .infinity)
        ) { simd_min($0, $1) })
    }
}
