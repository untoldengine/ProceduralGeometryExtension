//
//  NearestCardinalAxisTests.swift
//  ProceduralGeometryExtensionTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import ProceduralGeometryExtension
import simd
import XCTest

final class NearestCardinalAxisTests: XCTestCase {
    func testNearestCardinalAxis_noRotation_snapsToWorldAxes() {
        XCTAssertEqual(nearestCardinalAxis(to: SIMD3(0.9, 0.1, 0.05)), SIMD3(1, 0, 0))
        XCTAssertEqual(nearestCardinalAxis(to: SIMD3(0.1, -0.9, 0.05)), SIMD3(0, -1, 0))
    }

    func testNearestCardinalAxis_zeroLengthDirection_fallsBackWithoutCrashing() {
        XCTAssertEqual(nearestCardinalAxis(to: .zero), SIMD3(1, 0, 0))
    }

    func testNearestCardinalAxis_withRotation_snapsToTheRotatedFrameNotWorldAxes() {
        // 90 degrees around Y: local +X maps to world (0, 0, -1), local +Z maps to world (1, 0, 0).
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))

        // A world direction close to the *rotated* +X (i.e. world -Z) should snap to that rotated
        // axis, not to the nearest raw world axis (which this same direction is nowhere near).
        let result = nearestCardinalAxis(to: SIMD3(0.05, 0.02, -0.9), relativeTo: rotation)
        XCTAssertEqual(simd_distance(result, SIMD3(0, 0, -1)), 0, accuracy: 1e-5)
    }

    func testNearestCardinalAxis_withRotation_upAxisIsUnaffected() {
        // The reference frame this extension actually uses (a wall-derived rotation) never tilts
        // the vertical axis — confirm a rotation around Y leaves world +Y exactly as the nearest
        // axis for an up-ish direction, same as with no rotation at all.
        let rotation = simd_quatf(angle: .pi / 4, axis: SIMD3(0, 1, 0))
        let result = nearestCardinalAxis(to: SIMD3(0.05, 0.95, -0.05), relativeTo: rotation)
        XCTAssertEqual(simd_distance(result, SIMD3(0, 1, 0)), 0, accuracy: 1e-5)
    }

    func testNearestCardinalAxis_withRotation_exactRoundTripReturnsTheSameWorldVector() {
        let rotation = simd_quatf(angle: 0.6, axis: normalize(SIMD3<Float>(0, 1, 0)))
        let rotatedLocalX = rotation.act(SIMD3(1, 0, 0))
        let result = nearestCardinalAxis(to: rotatedLocalX, relativeTo: rotation)
        XCTAssertEqual(simd_distance(result, rotatedLocalX), 0, accuracy: 1e-5)
    }
}
