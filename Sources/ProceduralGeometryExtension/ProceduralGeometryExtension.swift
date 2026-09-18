//
//  ProceduralGeometryExtension.swift
//  ProceduralGeometryExtension
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import UntoldEngine

/// Namespace for the package. The name is deliberately capability-agnostic: the first (and
/// currently only) capability built on top of it is tube generation from a series of 3D
/// control points (see `TubeGeometryGenerator`), but the engine-facing pieces (an
/// `EngineExtension`, `Component`s, entity-creation APIs) are meant to host other procedural
/// geometry capabilities later without renaming the package.
public enum ProceduralGeometryExtensionInfo {
    public static let version = "0.1.0"
}
