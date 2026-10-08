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

    // MARK: - Degenerate spacing (programmatic protection)

    // A straight run (no real corner anywhere) has no spacing floor beyond avoiding exact
    // coincidence — see `TubeGeometryGenerator.requiredMiterClearance`'s doc comment: a plain
    // flat-ended cylinder of any positive length never self-intersects, however short. The
    // degenerate band this guards against only exists where there's a genuine corner, so every
    // test below uses one: a 90-degree bend with a too-short segment on one side.

    func testCreateTubeEntity_cornerWithSegmentShorterThanItsRequiredClearance_returnsNil() throws {
        // Not a drag at all — a direct, programmatic call. Protects against the same
        // self-intersecting-tube bug the interactive drags clamp against, for callers that never
        // go through a drag (scripted content, a loaded scene with hand-authored data, etc). The
        // corner at index 1 (incoming +Z, outgoing +X) needs clearance `radius * tan(45°) == 0.2`
        // on each side; the second segment here is only 0.05 long.
        let entityId = ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(0.05, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        )
        XCTAssertNil(entityId)
    }

    func testSetControlPoints_wouldShrinkACornersSegmentBelowItsRequiredClearance_returnsFalseAndLeavesPathUntouched() throws {
        let validPath: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(5, 0, 10)]
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: validPath, radius: 0.2, radialSegments: 8
        ))

        let accepted = ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId, [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(0.05, 0, 10)]
        )

        XCTAssertFalse(accepted)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, validPath) // untouched
    }

    func testSetControlPoints_coincidentPoints_stillAccepted() throws {
        // A fully coincident pair isn't the degenerate band this guards against (`generate`
        // merges those away harmlessly) — only confirm the new guard doesn't start rejecting a
        // case that already worked.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))

        let accepted = ProceduralGeometryExtension.shared.setControlPoints(
            entityId: entityId, [SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 10)]
        )

        XCTAssertTrue(accepted)
    }

    func testDirectComponentWrite_bypassingTheAPI_degenerateSpacing_preservesLastValidMesh() throws {
        // Simulates a caller that bypasses `setControlPoints` entirely — a scene loader, a script
        // writing `TubePathComponent` fields directly — landing the path in the same degenerate
        // band the guarded API refuses. `TubeGeometryGenerator.generate` itself refuses this input
        // (see its own tests), so the per-tick safety net's `applyGeometryUpdate` call fails and
        // the entity's last successfully-built mesh is left exactly as it was: "preserve the last
        // valid geometry rather than allowing the mesh to collapse," independent of whether the
        // interaction layer ever got a chance to clamp it first.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(5, 0, 10)],
            radius: 0.2,
            radialSegments: 8
        ))
        let originalVertexCount = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexCount

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        component.controlPoints = [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(0.05, 0, 10)] // last segment: 0.05 < 0.2
        component.contentVersion += 1 // what the guarded API would have done, done by hand here

        ProceduralGeometryExtension.shared.update(deltaTime: 1 / 60, context: idleContext)

        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, originalVertexCount)
    }

    func testInsertControlPoint_wouldShrinkACornersSegmentBelowItsRequiredClearance_returnsFalseAndLeavesPathUntouched() throws {
        // Base tube already has one valid 90-degree corner at index 1 (long segments on both
        // sides). Inserting a point 0.05 past that corner, collinear with the segment beyond it,
        // shrinks the corner's own outgoing segment to 0.05 — well under the 0.2 clearance that
        // corner needs — without changing the corner's own angle at all.
        let validPath: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 0, 10), SIMD3(5, 0, 10)]
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: validPath, radius: 0.2, radialSegments: 8
        ))

        let accepted = ProceduralGeometryExtension.shared.insertControlPoint(
            entityId: entityId, at: 2, SIMD3(0.05, 0, 10)
        )

        XCTAssertFalse(accepted)
        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints, validPath) // untouched
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
