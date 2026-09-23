//
//  PathCornerRoundingTests.swift
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

/// Pure-math tests for `PathCornerRounding` — no Metal device, no engine bootstrap, no ECS,
/// and no knowledge of tubes.
final class PathCornerRoundingTests: XCTestCase {
    func testRound_straightPath_isUnchanged() {
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(10, 0, 0)]
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8)
        XCTAssertEqual(result, path)
    }

    func testRound_zeroOrNegativeBendRadius_returnsPathUnchanged() {
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0)]
        XCTAssertEqual(PathCornerRounding.round(path: path, bendRadius: 0, segmentsPerCorner: 8), path)
        XCTAssertEqual(PathCornerRounding.round(path: path, bendRadius: -1, segmentsPerCorner: 8), path)
    }

    func testRound_fewerThanThreePoints_returnsPathUnchanged() {
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 0)]
        XCTAssertEqual(PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8), path)
    }

    func testRound_rightAngleCorner_producesExpectedTangentPointsAndCount() {
        // Corner at (5,0,0): incoming +x, outgoing +y — a 90-degree turn. Segments are long
        // (length 5 each) relative to the bend radius (1), so the clamp doesn't engage:
        // tangentLength = bendRadius * tan(45 deg) = 1.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0)]
        let segmentsPerCorner = 8
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: segmentsPerCorner)

        // Untouched endpoints + one rounded corner (segmentsPerCorner + 1 points for that corner).
        XCTAssertEqual(result.count, 2 + (segmentsPerCorner + 1))
        XCTAssertEqual(result.first, path.first)
        XCTAssertEqual(result.last, path.last)

        let expectedTangentIn = SIMD3<Float>(4, 0, 0)
        let expectedTangentOut = SIMD3<Float>(5, 1, 0)
        XCTAssertLessThan(simd_distance(result[1], expectedTangentIn), 1e-4)
        XCTAssertLessThan(simd_distance(result[result.count - 2], expectedTangentOut), 1e-4)
    }

    func testRound_tangentPointsAreTrueTangents() {
        // A defining property of a circular fillet: the radius to a tangent point is
        // perpendicular to the line it's tangent to. Verifying this directly checks the
        // center/tangent-point construction is a geometrically valid circle, not just that the
        // numbers happen to look plausible.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 4, 4)]
        let result = PathCornerRounding.round(path: path, bendRadius: 0.5, segmentsPerCorner: 8)

        let tangentIn = result[1]
        let tangentOut = result[result.count - 2]
        let directionIn = normalize(path[1] - path[0])
        let directionOut = normalize(path[2] - path[1])

        // Reconstruct the fillet center independently (same geometric definition, not copied
        // from the implementation's exact code path) and verify both tangent points sit
        // perpendicular to their respective line, at equal distance from that center.
        let corner = path[1]
        let tangentLength = simd_distance(tangentIn, corner)
        let halfDelta = acos(simd_clamp(dot(directionIn, directionOut), -1, 1)) / 2
        let bisector = normalize(directionOut - directionIn)
        let center = corner + bisector * (tangentLength / sin(halfDelta))

        XCTAssertLessThan(abs(dot(tangentIn - center, directionIn)), 1e-4)
        XCTAssertLessThan(abs(dot(tangentOut - center, directionOut)), 1e-4)
        XCTAssertEqual(simd_distance(tangentIn, center), simd_distance(tangentOut, center), accuracy: 1e-4)
    }

    func testRound_shortAdjacentSegment_clampsTangentLength() {
        // Requested bend radius (1) would want tangentLength = tan(45 deg) = 1, but the outgoing
        // segment is only 0.1 long, so the achieved tangent length must be clamped to half of
        // that (0.05) — not the full requested radius.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0.1, 0)]
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8)

        let tangentOut = result[result.count - 2]
        let corner = path[1]
        XCTAssertEqual(simd_distance(tangentOut, corner), 0.05, accuracy: 1e-4)
    }

    func testRound_nearTotalReversal_passesThroughUnroundedNoCoincidentPoints() {
        // ~179.94-degree turn: directionOut is almost exactly -directionIn, with a tiny
        // perpendicular wobble so the turn angle isn't exactly 0. This is the case where
        // idealTangentLength (bendRadius * tan(halfDelta)) blows up toward infinity, bendAxis
        // (cross(directionIn, directionOut)) is near-degenerate, AND — the part the old version
        // of this test didn't check — tangentIn/tangentOut collapse to (near-)coincident points.
        // Finite values alone don't catch that: a cluster of duplicate points is still "finite",
        // but it hands any downstream consumer (TubeGeometryGenerator's tangent-direction
        // normalize, for one) a zero-length segment to choke on. A near-total reversal isn't a
        // meaningful "very tight fillet" with this two-tangent-point construction anyway, so it
        // should pass through unrounded — the same as the effectively-straight case.
        let wobble: Float = 0.001
        let path: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(1 - cos(wobble), sin(wobble), 0),
        ]
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1], path[1])
        for point in result {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite && point.z.isFinite)
        }
    }

    func testRound_exactTotalReversal_passesThroughUnrounded() {
        // The limiting case: directionOut is *exactly* -directionIn, not just nearly so.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 0)]
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1], path[1])
    }

    func testRound_verySharpButNotReversedCorner_stillRoundsWithoutCoincidentPoints() {
        // 170 degrees — deliberately sharp, but far enough from a total reversal that this
        // should still be a legitimate, well-defined fillet, not treated as unroundable. Guards
        // against the near-180 guard above being so wide it swallows genuinely sharp corners.
        let angle: Float = 170 * .pi / 180
        let path: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(1 + cos(Float.pi - angle), sin(Float.pi - angle), 0),
        ]
        let result = PathCornerRounding.round(path: path, bendRadius: 0.1, segmentsPerCorner: 8)

        XCTAssertEqual(result.count, 2 + 9) // a real rounded corner, not a pass-through
        let tangentIn = result[1]
        let tangentOut = result[result.count - 2]
        XCTAssertGreaterThan(simd_distance(tangentIn, tangentOut), 1e-4)
        for point in result {
            XCTAssertTrue(point.x.isFinite && point.y.isFinite && point.z.isFinite)
        }
    }

    func testRound_tinyDeviationAngle_passesThroughUnrounded() {
        // A deviation just under the "effectively straight" threshold: no arc should be
        // inserted, the corner passes through as a single point like a fully straight path.
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(10, 0.00001, 0)]
        let result = PathCornerRounding.round(path: path, bendRadius: 1, segmentsPerCorner: 8)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1], path[1])
    }

    func testRound_multipleCorners_eachRoundedIndependently() {
        let path: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(5, 5, 0), SIMD3(0, 5, 0),
        ]
        let segmentsPerCorner = 4
        let result = PathCornerRounding.round(path: path, bendRadius: 0.5, segmentsPerCorner: segmentsPerCorner)

        // Two interior corners, each contributing segmentsPerCorner + 1 points, plus the two
        // untouched endpoints.
        XCTAssertEqual(result.count, 2 + 2 * (segmentsPerCorner + 1))
        XCTAssertEqual(result.first, path.first)
        XCTAssertEqual(result.last, path.last)
    }
}
