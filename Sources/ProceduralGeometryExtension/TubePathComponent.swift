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
    public var assetName: String = "Tube"

    /// Bumped by every `ProceduralGeometryExtension` editing call. Compared against the
    /// extension's own last-built record to detect changes made some other way (a scene load,
    /// or a script writing these fields directly) without diffing geometry every frame.
    public var contentVersion: Int = 0

    public required init() {}
}
