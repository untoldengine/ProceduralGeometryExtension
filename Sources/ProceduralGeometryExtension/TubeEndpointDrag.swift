//
//  TubeEndpointDrag.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import UntoldEngine

/// The six world-axis directions a drag snaps to, so every segment created this way is exactly
/// axis-aligned and every corner is exactly 90 degrees. Shared with `TubeInteriorBendDrag`, and
/// public so a caller placing a *new* tube (e.g. aligning it to a detected real-world surface)
/// can snap its initial direction the same way, instead of duplicating this math.
public let cardinalAxes: [SIMD3<Float>] = [
    SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
    SIMD3(0, 1, 0), SIMD3(0, -1, 0),
    SIMD3(0, 0, 1), SIMD3(0, 0, -1),
]

public func nearestCardinalAxis(to direction: SIMD3<Float>) -> SIMD3<Float> {
    guard simd_length(direction) > 1e-6 else { return cardinalAxes[0] }
    let normalized = normalize(direction)
    return cardinalAxes.max { dot(normalized, $0) < dot(normalized, $1) } ?? cardinalAxes[0]
}

/// Interactive, axis-constrained editing of a tube's start or end control point: extending it
/// along a locked cardinal axis, and automatically inserting a 90-degree bend wherever the
/// caller's recent input heading changes to a different axis.
///
/// Has no knowledge of picking, gestures, hand tracking, or any rendering/proxy entity — it only
/// consumes a raw 3D position each frame, however the caller obtains it, and reports back the
/// (axis-constrained) position the dragged endpoint should now be at. Any input source that can
/// supply "where is the user's hand/cursor right now" can drive this: XR pinch tracking, mouse
/// drag, a game controller, or a unit test feeding synthetic positions.
///
/// Reshaping or removing an existing bend once it's been placed is out of scope for this type —
/// it only ever touches its own tube's start or end index, never an interior point.
public struct TubeEndpointDrag {
    public let tubeId: EntityID
    /// True if dragging the tube's start (index 0). False if dragging its end (last index).
    public let isStart: Bool

    private var neighborPosition: SIMD3<Float>
    private var lockedAxis: SIMD3<Float>
    /// Rolling buffer of the most recent raw positions (oldest first, capped at
    /// `configuration.recentWindowCapacity`). Turn detection reads the vector from the oldest
    /// sample to the newest — the *current heading* — instead of the vector from the segment's
    /// fixed start, so redirecting doesn't get harder the longer the segment already is. Cleared
    /// after every commit, which doubles as the settle time before another commit can fire: the
    /// buffer has to fill back up with fresh motion before a new heading can even be read.
    private var recentPositions: [SIMD3<Float>] = []
    /// The `(neighborPosition, lockedAxis)` state each bend *this drag* has committed replaced,
    /// most recent last — so a reversal past a bend this same drag just created can undo it and
    /// resume from the segment before it, rather than only ever retracting toward (and stopping
    /// at) it. Scoped to this one drag: bends from an earlier, already-finished gesture are never
    /// on this stack, so a reversal can never reach back and remove one of those.
    private var undoStack: [(neighborPosition: SIMD3<Float>, lockedAxis: SIMD3<Float>)] = []
    private let configuration: Configuration

    /// Tuning knobs, exposed so a consumer can adjust feel without forking this type. Defaults
    /// match what shipped in the ProceduralGeometry demo after extensive on-device XR tuning.
    public struct Configuration: Sendable {
        /// How many recent samples count as "current heading". Small enough to stay responsive
        /// to a deliberate direction change, large enough to smooth out per-frame input jitter.
        /// Also sets the settle time after a commit, in samples.
        public var recentWindowCapacity: Int
        /// Below this distance across the whole recent window, the heading is too small to read
        /// reliably (input basically stationary) — a noise floor, not a turn-sensitivity knob.
        public var minimumRecentDragDistance: Float
        /// Minimum length, along the *true* fixed anchor, a new segment must already have before
        /// a turn can land there — and the floor a segment is clamped to on every update, not
        /// just at commit time. `TubeGeometryGenerator`'s parallel-transport frames and
        /// `PathCornerRounding`'s tangent-arc corner rounding are hardened against near-zero and
        /// near-180-degree segments, but a segment collapsing to zero length is still never a
        /// meaningful edit, so this keeps segments sane rather than relying on that hardening
        /// alone.
        public var minimumSegmentLength: Float

        public init(
            recentWindowCapacity: Int = 10,
            minimumRecentDragDistance: Float = 0.02,
            minimumSegmentLength: Float = 0.05
        ) {
            self.recentWindowCapacity = recentWindowCapacity
            self.minimumRecentDragDistance = minimumRecentDragDistance
            self.minimumSegmentLength = minimumSegmentLength
        }

        public static let `default` = Configuration()
    }

    /// Begins dragging `tubeId`'s start (`isStart == true`) or end control point. Returns `nil`
    /// if the tube has no `TubePathComponent`, or fewer than 2 control points (shouldn't happen
    /// for a valid tube, but this stays a no-op rather than crash if it somehow does).
    public init?(tubeId: EntityID, isStart: Bool, configuration: Configuration = .default) {
        guard let component = scene.get(component: TubePathComponent.self, for: tubeId) else {
            return nil
        }
        let count = component.controlPoints.count
        guard count >= 2 else { return nil }

        let ownIndex = isStart ? 0 : count - 1
        let neighborIndex = isStart ? 1 : count - 2
        let neighborPosition = component.controlPoints[neighborIndex]
        let currentPosition = component.controlPoints[ownIndex]

        self.tubeId = tubeId
        self.isStart = isStart
        self.neighborPosition = neighborPosition
        self.lockedAxis = nearestCardinalAxis(to: currentPosition - neighborPosition)
        self.configuration = configuration
    }

    /// Call every frame with the current raw position of whatever the caller is using to drag
    /// this endpoint — a picking proxy, a direct pinch position, a mouse ray hit, anything.
    /// Pushes the result into the tube via `setControlPoints`/`insertControlPoint` and returns
    /// the (axis-constrained) position the caller's own visual representation of the dragged tip
    /// should be placed at.
    @discardableResult
    public mutating func update(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        undoLastBendsIfRetractedPast(rawPosition: rawPosition)

        recentPositions.append(rawPosition)
        if recentPositions.count > configuration.recentWindowCapacity {
            recentPositions.removeFirst()
        }

        // Which cardinal axis the *recent* motion is closest to — decoupled from how far the
        // tip has already travelled since the segment's true start, unlike comparing the total
        // delta from that fixed anchor (which makes a long existing extension have ever-growing
        // inertia against turning). `nearestCardinalAxis` still requires genuine dominance
        // within that window — the new axis has to out-vote every other axis, including the
        // currently-locked one — so this isn't just an absolute-distance trigger.
        if recentPositions.count == configuration.recentWindowCapacity {
            let recentDelta = rawPosition - recentPositions[0]
            if simd_length(recentDelta) > configuration.minimumRecentDragDistance {
                let candidateAxis = nearestCardinalAxis(to: recentDelta)
                // Reversing straight back along the locked axis is a distinct cardinal axis
                // (+X and -X are different directions to nearestCardinalAxis), but it isn't a
                // real 90-degree corner — it's a retraction, already handled by the length floor
                // below. A 180-degree "bend" isn't geometrically a corner at all, and isn't a
                // 90-degree bend, which is all a caller using this type is choosing to allow.
                if candidateAxis != lockedAxis, candidateAxis != -lockedAxis {
                    let fullDelta = rawPosition - neighborPosition
                    let alongLockedAxis = dot(fullDelta, lockedAxis)
                    if alongLockedAxis > configuration.minimumSegmentLength,
                       let component = scene.get(component: TubePathComponent.self, for: tubeId) {
                        let bendPosition = neighborPosition + lockedAxis * alongLockedAxis
                        // The new bend always lands adjacent to whichever end is being dragged:
                        // index 1 if dragging the start (the tip itself stays at index 0), or
                        // the current last index if dragging the end (the tip's own index then
                        // advances by one, staying the last index) — re-derived fresh from the
                        // live array every time, so there's nothing to keep in sync by hand.
                        let insertIndex = isStart ? 1 : component.controlPoints.count - 1

                        if ProceduralGeometryExtension.shared.insertControlPoint(entityId: tubeId, at: insertIndex, bendPosition) {
                            undoStack.append((neighborPosition: neighborPosition, lockedAxis: lockedAxis))
                            neighborPosition = bendPosition
                            lockedAxis = candidateAxis
                            recentPositions.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
        }

        return applyAxisConstraint(rawPosition: rawPosition)
    }

    /// Call on the final frame of a drag gesture — its "ended"/"cancelled" phase — instead of
    /// `update(rawPosition:)`. Applies the same axis-constrained positioning (so the tip stays
    /// visually locked in place, not wherever the raw input landed), but never evaluates for a
    /// new bend. Hand/input release is commonly accompanied by a small involuntary movement as
    /// the gesture resolves — `update`'s turn detection has no way to distinguish that from a
    /// deliberate redirect, and would otherwise be free to insert an unwanted bend right at the
    /// moment of release.
    @discardableResult
    public mutating func end(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        applyAxisConstraint(rawPosition: rawPosition)
    }

    /// Pops and removes bends *this drag* created, for as long as the raw position has been
    /// pulled fully behind the current anchor along the locked axis — i.e. the user has retracted
    /// all the way through the most recently created bend, not just shrunk toward it. A `while`,
    /// not an `if`, so a single large single-frame retraction can undo more than one bend rather
    /// than only reading as "past the first one, ignore the rest". Deliberately not called from
    /// `end(rawPosition:)` — release jitter shouldn't be able to remove a bend any more than it
    /// should be able to create one.
    private mutating func undoLastBendsIfRetractedPast(rawPosition: SIMD3<Float>) {
        while let previous = undoStack.last {
            let alongLockedAxis = dot(rawPosition - neighborPosition, lockedAxis)
            guard alongLockedAxis < 0 else { return }

            guard let component = scene.get(component: TubePathComponent.self, for: tubeId) else { return }
            let removeIndex = isStart ? 1 : component.controlPoints.count - 2
            guard removeIndex >= 0,
                  ProceduralGeometryExtension.shared.removeControlPoint(entityId: tubeId, at: removeIndex)
            else {
                return
            }

            undoStack.removeLast()
            neighborPosition = previous.neighborPosition
            lockedAxis = previous.lockedAxis
            recentPositions.removeAll(keepingCapacity: true)
        }
    }

    private func applyAxisConstraint(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        let updatedDelta = rawPosition - neighborPosition
        // Floored on every call, not just when a bend commits — dragging the tip back toward
        // (or past) its own neighbor would otherwise shrink this segment toward zero or negative
        // length with nothing stopping it.
        let alongLockedAxis = max(dot(updatedDelta, lockedAxis), configuration.minimumSegmentLength)
        let constrainedPosition = neighborPosition + lockedAxis * alongLockedAxis

        writeControlPoint(position: constrainedPosition)
        return constrainedPosition
    }

    /// Writes `position` into the tube's start or end control point and pushes the update.
    private func writeControlPoint(position: SIMD3<Float>) {
        guard let component = scene.get(component: TubePathComponent.self, for: tubeId),
              !component.controlPoints.isEmpty
        else {
            return
        }
        var controlPoints = component.controlPoints
        controlPoints[isStart ? 0 : controlPoints.count - 1] = position
        ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, controlPoints)
    }
}
