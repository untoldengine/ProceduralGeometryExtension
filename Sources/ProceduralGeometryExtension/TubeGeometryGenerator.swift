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

    /// The absolute *lower bound* on a valid segment length for any `radius` — achieved only
    /// when neither end of the segment is a real corner (both ends are the path's own open ends,
    /// or a straight, same-direction continuation), so both end rings are the plain,
    /// un-mitered `radius`. A genuine bend on either end needs *more* than this — see
    /// `requiredRingRadius(at:in:radius:)` and `hasValidControlPointSpacing`, which account for
    /// the actual corner angle instead of assuming this best case. Kept as a cheap, conservative
    /// pre-check callers can use when they only know a radius and no path shape yet (there's
    /// nothing shorter than this that could ever be valid, for any configuration).
    public static func minimumSegmentLength(forRadius radius: Float) -> Float {
        radius * 2
    }

    /// Default epsilon `generate`'s own internal merge pass uses to treat two adjacent points as
    /// coincident (and therefore collapse to one, rather than sweep a near-zero segment). Exposed
    /// so a caller validating points *before* they reach `generate` — e.g.
    /// `hasValidControlPointSpacing` below — agrees on exactly the same boundary between "will be
    /// merged away harmlessly" and "is a real, if short, segment".
    public static let coincidentEpsilon: Float = 1e-5

    /// How far below a required length a distance is still accepted as "at the floor" rather than
    /// rejected — pure floating-point slack, not a relaxation of the actual geometric rule. A drag
    /// that clamps its own output to exactly a computed floor (see
    /// `TubeInteriorBendDrag.clampedScalar`) accumulates a few ULPs of error doing so (subtracting
    /// and re-adding vector components along an axis); without this slack, a legitimately-clamped
    /// position could land a hair's-breadth under the floor and get rejected by
    /// `hasValidControlPointSpacing` on the very next frame, which would read to the user as the
    /// drag randomly freezing early rather than holding cleanly at the minimum separation.
    public static let spacingTolerance: Float = 1e-4

    /// The ring radius needed at the corner where the path arrives along `incoming` and leaves
    /// along `outgoing` (both unit vectors) so the tube's actual cross-section — perpendicular to
    /// travel — stays equal to `radius` there, instead of shrinking. `cos(halfAngle)` via the
    /// half-angle identity `cos(θ/2) = sqrt((1 + cosθ) / 2)`, θ = the angle between the two
    /// directions — this avoids needing the bisector vector (and its own near-180° degenerate
    /// case, handled separately in `ringPlanes` for the ring's *orientation*, not its radius) just
    /// to get this scalar magnitude. An exact reversal (`cosθ == -1`) divides by zero: in `Float`
    /// arithmetic that's `.infinity`, not a trap, and every caller of this treats `.infinity` as
    /// "this corner needs more clearance than any finite segment could give it" — which is the
    /// actual geometric truth, not a bug to patch around. This generator never shrinks a ring
    /// below this value to make it fit a short segment (an earlier version did — see
    /// `hasValidControlPointSpacing`'s doc comment for why that made the tube visibly thinner
    /// right where it was needed most); if a ring can't have this radius without overlapping its
    /// neighbor, the edit that would have caused it is refused instead.
    public static func requiredMiterRingRadius(radius: Float, incoming: SIMD3<Float>, outgoing: SIMD3<Float>) -> Float {
        let cosDelta = simd_clamp(dot(incoming, outgoing), -1, 1)
        let cosHalfAngle = sqrt(max(0, (1 + cosDelta) / 2))
        return radius / cosHalfAngle
    }

    /// The ring radius `generate` needs at `points[index]` to keep the cross-section equal to
    /// `radius` there: plain `radius` at either path end (`index == 0` or
    /// `index == points.count - 1` — there's no second segment to miter against), or
    /// `requiredMiterRingRadius` for every interior point, computed from its own two immediate
    /// neighbors in `points`. Callers that already know a point's two neighbor directions won't
    /// change for the life of an edit (both `TubeEndpointDrag` and `TubeInteriorBendDrag` keep
    /// every corner axis-locked, so this is true for every corner either type touches) can call
    /// this once and treat the result as a constant for that edit, rather than recomputing it
    /// every frame.
    public static func requiredRingRadius(at index: Int, in points: [SIMD3<Float>], radius: Float) -> Float {
        guard index > 0, index < points.count - 1 else { return radius }
        let incoming = normalize(points[index] - points[index - 1])
        let outgoing = normalize(points[index + 1] - points[index])
        return requiredMiterRingRadius(radius: radius, incoming: incoming, outgoing: outgoing)
    }

    /// How far along *each* adjacent segment the corner where the path arrives along `incoming`
    /// and leaves along `outgoing` "consumes" — the same quantity, and the same formula, as
    /// `PathCornerRounding`'s own `tangentLength = bendRadius * tan(halfAngle)`, just with the
    /// tube's own `radius` standing in for a fillet's `bendRadius` (a sharp miter join is the
    /// limit of a fillet as its arc radius shrinks to a single point, so the same tangent-length
    /// relationship applies). This is *not* the ring's radius (see `requiredMiterRingRadius`,
    /// which is a perpendicular-to-travel measurement) — it's a parallel-to-travel one, and
    /// they're genuinely different quantities: this is the one `hasValidControlPointSpacing` needs
    /// (how much of a *segment* a corner eats into, so two corners sharing one segment can be
    /// compared against that segment's length), not the ring radius, which has no direct
    /// relationship to segment length at all (a barely-bent ring can still have a large radius —
    /// a big tube is still a big tube on a gentle curve — while still consuming almost no length
    /// from its segment, exactly what makes a finely-subdivided `bendRadius` fillet's many gentle
    /// sub-joints each individually cheap, even though the tube's radius at every one of them is
    /// essentially unchanged from nominal). Zero at a perfectly straight pass-through (`incoming ==
    /// outgoing`); grows to `.infinity` at an exact reversal, same reasoning as
    /// `requiredMiterRingRadius`.
    public static func requiredMiterClearance(radius: Float, incoming: SIMD3<Float>, outgoing: SIMD3<Float>) -> Float {
        let cosDelta = simd_clamp(dot(incoming, outgoing), -1, 1)
        let cosHalfAngle = sqrt(max(0, (1 + cosDelta) / 2))
        let sinHalfAngle = sqrt(max(0, (1 - cosDelta) / 2))
        return radius * sinHalfAngle / cosHalfAngle
    }

    /// The clearance `points[index]` consumes from each of its two adjacent segments: zero at
    /// either path end (`index == 0` or `index == points.count - 1` — nothing to miter against),
    /// or `requiredMiterClearance` for every interior point. See that function's doc comment for
    /// why this, not `requiredRingRadius`, is the quantity a segment-length check needs. Same
    /// "safe to compute once and treat as a constant for the life of an edit" note as
    /// `requiredRingRadius` applies here too.
    public static func requiredClearance(at index: Int, in points: [SIMD3<Float>], radius: Float) -> Float {
        guard index > 0, index < points.count - 1 else { return 0 }
        let incoming = normalize(points[index] - points[index - 1])
        let outgoing = normalize(points[index + 1] - points[index])
        return requiredMiterClearance(radius: radius, incoming: incoming, outgoing: outgoing)
    }

    /// Whether `radius` can be swept along `controlPoints` without any corner needing to consume
    /// more clearance (`requiredClearance(at:in:radius:)`) than its adjacent segment(s) actually
    /// have — two corners sharing a segment of length `L` fit without overlapping exactly when
    /// `requiredClearance(at: i) + requiredClearance(at: i+1) <= L` (within `spacingTolerance`).
    /// This replaces an earlier, angle-blind version of this check (a flat
    /// `minimumSegmentLength(forRadius:)` for every segment, regardless of how sharp its corners
    /// were) — that version let a segment between two genuine bends pass as "valid" even though
    /// `generate`'s own miter correction would need a *wider-than-nominal* ring there, which it was
    /// resolving by silently shrinking the ring (and with it, the tube's apparent diameter) rather
    /// than refusing the edit. A sharper corner on either end now correctly requires more
    /// clearance to keep the same radius — that's the real geometry, not an over-strict rule.
    /// Coincident (or near-coincident, within `coincidentEpsilon`) adjacent points are merged away
    /// first (same as `generate` itself does), so they're never treated as a too-short "segment"
    /// in their own right.
    public static func hasValidControlPointSpacing(_ controlPoints: [SIMD3<Float>], radius: Float) -> Bool {
        let points = mergeCoincidentPoints(controlPoints)
        guard points.count >= 2 else { return true }

        let clearances = (0 ..< points.count).map { requiredClearance(at: $0, in: points, radius: radius) }
        for index in 0 ..< points.count - 1 {
            let length = simd_distance(points[index + 1], points[index])
            let required = clearances[index] + clearances[index + 1] - spacingTolerance
            if length < required {
                return false
            }
        }
        return true
    }

    /// - Parameters:
    ///   - controlPoints: The tube's path, in order. Consecutive points closer than `1e-5`
    ///     apart are merged before generation (a zero-length segment has no direction).
    ///   - radius: Tube radius. Must be > 0.
    ///   - radialSegments: Vertices per ring. Must be >= 3.
    ///   - bendRadius: When set (and > 0), interior corners are rounded with a tangent-arc
    ///     fillet (`PathCornerRounding`) before sweeping, instead of the default sharp miter
    ///     joint. `nil` (the default) reproduces the exact sharp-miter behavior — this is purely
    ///     additive, the sweep/ring/miter code below never changes based on it.
    ///   - bendSegmentsPerCorner: Arc resolution when `bendRadius` is set. Needs to stay
    ///     constant across repeated calls during a drag for the in-place fast path (see
    ///     `ProceduralGeometryExtension`) to keep recognizing the topology as unchanged.
    /// - Returns: `nil` if, after merging duplicates, fewer than 2 distinct control points
    ///   remain, if `radius`/`radialSegments` are out of range, or if any ring would need to be
    ///   narrower than `requiredRingRadius(at:in:radius:)` to fit its own adjacent segment(s) —
    ///   see `hasValidControlPointSpacing`. That last case is deliberately a hard refusal, not a
    ///   best-effort patch: an earlier version of this generator instead shrank an over-wide ring
    ///   down to fit, which kept the mesh finite but made the tube visibly thinner right at the
    ///   corner that needed the correction — exactly backwards from "the radius never changes
    ///   unless the caller changes it." Refusing here means a caller that reaches this with bad
    ///   data (a direct `TubePathComponent` write that bypassed
    ///   `ProceduralGeometryExtension`'s own editing API, for instance) gets its last
    ///   successfully-built mesh left alone instead of a corrupted *or* visibly-shrunk one.
    public static func generate(
        controlPoints: [SIMD3<Float>],
        radius: Float,
        radialSegments: Int,
        capStart: Bool = false,
        capEnd: Bool = false,
        bendRadius: Float? = nil,
        bendSegmentsPerCorner: Int = 8
    ) -> Output? {
        guard radius > 0, radius.isFinite, radialSegments >= 3 else { return nil }

        let mergedPoints = mergeCoincidentPoints(controlPoints)
        guard mergedPoints.count >= 2 else { return nil }

        // Corner rounding is a path-preprocessing step only — everything below sweeps whatever
        // point list it's given exactly as before, with no knowledge of whether corners came
        // from the caller directly or from PathCornerRounding's arcs. Merged again afterward:
        // PathCornerRounding guards against producing coincident points itself, but this is a
        // second, independent line of defense for this generator specifically — the thing that
        // actually breaks on a zero-length segment is the tangent-direction normalize just
        // below, whose NaN then propagates through every subsequent frame via the sequential
        // parallel-transport chain, corrupting the *entire* tube rather than staying local.
        let roundedPoints = bendRadius.map {
            PathCornerRounding.round(path: mergedPoints, bendRadius: $0, segmentsPerCorner: bendSegmentsPerCorner)
        } ?? mergedPoints
        let points = mergeCoincidentPoints(roundedPoints)
        guard points.count >= 2 else { return nil }
        // Checked on `points` — the final, actually-swept list — not the caller's raw
        // `controlPoints`: corner rounding can turn one sharp corner that wouldn't have passed
        // this check into several much gentler arc segments that do, so checking any earlier
        // would reject configurations `bendRadius` rounding would otherwise have made valid.
        guard hasValidControlPointSpacing(points, radius: radius) else { return nil }

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

        let segmentLengths = (0 ..< segmentDirections.count).map {
            simd_length(points[$0 + 1] - points[$0])
        }

        var cumulativeLength: [Float] = [0]
        for index in 0 ..< segmentDirections.count {
            cumulativeLength.append(cumulativeLength[index] + segmentLengths[index])
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
            // miter plane. At a near-total-reversal corner, the plane's normal (see the
            // orthogonal-to-incoming fallback in ringPlanes above) can end up anti-parallel to
            // the transported right vector — the projection then removes all of it, leaving
            // nothing to normalize. Same orthogonal(to:) fallback as everywhere else in this
            // file for the same underlying degenerate configuration.
            let projectedRight = frame.right - dot(frame.right, plane.normal) * plane.normal
            let right = simd_length(projectedRight) > 1e-6 ? normalize(projectedRight) : orthogonal(to: plane.normal)
            let up = cross(plane.normal, right)

            // Miter radius correction: a ring on the bisector plane between two segments needs a
            // larger radius so the tube's actual cross-section (perpendicular to travel) stays
            // constant — exactly `requiredRingRadius`, the same formula `hasValidControlPointSpacing`
            // already confirmed (before `generate` ever got this far) fits both of this ring's
            // adjacent segments. Never shrunk to fit a short segment: an earlier version of this
            // generator clamped the radius down when it didn't fit, which kept the mesh finite but
            // made the tube visibly — and silently — thinner right at the corner that needed
            // widening. Now a configuration that can't support this radius is refused up front
            // instead, so by the time this line runs, it's already guaranteed to fit.
            let ringRadius = requiredRingRadius(at: ringIndex, in: points, radius: radius)

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

    private static func mergeCoincidentPoints(_ points: [SIMD3<Float>], epsilon: Float = coincidentEpsilon) -> [SIMD3<Float>] {
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
                // At a near-total reversal, incoming and outgoing are near-opposite, so their
                // sum — and with it the usual bisector — degenerates toward the zero vector.
                // Same fallback used for `bendAxis` in PathCornerRounding and for `rotate`'s
                // near-180 branch just above: any direction orthogonal to the incoming segment
                // is a well-defined, finite stand-in plane normal here. The miter radius
                // correction below is already clamped for exactly this case (a near-zero dot
                // product between an orthogonal normal and the reference direction), so this
                // only needs to keep the normal itself finite, not geometrically "correct" — a
                // true reversal has no clean ring plane to begin with.
                let bisectorSum = incoming + outgoing
                let bisector = simd_length(bisectorSum) > 1e-6 ? normalize(bisectorSum) : orthogonal(to: incoming)
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
