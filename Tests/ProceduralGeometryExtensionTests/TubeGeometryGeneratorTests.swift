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

    func testGenerate_cornerWithSegmentExactlyAtRequiredClearance_preservesExactDiameter() throws {
        // The core regression this task reports: as two control points approach each other, the
        // tube must never get visibly *thinner* right at the corner that's shrinking — its ring
        // radius must stay at the exact, uncompressed miter value for as long as the configuration
        // is accepted at all, never a clamped-down approximation of it. Exercised right at the
        // boundary (segment length == exactly what two 90-degree corners need between them),
        // across several radii, since that boundary is precisely where an earlier "shrink to fit"
        // implementation would have kicked in.
        for radius: Float in [0.03, 0.1, 0.25] {
            let clearance = radius * Float(tan(Double.pi / 4)) // 90-degree corner: radius * tan(45°)
            let segmentLength = clearance * 2 // exactly what two such corners need between them
            let controlPoints: [SIMD3<Float>] = [
                SIMD3(0, 3, 0), SIMD3(0, 0, 0), SIMD3(segmentLength, 0, 0), SIMD3(segmentLength, 3, 0),
            ]
            let output = try XCTUnwrap(TubeGeometryGenerator.generate(
                controlPoints: controlPoints, radius: radius, radialSegments: 8
            ), "radius \(radius)")

            let expectedRingRadius = radius / Float(cos(Double.pi / 4))
            // Rings 1 and 2 (the two interior corners, index range [8,16) and [16,24)).
            for (ringStart, center) in [(8, controlPoints[1]), (16, controlPoints[2])] {
                for index in ringStart ..< ringStart + 8 {
                    let distance = simd_distance(output.positions[index], center)
                    XCTAssertEqual(
                        distance, expectedRingRadius, accuracy: 1e-3,
                        "radius \(radius): ring at \(center) was shrunk instead of staying at the exact miter radius"
                    )
                }
            }
        }
    }

    func testGenerate_sharpCornerOnShortSegment_preservesExactDiameterInsteadOfShrinking() throws {
        // Regression coverage for a real device bug: dragging two control points close together
        // on a sharp turn visibly thinned the tube right at that corner. An earlier fix (in
        // between the original bug and this one) clamped the joint ring's radius down to fit the
        // short segment — which stopped the mesh from spiking outward into a self-intersecting
        // mess, but produced exactly this *visible thinning* as a side effect, which is this
        // task's own regression. The corrected behavior: the ring keeps its exact, uncompressed
        // miter radius (`radius / cos(halfAngle)`, never shrunk) as long as the corner's actual
        // required *clearance* — not its ring radius; see `requiredMiterClearance`'s doc comment
        // for why those are different quantities — still fits the segment, which this
        // configuration's roughly-90-degree turn does even on a short (0.06) segment.
        let radius: Float = 0.03
        let shortSegment: Float = 0.06
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(0, 0, 1),
            SIMD3(0, shortSegment, 1 - 0.001), // close to a 90-degree turn, not a reversal
        ]
        let output = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: radius, radialSegments: 8
        ))

        for position in output.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }

        let expectedRingRadius = TubeGeometryGenerator.requiredMiterRingRadius(
            radius: radius,
            incoming: normalize(controlPoints[1] - controlPoints[0]),
            outgoing: normalize(controlPoints[2] - controlPoints[1])
        )
        let jointCenter = controlPoints[1]
        for index in 8 ..< 16 {
            let distance = simd_distance(output.positions[index], jointCenter)
            XCTAssertEqual(distance, expectedRingRadius, accuracy: 1e-4)
        }
    }

    func testGenerate_nearReversalOnShortSegment_refusesRatherThanShrinkingTheTube() throws {
        // A genuine near-total reversal (unlike the roughly-90-degree turn just above) needs a
        // required clearance far larger than any short segment can give it while keeping the
        // caller's exact radius — `generate` refuses this outright (`nil`) rather than render it
        // at any radius other than the one asked for.
        let radius: Float = 0.03
        let shortSegment: Float = 0.06
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(0, 0, 1),
            SIMD3(0, 0.001, 1 - shortSegment), // near-total reversal relative to the incoming segment
        ]
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: radius, radialSegments: 8
        ))
    }

    // MARK: - Control-point spacing validation

    func testMinimumSegmentLength_isTwiceTheRadius() {
        XCTAssertEqual(TubeGeometryGenerator.minimumSegmentLength(forRadius: 0.1), 0.2, accuracy: 1e-6)
        XCTAssertEqual(TubeGeometryGenerator.minimumSegmentLength(forRadius: 0.03), 0.06, accuracy: 1e-6)
    }

    func testHasValidControlPointSpacing_segmentShorterThanDiameter_isInvalid() {
        // Distinct (not coincident) but inside the degenerate band this whole fix exists to
        // keep callers out of: shorter than the tube's own diameter, so the two end rings would
        // overlap and self-intersect — exactly the U-shaped-tube bug this task reports, if a
        // caller reached this spacing by any means other than an interactive drag (which clamps
        // before ever getting here).
        let radius: Float = 0.1
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0.05, 1, 0), // last segment: 0.05 < 0.2
        ]
        XCTAssertFalse(TubeGeometryGenerator.hasValidControlPointSpacing(controlPoints, radius: radius))
    }

    func testHasValidControlPointSpacing_segmentAboveDiameter_isValid() {
        let radius: Float = 0.1
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0.25, 1, 0), // last segment: 0.25 > 0.2
        ]
        XCTAssertTrue(TubeGeometryGenerator.hasValidControlPointSpacing(controlPoints, radius: radius))
    }

    func testHasValidControlPointSpacing_coincidentPoints_areValid() {
        // A fully coincident (or near-coincident) pair isn't in the degenerate band at all —
        // `generate` merges these away harmlessly, so they should never be rejected here.
        let radius: Float = 0.1
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0),
        ]
        XCTAssertTrue(TubeGeometryGenerator.hasValidControlPointSpacing(controlPoints, radius: radius))
    }

    func testGenerate_adjacentControlPointsCloserThanDiameter_returnsNilRatherThanPatchedGeometry() throws {
        // This is the actual fix for the on-device bug reported in this task: earlier, `generate`
        // tried to patch a too-close pair via the miter-radius clamp, which produced a finite but
        // visibly self-intersecting/ballooning sweep rather than refusing outright. Any caller
        // that reaches `generate` with control points in the degenerate band now gets `nil` —
        // including one that bypassed `ProceduralGeometryExtension`'s own editing API entirely
        // (a direct `TubePathComponent.controlPoints` write, for instance), not just the three
        // guarded entry points (`setControlPoints`/`insertControlPoint`/`createTubeEntity`).
        let radius: Float = 0.1
        let uShapeWithCollapsedMiddle: [SIMD3<Float>] = [
            SIMD3(0, 3, 0), SIMD3(0, 0, 0), SIMD3(0.05, 0, 0), SIMD3(0.05, 3, 0), // middle: 0.05 < 0.2
        ]
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: uShapeWithCollapsedMiddle, radius: radius, radialSegments: 8
        ))
    }

    func testGenerate_spacingExactlyAtFloor_isAccepted() throws {
        // A drag clamped to exactly `minimumSegmentLength(forRadius:)` (see
        // `TubeInteriorBendDrag.clampedScalar`) must not be spuriously rejected by float rounding
        // on the very next call — see `TubeGeometryGenerator.spacingTolerance`.
        let radius: Float = 0.1
        let atExactlyTheFloor: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(TubeGeometryGenerator.minimumSegmentLength(forRadius: radius), 0, 0),
        ]
        XCTAssertNotNil(TubeGeometryGenerator.generate(
            controlPoints: atExactlyTheFloor, radius: radius, radialSegments: 8
        ))
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

    // MARK: - Bend radius

    func testGenerate_nilBendRadius_reproducesSharpMiterOutput() throws {
        // Regression guard: omitting bendRadius (the default) must be bit-for-bit identical to
        // the pre-existing sharp-miter behavior — this is purely additive.
        let withDefault = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8
        ))
        let withExplicitNil = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2,
            radialSegments: 8,
            bendRadius: nil
        ))
        XCTAssertEqual(withDefault.positions, withExplicitNil.positions)
        XCTAssertEqual(withDefault.indices, withExplicitNil.indices)
    }

    func testGenerate_bendRadiusSet_roundsCornerInsteadOfSharpMiter() throws {
        let controlPoints: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)]
        let sharp = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: 0.2, radialSegments: 8
        ))
        let rounded = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: 0.2, radialSegments: 8, bendRadius: 0.5
        ))

        // Rounding expands one corner into extra rings, so vertex/index counts must grow.
        XCTAssertGreaterThan(rounded.positions.count, sharp.positions.count)
        XCTAssertGreaterThan(rounded.indices.count, sharp.indices.count)

        // The sharp version has a ring exactly at the corner (2,0,0); the rounded version
        // shouldn't — every ring center now sits somewhere along the fillet arc instead.
        let cornerRingCenters = stride(from: 0, to: rounded.positions.count, by: 8)
        for start in cornerRingCenters {
            let ringCenterApprox = rounded.positions[start ..< start + 8].reduce(SIMD3<Float>.zero, +) / 8
            XCTAssertGreaterThan(simd_distance(ringCenterApprox, SIMD3(2, 0, 0)), 1e-3)
        }
    }

    func testGenerate_bendRadiusSet_nearTotalReversalCorner_producesFiniteGeometryNotNaN() throws {
        // Originally regression coverage for a NaN-propagation bug: PathCornerRounding's tangent
        // points collapse to (near-)coincident points at a near-180-degree corner, feeding a
        // zero-length segment into normalize() and producing NaN that propagated through every
        // subsequent ring via the sequential parallel-transport chain. That specific propagation
        // path is still hardened (PathCornerRounding's own near-reversal passthrough, and
        // `generate`'s post-round merge) — but this exact input is now caught even earlier: a
        // near-180-degree corner needs a required ring radius `hasValidControlPointSpacing` knows
        // no segment this short can satisfy at the caller's chosen radius without shrinking it
        // (which is exactly the bug the diameter-preservation fix exists to prevent — see
        // `TubeGeometryGenerator.requiredMiterRingRadius`), so `generate` now refuses this
        // configuration outright. `nil` is itself the proof there's no NaN: there's no output to
        // check.
        let wobble: Float = 0.001
        let controlPoints: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(1, 0, 0),
            SIMD3(1 - cos(wobble), sin(wobble), 0),
        ]
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: 0.05, radialSegments: 8, bendRadius: 0.3
        ))
    }

    func testGenerate_bendRadiusSet_exactReversalCorner_refusesRatherThanProducingNaN() throws {
        // An exact reversal has no finite required ring radius at all (see
        // `requiredMiterRingRadius`'s own doc comment on dividing by zero there) — `generate`
        // refuses it the same as the near-total-reversal case just above, for the same reason.
        let controlPoints: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 0)]
        XCTAssertNil(TubeGeometryGenerator.generate(
            controlPoints: controlPoints, radius: 0.05, radialSegments: 8, bendRadius: 0.3
        ))
    }

    func testGenerate_bendRadius_stableVertexCountAcrossRepeatedCalls() throws {
        // The in-place fast path depends on repeated generate() calls (as control points move)
        // producing the same vertex/index count as long as bendRadius/bendSegmentsPerCorner
        // don't change — this is what the extension's fast-path eligibility check relies on.
        let first = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 0, 2)],
            radius: 0.2, radialSegments: 8, bendRadius: 0.5
        ))
        let second = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2.3, 0, 0), SIMD3(2.3, 0, 1.7)],
            radius: 0.2, radialSegments: 8, bendRadius: 0.5
        ))
        XCTAssertEqual(first.positions.count, second.positions.count)
        XCTAssertEqual(first.indices.count, second.indices.count)
    }

    // MARK: - Scale

    /// An 18-point zigzag with 16 interior 90-degree corners — a more BIM-realistic path than
    /// the 2-3 point paths used everywhere else in this file.
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

    func testGenerate_manyBendZigzagPath_producesSaneGeometry() throws {
        let path = zigzagPath(count: 18)
        let radialSegments = 8
        let bendSegmentsPerCorner = 8

        // bendRadius (0.3) fits comfortably within half of every 1-unit-long segment (0.5), so
        // none of the 16 interior corners are clamped — every one rounds fully.
        let output = try XCTUnwrap(TubeGeometryGenerator.generate(
            controlPoints: path,
            radius: 0.05,
            radialSegments: radialSegments,
            bendRadius: 0.3,
            bendSegmentsPerCorner: bendSegmentsPerCorner
        ))

        let interiorCorners = path.count - 2
        let expectedRingCount = 2 + interiorCorners * (bendSegmentsPerCorner + 1)
        XCTAssertEqual(output.positions.count, expectedRingCount * radialSegments)
        XCTAssertEqual(output.indices.count, (expectedRingCount - 1) * radialSegments * 6)

        for position in output.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
        for normal in output.normals {
            XCTAssertEqual(simd_length(normal), 1.0, accuracy: 1e-3)
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
