//
//  ProceduralGeometryExtensionTests.swift
//  ProceduralGeometryExtensionTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ProceduralGeometryExtension
import UntoldEngine
import XCTest

/// Milestone 2 scaffold check: this package builds and links against `UntoldEngine` as an
/// out-of-tree dependency, and `Mesh.makeMesh(positions:normals:uvs:tangents:indices:name:)`
/// (the Milestone 1 addition to the engine) is reachable and usable from outside the engine
/// repo, using only the same public bootstrap entry point (`UntoldRenderer.create()`) a real
/// consumer app calls at startup. No tube-generation logic exists yet — that lands in later
/// milestones.
@MainActor
final class ProceduralGeometryExtensionTests: XCTestCase {
    private var renderer: UntoldRenderer!

    override func setUp() async throws {
        try await super.setUp()
        renderer = UntoldRenderer.create()
        XCTAssertNotNil(renderer, "UntoldRenderer.create() must succeed to exercise UntoldEngine's public API from this package")
    }

    func testPackageVersionIsExposed() {
        XCTAssertFalse(ProceduralGeometryExtensionInfo.version.isEmpty)
    }

    func testUntoldEngineMeshFactoryIsReachableFromThisPackage() throws {
        let mesh = Mesh.makeMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)],
            indices: [0, 1, 2],
            name: "ScaffoldTriangle"
        )

        XCTAssertNotNil(mesh)
    }
}
