//
//  TubePathComponent.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import simd
import UntoldEngine

/// The authoritative shape data for a tube entity created by `ProceduralGeometryExtension`.
///
/// A class, not a struct: `Scene.get(component:for:)` hands back a value copy for struct
/// components, so mutating it wouldn't persist back into the ECS without an explicit write-back
/// call the engine doesn't expose. Reference-type components don't have that problem — the copy
/// `get` returns is a reference alias to the same stored instance, so editing its fields is
/// enough (this mirrors the one existing `Component & Codable` type in the engine,
/// `ScriptComponent`, which is a class for the same reason).
public final class TubePathComponent: Component, Codable {
    public var controlPoints: [SIMD3<Float>] = []
    public var radius: Float = 0.25
    public var radialSegments: Int = 12
    public var capStart: Bool = false
    public var capEnd: Bool = false
    /// When set (and > 0), interior corners are rounded with a tangent-arc fillet instead of a
    /// sharp miter joint. `nil` reproduces the original sharp-corner behavior.
    public var bendRadius: Float?
    public var assetName: String = "Tube"

    /// Raw storage for `referenceRotation` — a `SIMD4<Float>` (x, y, z, w) rather than
    /// `simd_quatf` directly, for unambiguous `Codable` conformance. Callers should use
    /// `referenceRotation`, not this, directly.
    public var referenceRotationVector: SIMD4<Float>?
    /// Optional rotation defining this tube's own reference frame for axis-locked editing
    /// (`TubeEndpointDrag`/`TubeInteriorBendDrag`) — `nil` means "snap to raw world axes," which
    /// is every tube's behavior before this field existed. Set this when a tube's natural editing
    /// directions should be relative to something other than the scene's arbitrary world
    /// coordinate system — e.g. the real-world wall it was placed against, whose orientation has
    /// no necessary relationship to world X/Z.
    public var referenceRotation: simd_quatf? {
        get { referenceRotationVector.map { simd_quatf(vector: $0) } }
        set { referenceRotationVector = newValue?.vector }
    }

    /// Bumped by every `ProceduralGeometryExtension` editing call. Compared against the
    /// extension's own last-built record to detect changes made some other way (a scene load,
    /// or a script writing these fields directly) without diffing geometry every frame.
    public var contentVersion: Int = 0

    public required init() {}
}
