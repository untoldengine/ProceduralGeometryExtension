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

/// Interactive reshaping (or removal, by dragging it away) of an *existing* interior bend: slides
/// it along one of its two existing segment axes — chosen once, from the direction the caller
/// first pulls, out of only those two candidates — while whichever side's axis *isn't* the locked
/// one gets rigidly translated by the same delta, so that side's direction (and every corner
/// beyond it) never changes. The whole tube stays axis-aligned throughout, not just once the drag
/// ends.
///
/// If the locked side's segment is dragged down to `configuration.minimumSegmentLength`, this
/// bend is removed entirely. The two candidate axes at any corner this type touches are always
/// perpendicular, so the rigid shift on the non-locked side can never touch the other segment's
/// own direction — reconnecting the two former neighbors by exactly the original far-side vector
/// keeps them perfectly axis-aligned, with no other special-casing needed (see `update` for why
/// that shift has to be snapped to the *exact* cancelling delta, not whatever partial delta
/// existed on the frame the threshold was crossed).
///
/// Has no knowledge of picking, gestures, hand tracking, or any rendering/proxy entity — same
/// design as `TubeEndpointDrag`, just for an interior control point instead of an endpoint.
public struct TubeInteriorBendDrag {
    public let tubeId: EntityID
    /// This bend's control-point index *at the start of the drag*. Stable for the whole drag —
    /// nothing this type does inserts or removes any point other than (at most, at the very end)
    /// this one, so there's nothing else that could shift it.
    public let index: Int

    private let dragOrigin: SIMD3<Float>
    private let originalControlPoints: [SIMD3<Float>]
    private var lockedAxis: SIMD3<Float>?
    /// (back axis: neighbor[index-1] -> point, forward axis: point -> neighbor[index+1]).
    private let candidateAxes: (back: SIMD3<Float>, forward: SIMD3<Float>)
    private let configuration: Configuration

    public struct Configuration: Sendable {
        /// Minimum raw drag distance before an axis is locked in — below this, direction intent
        /// isn't clear yet, so the point holds at its original position rather than guessing.
        public var intentThreshold: Float
        /// Below this length, the locked side's segment is treated as collapsed and this bend is
        /// removed. Also why this is a "not too small" floor, not zero: `TubeGeometryGenerator`
        /// and `PathCornerRounding` are hardened against near-zero segments, but a segment that
        /// short was never a meaningful edit to leave behind either.
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
        candidateAxes = (
            back: nearestCardinalAxis(to: component.controlPoints[index] - component.controlPoints[index - 1]),
            forward: nearestCardinalAxis(to: component.controlPoints[index + 1] - component.controlPoints[index])
        )
        lockedAxis = nil
        self.configuration = configuration
    }

    /// Call every frame with the current raw position of whatever the caller is using to drag
    /// this bend. Returns the position this bend should now be shown at, or `nil` if this call
    /// removed it (the locked segment collapsed) — the caller should stop the drag and discard
    /// whatever was representing this bend visually, there's nothing left to place it at.
    @discardableResult
    public mutating func update(rawPosition: SIMD3<Float>) -> SIMD3<Float>? {
        resolveLockedAxis(rawPosition: rawPosition)
        guard let axis = lockedAxis else { return dragOrigin }

        let isBackSide = axis == candidateAxes.back
        let delta = axis * dot(rawPosition - dragOrigin, axis)
        let candidatePoints = shiftedControlPoints(delta: delta, isBackSide: isBackSide)

        // The locked side's own segment is the one whose length actually changes as the user
        // drags — a signed measure along the axis, so overshooting past the neighbor reads as
        // negative rather than wrapping back toward a false "still fine" positive distance.
        let lockedSegmentLength = isBackSide
            ? dot(candidatePoints[index] - originalControlPoints[index - 1], axis)
            : dot(originalControlPoints[index + 1] - candidatePoints[index], axis)

        guard lockedSegmentLength >= configuration.minimumSegmentLength else {
            // Snap to exactly cancel the locked segment instead of using the natural (slightly
            // short-of-exact) delta from the frame the threshold was crossed on — see the type's
            // doc comment for why only the *exact* cancelling delta keeps the reconnection
            // perfectly axis-aligned.
            let exactDelta = isBackSide
                ? originalControlPoints[index - 1] - originalControlPoints[index]
                : originalControlPoints[index + 1] - originalControlPoints[index]
            let snapped = shiftedControlPoints(delta: exactDelta, isBackSide: isBackSide)
            ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, snapped)
            ProceduralGeometryExtension.shared.removeControlPoint(entityId: tubeId, at: index)
            return nil
        }

        ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, candidatePoints)
        return candidatePoints[index]
    }

    /// Call on the final frame of a drag gesture instead of `update(rawPosition:)`. Same
    /// positioning, but never removes this bend — release jitter shouldn't be able to trigger a
    /// structural change any more than it should be able to for `TubeEndpointDrag`.
    @discardableResult
    public mutating func end(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        resolveLockedAxis(rawPosition: rawPosition)
        guard let axis = lockedAxis else { return dragOrigin }

        let isBackSide = axis == candidateAxes.back
        let delta = axis * dot(rawPosition - dragOrigin, axis)
        let candidatePoints = shiftedControlPoints(delta: delta, isBackSide: isBackSide)
        ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, candidatePoints)
        return candidatePoints[index]
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
