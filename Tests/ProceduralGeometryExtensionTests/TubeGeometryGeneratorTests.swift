//
//  TubeGeometryGeneratorTests.swift
//  ProceduralGeometryExtensionTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import ProceduralGeometryExtension
import simd
import XCTest

/// Pure-math tests for `TubeGeometryGenerator` — no Metal device, no engine bootstrap, no ECS.
final class TubeGeometryGeneratorTests: XCTestCase {
    // MARK: - Topology

    func testGenerate_straightTwoPointTube_hasExpectedTopology() throws {
        let output = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertEqual(output.positions.count, 16)
        XCTAssertEqual(output.normals.count, 16)
        XCTAssertEqual(output.uvs.count, 16)
        XCTAssertEqual(output.tangents.count, 16)
        XCTAssertEqual(output.indices.count, 48) // (2 rings - 1) * 8 segments * 2 triangles * 3

        // Straight tube along +z: every vertex should sit exactly `radius` from the z axis.
        for position in output.positions {
            let radialDistance = simd_length(SIMD2(position.x, position.y))
            XCTAssertEqual(radialDistance, 0.2, accuracy: 1e-4)
        }
    }

    func testGenerate_capsToggleVertexAndIndexCounts() throws {
        let uncapped = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 6,
            capStart: false,
            capEnd: false
        ))
        XCTAssertEqual(uncapped.positions.count, 12)
        XCTAssertEqual(uncapped.indices.count, 36)

        let capped = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 5)],
            radius: 0.2,
            radialSegments: 6,
            capStart: true,
            capEnd: true
        ))
        // Each cap adds one center vertex + one ring of `radialSegments` vertices.
        XCTAssertEqual(capped.positions.count, 12 + 2 * (6 + 1))
        // Each cap adds `radialSegments` triangles (3 indices each).
        XCTAssertEqual(capped.indices.count, 36 + 2 * 6 * 3)
    }

    // MARK: - Turns

    func testGenerate_rightAngleTurn_producesContinuousNonDegenerateRings() throws {
        let output = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8
        ))

        XCTAssertEqual(output.positions.count, 24)

        // No NaNs/degenerate vectors anywhere, and every normal is unit length.
        for normal in output.normals {
            XCTAssertTrue(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
            XCTAssertEqual(simd_length(normal), 1.0, accuracy: 1e-4)
        }
        for position in output.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }

        // The joint ring (index range [8, 16)) is on the miter bisector plane between the
        // incoming +x segment and outgoing +z segment, so its radius is scaled by 1/cos(45°).
        let expectedJointRadius = 0.2 / Float(cos(Double.pi / 4))
        let jointCenter = SIMD3<Float>(2, 0, 0)
        for index in 8 ..< 16 {
            let distance = simd_distance(output.positions[index], jointCenter)
            XCTAssertEqual(distance, expectedJointRadius, accuracy: 1e-3)
        }

        // The two end rings are unscaled (radius exactly `radius`).
        for index in 0 ..< 8 {
            XCTAssertEqual(simd_distance(output.positions[index], SIMD3(0, 0, 0)), 0.2, accuracy: 1e-4)
        }
        for index in 16 ..< 24 {
            XCTAssertEqual(simd_distance(output.positions[index], SIMD3(2, 0, 2)), 0.2, accuracy: 1e-4)
        }
    }

    func testGenerate_verticalSegment_doesNotDegenerateFrame() throws {
        // The first segment is parallel to the world-up fallback axis used when picking an
        // initial frame reference — this is exactly the case that degenerates if the frame is
        // re-derived from a fixed world-up vector instead of being parallel-transported.
        let output = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 5, 0), SIMD3(2, 5, 0)],
            radius: 0.2,
            radialSegments: 8
        ))

        for normal in output.normals {
            XCTAssertTrue(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
            XCTAssertEqual(simd_length(normal), 1.0, accuracy: 1e-4)
        }
        for position in output.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
    }

    // MARK: - Validation

    func testGenerate_returnsNilForInvalidRadius() {
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 1)],
            radius: 0,
            radialSegments: 8
        ))
    }

    func testGenerate_returnsNilForTooFewRadialSegments() {
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 1)],
            radius: 0.2,
            radialSegments: 2
        ))
    }

    func testGenerate_returnsNilWhenFewerThanTwoDistinctControlPoints() {
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0)],
            radius: 0.2,
            radialSegments: 8
        ))
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, 0)],
            radius: 0.2,
            radialSegments: 8
        ))
    }

    // MARK: - Topology signature

    func testTopologySignature_equalForSameShapeDifferentPositions() {
        let a = TubeGeometryGenerator.topologySignature(
            controlPointCount: 3, radialSegments: 8, capStart: false, capEnd: true
        )
        let b = TubeGeometryGenerator.topologySignature(
            controlPointCount: 3, radialSegments: 8, capStart: false, capEnd: true
        )
        XCTAssertEqual(a, b)
    }

    func testTopologySignature_differsWhenRadialSegmentsDiffer() {
        let a = TubeGeometryGenerator.topologySignature(
            controlPointCount: 3, radialSegments: 8, capStart: false, capEnd: false
        )
        let b = TubeGeometryGenerator.topologySignature(
            controlPointCount: 3, radialSegments: 12, capStart: false, capEnd: false
        )
        XCTAssertNotEqual(a, b)
    }
}
