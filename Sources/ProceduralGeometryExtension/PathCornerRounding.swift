//
//  PathCornerRounding.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd

/// Rounds the interior corners of a 3D polyline with tangent-arc fillets — the same
/// construction CAD tools use for a "corner radius" and road/rail centerline design uses for a
/// smooth curve through waypoints.
///
/// Has no knowledge of tubes, meshes, or any other geometry type: it only turns one polyline
/// into a longer polyline with corners replaced by arcs. Any path-based procedural geometry
/// generator can reuse it as a preprocessing step, the way `TubeGeometryGenerator` does.
public enum PathCornerRounding {
    /// - Parameters:
    ///   - path: The original polyline. Endpoints are never rounded (there's no corner there —
    ///     only interior points, index `1..<path.count-1`, are candidates).
    ///   - bendRadius: The desired radius of curvature at each corner. Corners where the
    ///     adjacent segments are too short to fit this radius get a smaller *effective* radius
    ///     instead (see below) rather than producing invalid geometry.
    ///   - segmentsPerCorner: How many straight sub-segments approximate each rounded corner's
    ///     arc. Must be >= 1; higher looks smoother. This needs to stay constant across repeated
    ///     calls during a drag for a generator's in-place fast path to keep working — it's a
    ///     resolution setting, not something to vary per call.
    /// - Returns: `path` unchanged if `bendRadius <= 0`, `segmentsPerCorner < 1`, or there are
    ///   fewer than 3 points (no interior corners to round). Otherwise, a longer polyline with
    ///   each rounded interior corner replaced by `segmentsPerCorner + 1` points tracing its arc
    ///   (first and last of which are the arc's tangent points on the original two segments).
    ///   Corners with a negligible turn angle, or a degenerate (near-zero-length) adjacent
    ///   segment, pass through as a single point unchanged — there's nothing meaningful to round.
    public static func round(
        path: [SIMD3<Float>],
        bendRadius: Float,
        segmentsPerCorner: Int = 8
    ) -> [SIMD3<Float>] {
        guard bendRadius > 0, bendRadius.isFinite, segmentsPerCorner >= 1, path.count >= 3 else {
            return path
        }

        var result: [SIMD3<Float>] = [path[0]]

        for index in 1 ..< path.count - 1 {
            let previous = path[index - 1]
            let corner = path[index]
            let next = path[index + 1]

            let incoming = corner - previous
            let outgoing = next - corner
            let incomingLength = simd_length(incoming)
            let outgoingLength = simd_length(outgoing)

            guard incomingLength > 1e-6, outgoingLength > 1e-6 else {
                // A degenerate adjacent segment has no well-defined direction to fillet against.
                result.append(corner)
                continue
            }

            let directionIn = incoming / incomingLength
            let directionOut = outgoing / outgoingLength

            let cosDelta = simd_clamp(dot(directionIn, directionOut), -1, 1)
            guard cosDelta < 0.999_999 else {
                // Effectively straight — nothing to round.
                result.append(corner)
                continue
            }
            guard cosDelta > -0.999_999 else {
                // Effectively a full reversal. This construction's tangent points collapse to a
                // single coincident location here (tangentOut = corner + directionOut*tangentLength
                // = corner - directionIn*tangentLength = tangentIn when directionOut is exactly
                // -directionIn), which would otherwise emit a run of duplicate points — no NaN at
                // this level, but a zero-length segment for any downstream consumer (like
                // TubeGeometryGenerator's tangent-direction normalize) to trip over. There's no
                // meaningful "very tight fillet" reading of a near-total reversal with a
                // two-tangent-point arc anyway, so pass the corner through unrounded, the same as
                // the effectively-straight case above.
                result.append(corner)
                continue
            }

            let delta = acos(cosDelta)
            let halfDelta = delta / 2
            // Safe without a zero-guard: halfDelta is bounded away from 0 by the cosDelta check
            // above (delta near 0 is already handled as "effectively straight"), and sin is
            // monotonically increasing on [0, pi/2], so sinHalfDelta only grows as the corner
            // approaches a full reversal — the opposite of where a division-by-zero risk would
            // be. (The construction that *does* degenerate near a 180-degree reversal is
            // `bendAxis` below — `directionIn` and `directionOut` become anti-parallel, so their
            // cross product vanishes — which is why that has its own fallback.)
            let sinHalfDelta = sin(halfDelta)

            // The tangent length a full-radius fillet would need, clamped to at most half of
            // each *original* adjacent segment's length. Each corner is clamped independently
            // using only its own segments — two corners sharing one segment can each claim at
            // most half of it, so they can never overlap, without needing to know about each
            // other. When the clamp bites, the achieved bend is a smaller effective radius
            // rather than broken/self-intersecting geometry.
            let idealTangentLength = bendRadius * tan(halfDelta)
            let tangentLength = min(idealTangentLength, incomingLength / 2, outgoingLength / 2)
            guard tangentLength > 1e-6 else {
                result.append(corner)
                continue
            }

            let tangentIn = corner - directionIn * tangentLength
            let tangentOut = corner + directionOut * tangentLength

            let bisector = normalize(directionOut - directionIn)
            let center = corner + bisector * (tangentLength / sinHalfDelta)

            var bendAxis = cross(directionIn, directionOut)
            let bendAxisLength = simd_length(bendAxis)
            bendAxis = bendAxisLength > 1e-6 ? bendAxis / bendAxisLength : orthogonal(to: directionIn)

            let radiusVector = tangentIn - center

            result.append(tangentIn)
            if segmentsPerCorner > 1 {
                for step in 1 ..< segmentsPerCorner {
                    let alpha = delta * Float(step) / Float(segmentsPerCorner)
                    let rotated = cos(alpha) * radiusVector + sin(alpha) * cross(bendAxis, radiusVector)
                    result.append(center + rotated)
                }
            }
            result.append(tangentOut)
        }

        result.append(path[path.count - 1])
        return result
    }

    private static func orthogonal(to v: SIMD3<Float>) -> SIMD3<Float> {
        let reference: SIMD3<Float> = abs(v.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        return normalize(cross(v, reference))
    }
}
