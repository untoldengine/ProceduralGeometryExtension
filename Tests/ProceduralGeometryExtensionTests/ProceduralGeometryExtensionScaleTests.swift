//
//  ProceduralGeometryExtensionScaleTests.swift
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

/// Milestone 5: everything else in this package has only been exercised with a 2-3 point demo
/// tube. These tests use a more BIM-realistic path (many points, several bends) to confirm
/// correctness and fast-path stability don't just happen to work at toy scale.
@MainActor
final class ProceduralGeometryExtensionScaleTests: XCTestCase {
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

    /// An 18-point zigzag with 16 interior 90-degree corners.
    private func zigzagPath(count: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = [SIMD3(0, 0, 0)]
        var current = SIMD3<Float>(0, 0, 0)
        for index in 1 ..< count {
            let step: SIMD3<Float> = index.isMultiple(of: 2) ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            current += step
            points.append(current)
        }
        return points
    }

    func testCreateTube_manyPointsWithBends_matchesGeneratorOutput() throws {
        let path = zigzagPath(count: 18)
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path,
            radius: 0.05,
            radialSegments: 8,
            bendRadius: 0.3
        ))

        let expected = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: path, radius: 0.05, radialSegments: 8, bendRadius: 0.3
        ))
        let renderComponent = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.vertexCount, expected.positions.count)
        XCTAssertEqual(renderComponent.mesh[0].metalKitMesh.submeshes[0].indexCount, expected.indices.count)
    }

    func testRepeatedDrag_onManyPointMultiBendTube_staysOnFastPathThroughout() throws {
        let path = zigzagPath(count: 18)
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: path,
            radius: 0.05,
            radialSegments: 8,
            bendRadius: 0.3
        ))

        let bufferAtStart = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer

        // Simulate a short drag: nudge one interior point a little further each "frame". Small
        // enough perturbations that no corner's angle crosses into/out of the "effectively
        // straight" or clamped-tangent-length thresholds along the way — topology should stay
        // constant the whole time.
        var current = path
        let draggedIndex = 8
        for step in 1 ... 20 {
            current[draggedIndex] = path[draggedIndex] + SIMD3<Float>(Float(step) * 0.01, 0, 0)
            XCTAssertTrue(ProceduralGeometryExtension.shared.setControlPoints(entityId: entityId, current))
        }

        let bufferAtEnd = try XCTUnwrap(scene.get(component: RenderComponent.self, for: entityId))
            .mesh[0].metalKitMesh.vertexBuffers[0].buffer
        // Same GPU buffer across 20 consecutive updates on an 18-point, 16-bend tube — no
        // per-frame reallocation even at this scale, not just the 2-3 point demo.
        XCTAssertTrue(bufferAtStart === bufferAtEnd)

        let finalComponent = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(finalComponent.controlPoints, current)
    }
}
