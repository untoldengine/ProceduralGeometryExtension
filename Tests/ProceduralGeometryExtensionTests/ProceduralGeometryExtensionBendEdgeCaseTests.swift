//
//  ProceduralGeometryExtensionBendEdgeCaseTests.swift
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

/// Milestone 4: confirms rounded bends and insert/remove interact correctly with the existing
/// in-place fast path and with each other — no new mechanism here, `fastPathEligibleMesh`
/// already keys off actual vertex/index counts, this just verifies that holds with bends
/// involved too.
@MainActor
final class ProceduralGeometryExtensionBendEdgeCaseTests: XCTestCase {
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

    func testDraggingControlPoint_withBendRadiusSet_staysOnFastPath() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.1,
            radialSegments: 8,
            bendRadius: 0.5
        ))

        let bufferBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer

        // Same point count, same radial segments/caps/bendRadius, and the corner stays a
        // similar angle — no reason for the vertex/index count to change.
        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 0, 3)]
        ))

        let bufferAfter = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer
        XCTAssertTrue(bufferBefore === bufferAfter)
    }

    func testInsertControlPoint_withBendRadiusSet_takesFullRebuildAndProducesCorrectGeometry() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.1,
            radialSegments: 8,
            bendRadius: 0.5
        ))
        let meshBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId)).mesh[0].metalKitMesh

        let newControlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 2, 2), SIMD3(2, 0, 2),
        ]
        XCTAssertTrue(ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 2, SIMD3(2, 2, 2)
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        // A different point count can't be satisfied by the old buffer — must be a new MTKMesh.
        XCTAssertFalse(meshBefore === renderComponent.mesh[0].metalKitMesh)

        let expectedGeometry = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: newControlPoints, radius: 0.1, radialSegments: 8, bendRadius: 0.5
        ))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, expectedGeometry.positions.count)
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.submeshes[0].indexCount, expectedGeometry.indices.count)
    }

    func testDraggingToShrinkAdjacentSegment_bendShrinksSmoothly_notBroken() throws {
        // bendRadius (2) is deliberately larger than the segments (length 2 each) can fully
        // satisfy, so the initial bend is already clamped to a tangent length of 1 (half of 2).
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.1,
            radialSegments: 8,
            bendRadius: 2
        ))
        let vertexCountBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexCount

        // Drag the last point much closer to the corner: the outgoing segment shrinks to 0.4,
        // so the achieved tangent length must shrink further (to 0.2, half of 0.4) rather than
        // producing broken/self-intersecting geometry.
        XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 0.4)]
        ))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        let mesh = renderComponent.mesh[0]

        // Same topology throughout (angle unchanged, only a length change) — still the fast path.
        XCTAssertEqual(mesh.metalKitMesh.vertexCount, vertexCountBefore)

        // The tube now only reaches to just past z=0.4 — nowhere near the original z=2 extent —
        // confirming it actually followed the shrink instead of leaving stale, oversized, or
        // degenerate geometry behind.
        let bounds = mesh.localBounds
        XCTAssertLessThan(bounds.max.z, 0.6)
        XCTAssertGreaterThan(bounds.max.z, 0.3)

        // No NaN/garbage anywhere in the written buffer.
        let positionsBuffer = mesh.metalKitMesh.vertexBuffers[0].buffer
        let positions = positionsBuffer.contents().bindMemory(to: simd_float4.self, capacity: mesh.metalKitMesh.vertexCount)
        for index in 0 ..< mesh.metalKitMesh.vertexCount {
            let position = positions[index]
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
    }

    func testRemovingBendApex_removesTheBendCleanly() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.1,
            radialSegments: 8,
            bendRadius: 0.5
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.removeControlPoint(entityId: entityId, at: 1))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(2, 0, 2)])

        // Two points left, no interior corner to round — a plain straight tube, same as if
        // bendRadius had never been set.
        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 16) // 2 rings * 8 segments
    }
}
