//
//  TubeGeometryGenerator.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd

/// Pure CPU geometry math for sweeping a circular tube along a polyline of 3D control points.
///
/// Has no dependency on the engine's ECS, Metal, or any rendering type — it only produces plain
/// arrays, so it's independently unit-testable and reusable as the CPU step of both the full
/// mesh rebuild path and the interactive in-place-buffer-update path (later milestones).
public enum TubeGeometryGenerator {
    /// CPU-side geometry arrays, laid out to feed directly into
    /// `Mesh.makeMesh(positions:normals:uvs:tangents:indices:name:)`.
    public struct Output {
        public let positions: [SIMD3<Float>]
        public let normals: [SIMD3<Float>]
        public let uvs: [SIMD2<Float>]
        public let tangents: [SIMD4<Float>]
        public let indices: [UInt32]
    }

    /// A vertex count/topology fingerprint. Two `generate` calls that produce equal signatures
    /// produce arrays of identical length and index layout — only vertex *values* differ. Later
    /// milestones use this to decide whether an update can take the in-place buffer-write fast
    /// path (same signature) or needs a full mesh rebuild (different signature).
    public struct TopologySignature: Equatable {
        public let controlPointCount: Int
        public let radialSegments: Int
        public let capStart: Bool
        public let capEnd: Bool
    }

    /// - Parameters:
    ///   - controlPoints: The tube's path, in order. Consecutive points closer than `1e-5`
    ///     apart are merged before generation (a zero-length segment has no direction).
    ///   - radius: Tube radius. Must be > 0.
    ///   - radialSegments: Vertices per ring. Must be >= 3.
    /// - Returns: `nil` if, after merging duplicates, fewer than 2 distinct control points
    ///   remain, or if `radius`/`radialSegments` are out of range.
    public static func generate(
        controlPoints: [SIMD3<Float>],
        radius: Float,
        radialSegments: Int,
        capStart: Bool = false,
        capEnd: Bool = false
    ) -> Output? {
        guard radius > 0, radius.isFinite, radialSegments >= 3 else { return nil }

        let points = mergeCoincidentPoints(controlPoints)
        guard points.count >= 2 else { return nil }

        let segmentDirections = (0 ..< points.count - 1).map {
            normalize(points[$0 + 1] - points[$0])
        }

        let segmentFrames = parallelTransportFrames(directions: segmentDirections)

        let rings = ringPlanes(points: points, segmentDirections: segmentDirections)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var tangents: [SIMD4<Float>] = []
        positions.reserveCapacity(points.count * radialSegments)
        normals.reserveCapacity(points.count * radialSegments)
        uvs.reserveCapacity(points.count * radialSegments)
        tangents.reserveCapacity(points.count * radialSegments)

        var cumulativeLength: [Float] = [0]
        for index in 0 ..< segmentDirections.count {
            let length = simd_length(points[index + 1] - points[index])
            cumulativeLength.append(cumulativeLength[index] + length)
        }
        let totalLength = max(cumulativeLength.last ?? 1, 1e-6)

        for ringIndex in 0 ..< points.count {
            // Interior rings inherit the (already parallel-transported) basis of the incoming
            // segment; the first ring has no incoming segment, so it uses the first segment's
            // basis instead. Either way the basis is continuous along the whole path.
            let frame = ringIndex == 0 ? segmentFrames[0] : segmentFrames[ringIndex - 1]
            let plane = rings[ringIndex]

            // Project the transported right/up onto the ring's plane (its normal is the miter
            // bisector at interior points, or the segment tangent at the two ends) and
            // re-orthonormalize. This keeps the basis twist-free while still respecting the
            // miter plane.
            let right = normalize(frame.right - dot(frame.right, plane.normal) * plane.normal)
            let up = cross(plane.normal, right)

            // Miter radius correction: a ring on the bisector plane between two segments needs
            // a larger radius so the tube's actual cross-section (perpendicular to travel)
            // stays constant. Clamped so a near-180-degree reversal doesn't blow up to
            // infinity — an accepted limitation for sharp turns in this milestone.
            let cosHalfAngle = max(dot(plane.normal, plane.referenceDirection), 0.2)
            let ringRadius = radius / cosHalfAngle

            let v = cumulativeLength[ringIndex] / totalLength

            for segment in 0 ..< radialSegments {
                let angle = 2 * Float.pi * Float(segment) / Float(radialSegments)
                let localDirection = cos(angle) * right + sin(angle) * up
                positions.append(points[ringIndex] + localDirection * ringRadius)
                normals.append(localDirection)
                uvs.append(SIMD2(Float(segment) / Float(radialSegments), v))
                tangents.append(SIMD4(plane.referenceDirection, 1))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((points.count - 1) * radialSegments * 6)
        for ringIndex in 0 ..< points.count - 1 {
            let ringStart = UInt32(ringIndex * radialSegments)
            let nextRingStart = UInt32((ringIndex + 1) * radialSegments)
            for segment in 0 ..< radialSegments {
                let next = (segment + 1) % radialSegments
                let a = ringStart + UInt32(segment)
                let b = ringStart + UInt32(next)
                let c = nextRingStart + UInt32(next)
                let d = nextRingStart + UInt32(segment)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        if capStart {
            appendCap(
                center: points[0],
                normal: -segmentDirections[0],
                right: segmentFrames[0].right,
                up: cross(-segmentDirections[0], segmentFrames[0].right),
                radius: radius,
                radialSegments: radialSegments,
                v: 0,
                reversedWinding: true,
                positions: &positions, normals: &normals, uvs: &uvs, tangents: &tangents, indices: &indices
            )
        }

        if capEnd {
            let lastDirection = segmentDirections[segmentDirections.count - 1]
            let lastFrame = segmentFrames[segmentFrames.count - 1]
            appendCap(
                center: points[points.count - 1],
                normal: lastDirection,
                right: lastFrame.right,
                up: cross(lastDirection, lastFrame.right),
                radius: radius,
                radialSegments: radialSegments,
                v: 1,
                reversedWinding: false,
                positions: &positions, normals: &normals, uvs: &uvs, tangents: &tangents, indices: &indices
            )
        }

        return Output(positions: positions, normals: normals, uvs: uvs, tangents: tangents, indices: indices)
    }

    public static func topologySignature(
        controlPointCount: Int,
        radialSegments: Int,
        capStart: Bool,
        capEnd: Bool
    ) -> TopologySignature {
        TopologySignature(
            controlPointCount: controlPointCount,
            radialSegments: radialSegments,
            capStart: capStart,
            capEnd: capEnd
        )
    }

    // MARK: - Internal geometry helpers

    private struct SegmentFrame {
        let right: SIMD3<Float>
    }

    private struct RingPlane {
        /// The plane the ring's vertices lie in — the miter bisector at interior points, or
        /// the adjacent segment's own direction at the two path ends.
        let normal: SIMD3<Float>
        /// The direction actually traveled through this ring (used for the miter radius
        /// correction and as the per-vertex tangent).
        let referenceDirection: SIMD3<Float>
    }

    private static func mergeCoincidentPoints(_ points: [SIMD3<Float>], epsilon: Float = 1e-5) -> [SIMD3<Float>] {
        guard var previous = points.first else { return [] }
        var merged = [previous]
        for point in points.dropFirst() where simd_distance(point, previous) > epsilon {
            merged.append(point)
            previous = point
        }
        return merged
    }

    /// Builds one right-vector frame per segment, each transported (via the minimal rotation
    /// that maps the previous segment's direction onto the current one) from the previous
    /// segment's frame — a rotation-minimizing frame, so orientation doesn't accumulate twist
    /// along the path the way re-deriving "right" from a fixed world-up vector would (and
    /// doesn't degenerate when the path goes vertical).
    private static func parallelTransportFrames(directions: [SIMD3<Float>]) -> [SegmentFrame] {
        guard let firstDirection = directions.first else { return [] }

        let worldUpReference: SIMD3<Float> = abs(dot(firstDirection, SIMD3<Float>(0, 1, 0))) > 0.99
            ? SIMD3<Float>(1, 0, 0)
            : SIMD3<Float>(0, 1, 0)
        var right = normalize(cross(worldUpReference, firstDirection))
        var frames: [SegmentFrame] = [SegmentFrame(right: right)]

        for index in 1 ..< directions.count {
            right = rotate(right, from: directions[index - 1], to: directions[index])
            frames.append(SegmentFrame(right: right))
        }
        return frames
    }

    private static func ringPlanes(points: [SIMD3<Float>], segmentDirections: [SIMD3<Float>]) -> [RingPlane] {
        var planes: [RingPlane] = []
        planes.reserveCapacity(points.count)

        for index in 0 ..< points.count {
            if index == 0 {
                planes.append(RingPlane(normal: segmentDirections[0], referenceDirection: segmentDirections[0]))
            } else if index == points.count - 1 {
                let direction = segmentDirections[segmentDirections.count - 1]
                planes.append(RingPlane(normal: direction, referenceDirection: direction))
            } else {
                let incoming = segmentDirections[index - 1]
                let outgoing = segmentDirections[index]
                let bisector = normalize(incoming + outgoing)
                planes.append(RingPlane(normal: bisector, referenceDirection: outgoing))
            }
        }
        return planes
    }

    /// Rodrigues' rotation formula: rotates `v` by the minimal-angle rotation mapping unit
    /// vector `a` onto unit vector `b`.
    private static func rotate(_ v: SIMD3<Float>, from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
        let cosTheta = simd_clamp(dot(a, b), -1, 1)
        if cosTheta > 0.999_999 { return v }

        if cosTheta < -0.999_999 {
            // Near-180-degree reversal: cross(a, b) is degenerate, so pick any axis
            // orthogonal to `a` and rotate 180 degrees about it.
            let axis = orthogonal(to: a)
            return 2 * dot(v, axis) * axis - v
        }

        let axis = normalize(cross(a, b))
        let sinTheta = sqrt(1 - cosTheta * cosTheta)
        return v * cosTheta + cross(axis, v) * sinTheta + axis * dot(axis, v) * (1 - cosTheta)
    }

    private static func orthogonal(to v: SIMD3<Float>) -> SIMD3<Float> {
        let reference: SIMD3<Float> = abs(v.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return normalize(cross(v, reference))
    }

    private static func appendCap(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        radius: Float,
        radialSegments: Int,
        v: Float,
        reversedWinding: Bool,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        uvs: inout [SIMD2<Float>],
        tangents: inout [SIMD4<Float>],
        indices: inout [UInt32]
    ) {
        let centerVertexIndex = UInt32(positions.count)
        positions.append(center)
        normals.append(normal)
        uvs.append(SIMD2(0.5, v))
        tangents.append(SIMD4(right, 1))

        let ringStartIndex = UInt32(positions.count)
        for segment in 0 ..< radialSegments {
            let angle = 2 * Float.pi * Float(segment) / Float(radialSegments)
            let localDirection = cos(angle) * right + sin(angle) * up
            positions.append(center + localDirection * radius)
            normals.append(normal)
            uvs.append(SIMD2(0.5 + 0.5 * cos(angle), 0.5 + 0.5 * sin(angle)))
            tangents.append(SIMD4(right, 1))
        }

        for segment in 0 ..< radialSegments {
            let next = (segment + 1) % radialSegments
            let a = ringStartIndex + UInt32(segment)
            let b = ringStartIndex + UInt32(next)
            if reversedWinding {
                indices.append(contentsOf: [centerVertexIndex, b, a])
            } else {
                indices.append(contentsOf: [centerVertexIndex, a, b])
            }
        }
    }
}
