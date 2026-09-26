//
//  TubeTranslationDrag.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import UntoldEngine

/// Interactive rigid-body translation of an *entire* tube: every control point shifts by the
/// same delta, so the tube's own shape (every segment length, every corner angle) is completely
/// unchanged — only its position in space moves. Unconstrained: unlike `TubeEndpointDrag`/
/// `TubeInteriorBendDrag`, there's no cardinal-axis locking here, since moving a tube doesn't
/// touch any angle *between* its own segments, so there's no structural reason to restrict it.
///
/// Has no knowledge of picking, gestures, hand tracking, or any rendering/proxy entity — same
/// design as the other two drag types, just for the whole tube instead of one point on it.
///
/// Unlike those two, this type has no `end(rawPosition:)` — release jitter can't accidentally
/// trigger a structural change here (there isn't one to trigger; every frame just recomputes a
/// uniform shift), so there's nothing for a final frame to need different handling for.
///
/// Also unlike those two, `init` takes an explicit `dragOrigin` rather than deriving one from the
/// tube's own geometry: an endpoint or an interior bend each have one well-defined anchor point,
/// but grabbing a tube to move it doesn't — the caller can start that drag from anywhere along
/// its length, so where "the drag started" has to come from the caller's own input, not from the
/// tube's control points.
public struct TubeTranslationDrag {
    public let tubeId: EntityID
    private let dragOrigin: SIMD3<Float>
    private let originalControlPoints: [SIMD3<Float>]

    /// Begins moving `tubeId` as a rigid body. `dragOrigin` should be the raw position of
    /// whatever the caller is using to drag (a pinch position, a mouse ray hit, etc.) at the
    /// moment the gesture started. Returns `nil` if the tube has no `TubePathComponent`.
    public init?(tubeId: EntityID, dragOrigin: SIMD3<Float>) {
        guard let component = scene.get(component: TubePathComponent.self, for: tubeId) else {
            return nil
        }
        self.tubeId = tubeId
        self.dragOrigin = dragOrigin
        originalControlPoints = component.controlPoints
    }

    /// Call every frame with the current raw position of whatever the caller is using to drag.
    /// Returns the achieved translation delta, in case the caller finds it useful (e.g. for
    /// moving its own visual representation of the grab point) — most callers can ignore it,
    /// since the tube's own mesh already reflects the new position after this call.
    @discardableResult
    public mutating func update(rawPosition: SIMD3<Float>) -> SIMD3<Float> {
        let delta = rawPosition - dragOrigin
        let newControlPoints = originalControlPoints.map { $0 + delta }
        ProceduralGeometryExtension.shared.setControlPoints(entityId: tubeId, newControlPoints)
        return delta
    }
}
