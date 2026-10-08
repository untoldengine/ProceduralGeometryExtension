//
//  TubeInteriorBendDrag.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import UntoldEngine

/// Interactive reshaping of an *existing* interior bend: slides it along one of its two existing
/// segment axes — chosen once, from the direction the caller first pulls, out of only those two
/// candidates — while whichever side's axis *isn't* the locked one gets rigidly translated by the
/// same delta, so that side's direction (and every corner beyond it) never changes. The whole tube
/// stays axis-aligned throughout, not just once the drag ends.
///
/// If the locked side's segment would be dragged shorter than `effectiveMinimumSegmentLength`,
/// this bend's movement along that axis is clamped there instead — it holds at that minimum
/// separation, like hitting a wall, for as long as the raw input keeps pushing further. This type
/// never removes or merges a control point on its own; topology is something only an explicit
/// caller (`ProceduralGeometryExtension.removeControlPoint`) changes, never a side effect of
/// proximity. (An earlier version of this type did auto-remove the bend once its segment
/// collapsed — that's gone: besides taking topology control away from the caller, it meant any
/// single frame whose raw delta jumped past the threshold in one step would collapse the bend
/// immediately, with no clamped state in between for the caller to ever have rendered.)
///
/// Has no knowledge of picking, gestures, hand tracking, or any rendering/proxy entity — same
/// design as `TubeEndpointDrag`, just for an interior control point instead of an endpoint.
public struct TubeInteriorBendDrag {
    public let tubeId: EntityID
    /// This bend's control-point index *at the start of the drag*. Stable for the whole drag —
    /// this type never inserts or removes any point (see the type's own doc comment), so there's
    /// nothing that could shift it.
    public let index: Int

    private let dragOrigin: SIMD3<Float>
    private let originalControlPoints: [SIMD3<Float>]
    private var lockedAxis: SIMD3<Float>?
    /// (back axis: neighbor[index-1] -> point, forward axis: point -> neighbor[index+1]).
    private let candidateAxes: (back: SIMD3<Float>, forward: SIMD3<Float>)
    private let configuration: Configuration
    /// `configuration.minimumSegmentLength`, floored at the exact length this bend's own segment
    /// needs on each side to keep both its end rings at the tube's actual, undeformed radius —
    /// `(back:, forward:)` because the two sides generally need *different* floors: the dragged
    /// bend's own clearance is fixed (both its neighbor directions are locked for the life of this
    /// drag — see below), but the *far* clearance differs between the back segment (ends at
    /// `index - 1`) and the forward segment (ends at `index + 1`), since each far point has its
    /// own, generally different corner angle (or none at all, if it's the path's own open end).
    /// "Clearance," not ring radius — see `TubeGeometryGenerator.requiredMiterClearance`'s doc
    /// comment for why that, not the ring's actual radius, is the quantity a segment-length check
    /// needs. Below this floor, a segment's own end rings would need to be closer together than
    /// their required clearances allow and self-intersect into a twisted sweep (the actual
    /// on-device bug this guards against: dragging one bend of a U-shape toward its neighbor). An
    /// earlier version of this used a flat `radius * 2` here, which happens to be exactly right
    /// whenever both ends are ordinary 90-degree corners (this type's only use so far — `tan(45°)
    /// == 1`, so each side's clearance is just `radius`) but isn't the correct floor in general —
    /// a sharper corner on either end needs more than that, and a gentler one needs less.
    /// Computed once at `init`, not per frame: every corner this value depends on keeps its
    /// direction fixed for the whole drag by construction — the dragged bend's own two directions
    /// are exactly the two (fixed) locked axes, and the far corner's two directions are either
    /// untouched entirely or are themselves one of those same fixed axes — so the *clearance* each
    /// needs never changes, only how far apart they are.
    private let effectiveMinimumSegmentLength: (back: Float, forward: Float)

    public struct Configuration: Sendable {
        /// Minimum raw drag distance before an axis is locked in — below this, direction intent
        /// isn't clear yet, so the point holds at its original position rather than guessing.
        public var intentThreshold: Float
        /// Below this length, the locked side's segment is held here instead — see the type's own
        /// doc comment for why clamping, not removal. Also why this is a "not too small" floor,
        /// not zero: `TubeGeometryGenerator` and `PathCornerRounding` are hardened against
        /// near-zero segments, but a segment that short was never a meaningful edit to leave
        /// behind either.
        public var minimumSegmentLength: Float

        public init(intentThreshold: Float = 0.01, minimumSegmentLength: Float = 0.05) {
            self.intentThreshold = intentThreshold
            self.minimumSegmentLength = minimumSegmentLength
        }

        public static let `default` = Configuration()
    }

    /// Begins dragging the interior control point at `index`. Returns `nil` if the tube has no
    /// `TubePathComponent`, or `index` isn't a true interior point (0 and the last index are
    /// endpoints — see `TubeEndpointDrag` for those).
    public init?(tubeId: EntityID, index: Int, configuration: Configuration = .default) {
        guard let component = scene.get(component: TubePathComponent.self, for: tubeId) else {
            return nil
        }
        let count = component.controlPoints.count
        guard index > 0, index < count - 1 else { return nil }

        self.tubeId = tubeId
        self.index = index
        originalControlPoints = component.controlPoints
        dragOrigin = component.controlPoints[index]
        let rotation = component.referenceRotation
        candidateAxes = (
            back: nearestCardinalAxis(to: component.controlPoints[index] - component.controlPoints[index - 1], relativeTo: rotation),
            forward: nearestCardinalAxis(to: component.controlPoints[index + 1] - component.controlPoints[index], relativeTo: rotation)
        )
        lockedAxis = nil
        self.configuration = configuration

        let points = component.controlPoints
        let radius = component.radius
        let ownClearance = TubeGeometryGenerator.requiredClearance(at: index, in: points, radius: radius)
        let backFarClearance = TubeGeometryGenerator.requiredClearance(at: index - 1, in: points, radius: radius)
        let forwardFarClearance = TubeGeometryGenerator.requiredClearance(at: index + 1, in: points, radius: radius)
        effectiveMinimumSegmentLength = (
            back: max(configuration.minimumSegmentLength, ownClearance + backFarClearance),
            forward: max(configuration.minimumSegmentLength, ownClearance + forwardFarClearance)
        )
    }

    /// Call every frame with the current raw position of whatever the caller is using to drag
    /// this bend. Returns the position this bend should now be shown at — never `nil`; this type
    /// never removes the bend on its own (see the type's own doc comment), it only ever clamps.
    /// The `Optional` return type is kept for source compatibility with callers written against
    /// an earlier version that did remove bends; it's never actually `nil` now.
    @discardableResult
    public mutating func update(rawPosition: SIMD3<Float>) -> SIMD3<Float>? {
        resolvedPosition(rawPosition: rawPosition)
    }

    /// Call on the final frame of a drag gesture instead of `update(rawPosition:)`. Identical
    /// behavior to `update` now that neither ever removes this bend — kept as a separate entry
    /// point so a caller's gesture-lifecycle code can still name its final frame distinctly, the
    /// same shape as `TubeEndpointDrag.end`.
    @discardableResult
    public mutating func end(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        resolvedPosition(rawPosition: rawPosition)
    }

    /// Shared by `update`/`end`: resolves the locked axis (first call only), computes this bend's
    /// new position — clamped so the locked side's segment never ends up shorter than
    /// `effectiveMinimumSegmentLength` — and pushes it into the tube.
    private mutating func resolvedPosition(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        resolveLockedAxis(rawPosition: rawPosition)
        guard let axis = lockedAxis else { return dragOrigin }

        let isBackSide = axis == candidateAxes.back
        let delta = axis * clampedScalar(rawPosition: rawPosition, axis: axis, isBackSide: isBackSide)
        let candidatePoints = shiftedControlPoints(delta: delta, isBackSide: isBackSide)
        ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, candidatePoints)
        return candidatePoints[index]
    }

    /// The signed distance along `axis` this bend should move, floored so the locked side's
    /// segment never ends up shorter than `effectiveMinimumSegmentLength`. Back-side and
    /// forward-side are floored from opposite ends because the locked segment's length reads
    /// as `alongAxisOriginal + scalar` on the back side (dragging the point away from its back
    /// neighbor lengthens it) but `alongAxisOriginal - scalar` on the forward side (the same sign
    /// of motion shortens the segment to the point's forward neighbor instead).
    private func clampedScalar(rawPosition: SIMD3<Float>, axis: SIMD3<Float>, isBackSide: Bool) -> Float {
        let scalar = dot(rawPosition - dragOrigin, axis)
        return isBackSide
            ? max(scalar, effectiveMinimumSegmentLength.back - dot(originalControlPoints[index] - originalControlPoints[index - 1], axis))
            : min(scalar, dot(originalControlPoints[index + 1] - originalControlPoints[index], axis) - effectiveMinimumSegmentLength.forward)
    }

    private mutating func resolveLockedAxis(rawPosition: SIMD3<Float>) {
        guard lockedAxis == nil else { return }
        let rawDelta = rawPosition - dragOrigin
        guard simd_length(rawDelta) > configuration.intentThreshold else { return }
        let normalizedDelta = normalize(rawDelta)
        // abs(), not a raw comparison: this is choosing which *line* the pull lies along, not
        // which of the two specific signed directions it resembles. A pull back toward this
        // bend's own back-side neighbor (the exact motion collapsing that segment requires) has
        // dot(pull, backAxis) == -1 — very negative, but still entirely a back-axis motion, not
        // a forward-axis one. Comparing raw signed dot products would lose that case to the
        // perpendicular axis's dot of 0 every time.
        lockedAxis = abs(dot(normalizedDelta, candidateAxes.back)) >= abs(dot(normalizedDelta, candidateAxes.forward))
            ? candidateAxes.back
            : candidateAxes.forward
    }

    private func shiftedControlPoints(delta: SIMD3<Float>, isBackSide: Bool) -> [SIMD3<Float>] {
        var newControlPoints = originalControlPoints
        newControlPoints[index] = originalControlPoints[index] + delta
        if isBackSide {
            for pointIndex in (index + 1) ..< newControlPoints.count {
                newControlPoints[pointIndex] = originalControlPoints[pointIndex] + delta
            }
        } else {
            for pointIndex in 0 ..< index {
                newControlPoints[pointIndex] = originalControlPoints[pointIndex] + delta
            }
        }
        return newControlPoints
    }
}
