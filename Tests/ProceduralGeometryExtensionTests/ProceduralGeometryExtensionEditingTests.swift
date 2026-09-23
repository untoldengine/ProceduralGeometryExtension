//
//  ProceduralGeometryExtensionEditingTests.swift
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
final class ProceduralGeometryExtensionEditingTests: XCTestCase {
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

    func testSetControlPoints_rebuildsMeshAndBounds() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        let moved = ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId,
            [SIMD3(0, 0, 0), SIMD3(0, 0, 20)]
        )
        XCTAssertTrue(moved)

        let transform = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entityId))
        XCTAssertGreaterThanOrEqual(transform.boundingBox.max.z, 19.9)

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.contentVersion, 1)
    }

    func testSetRadius_rebuildsMeshWithNewRadius() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.setRadius(entityId: entityId, 0.5))

        // A straight tube's local bounds in x/y are exactly +/- radius.
        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        let bounds = renderComponent.mesh[0].localBounds
        XCTAssertEqual(bounds.max.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.y, 0.5, accuracy: 1e-4)
    }

    func testSetRadialSegments_changesVertexCount() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertTrue(ProceduralGeometryExtension.shared.setRadialSegments(entityId: entityId, 16))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, 32) // 2 rings * 16 segments
    }

    func testCreateTubeEntity_withBendRadius_roundsTheCorner() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8,
            bendRadius: 0.5
        ))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.bendRadius, 0.5)

        let sharp = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2, radialSegments: 8
        ))
        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertGreaterThan(renderComponent.mesh[0].metalKitMesh.vertexCount, sharp.positions.count)
    }

    func testSetBendRadius_updatesExistingTubeAndAddsRounding() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8
        ))
        let sharpVertexCount = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexCount

        XCTAssertTrue(ProceduralGeometryExtension.shared.setBendRadius(entityId: entityId, 0.5))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.bendRadius, 0.5)

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertGreaterThan(renderComponent.mesh[0].metalKitMesh.vertexCount, sharpVertexCount)
    }

    func testSetBendRadius_backToNil_restoresSharpMiter() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8
        ))
        let sharpVertexCount = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexCount

        XCTAssertTrue(ProceduralGeometryExtension.shared.setBendRadius(entityId: entityId, 0.5))
        XCTAssertTrue(ProceduralGeometryExtension.shared.setBendRadius(entityId: entityId, nil))

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, sharpVertexCount)
    }

    func testEditingCall_returnsFalseForEntityWithoutTubePathComponent() {
        let entityId = createEntity()
        XCTAssertFalse(ProceduralGeometryExtension.shared.setRadius(entityId: entityId, 1.0))
    }

    // MARK: - Safety-net dirty scan

    func testUpdate_picksUpDirectComponentMutationViaVersionBump() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))

        // Simulate an out-of-band change: something other than this extension's editing API
        // wrote new control points directly onto the component (e.g. a scene-load decoder).
        component.controlPoints = [SIMD3(0, 0, 0), SIMD3(0, 0, 50)]
        component.contentVersion += 1

        ProceduralGeometryExtension.shared.update(deltaTime: 1 / 60, context: idleContext)

        let transform = try XCTUnwrap(scene.get(component: LocalTransformComponent.self, for: entityId))
        XCTAssertGreaterThanOrEqual(transform.boundingBox.max.z, 49.9)
    }

    func testUpdate_doesNotRebuildWhenVersionUnchanged() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))
        let meshBefore = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId)).mesh[0].metalKitMesh

        ProceduralGeometryExtension.shared.update(deltaTime: 1 / 60, context: idleContext)

        let meshAfter = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId)).mesh[0].metalKitMesh
        // Same underlying MTKMesh object identity — update() didn't touch it because the
        // component's contentVersion hadn't changed since the last build.
        XCTAssertTrue(meshBefore === meshAfter)
    }
}
