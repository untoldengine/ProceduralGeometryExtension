//
//  TubeEndpointDragTests.swift
//  ProceduralGeometryExtensionTests
//
// Copyright (C) Untold Engine Studios
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import ProceduralGeometryExtension
import simd
@testable import UntoldEngine
import XCTest

/// `TubeEndpointDrag` has no XR/picking/rendering dependency of its own — these tests drive it
/// with synthetic raw positions, standing in for whatever an application's own input layer would
/// supply frame to frame (see the ProceduralGeometry demo for the XR-specific glue).
@MainActor
final class TubeEndpointDragTests: XCTestCase {
    private var renderer: UntoldRenderer!

    override func setUp() async throws {
        try await super.setUp()
        renderer = UntoldRenderer.create()
        XCTAssertNotNil(renderer)
        ProceduralGeometryExtension.shared.install()
    }

    override func tearDown() async throws {
        destroyAllEntities()
        EngineExtensionRegistry.shared.unregister(id: ProceduralGeometryExtension.shared.id)
        try await super.tearDown()
    }

    func testInit_returnsNilForEntityWithoutTubePathComponent() {
        let entityId = createEntity()
        XCTAssertNil(TubeEndpointDrag(tubeId: entityId, isStart: false))
    }

    func testUpdate_extendingAlongLockedAxis_movesTipWithoutInsertingABend() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // no bend — still a straight extension
        XCTAssertEqual(component.controlPoints[1], result)
        XCTAssertEqual(result.x, 2.5, accuracy: 1e-4)
    }

    func testUpdate_withReferenceRotation_locksToTheRotatedFrameNotWorldAxes() throws {
        // 90 degrees around Y: local +X maps to world (0, 0, -1), local +Z maps to world (1, 0, 0).
        // Models a tube placed against a real-world wall whose orientation has no relationship to
        // the scene's raw world X/Z — see TubePathComponent.referenceRotation.
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(0, 0, -2)], radius: 0.1, radialSegments: 8,
            referenceRotation: rotation
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        // Extend further along the rotated +X (world -Z) — a straight continuation in this tube's
        // own frame, even though it's not aligned with raw world +X/+Z at all.
        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(0, 0, -2 - Float(step) * 0.05))
        }
        var component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // still straight — no bend from extending
        XCTAssertEqual(result.z, -2.5, accuracy: 1e-4)

        // Redirect toward the rotated +Z (world +X) — this tube's own "90 degrees over", not raw
        // world +Z (0, 0, 1), which this motion isn't anywhere near.
        for step in 1 ... 20 {
            result = drag.update(rawPosition: SIMD3(Float(step) * 0.05, 0, -2.5))
        }

        component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // bend committed
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(0, 0, -2.5)), 1e-4)
        XCTAssertGreaterThan(result.x, 0.05) // followed the rotated +Z, not clamped near zero
        XCTAssertEqual(result.z, -2.5, accuracy: 1e-4) // and did NOT drift back toward raw world +Z
    }

    func testUpdate_turningToADifferentAxis_insertsA90DegreeBend() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        // Settle the recent-position window along +X first (matches the already-locked axis —
        // no turn should be read from this).
        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // Then redirect to +Z. x stays fixed at 2.5 for every one of these frames, so whichever
        // frame the turn is actually detected on, the resulting bend's x is exactly 2.5 either
        // way — not dependent on nailing the precise trigger frame. 20 steps comfortably clears
        // both the default axisDominanceMargin (reached once the window is mostly +Z, a handful
        // of steps in) and turnConfirmationFrames (6 more consecutive dominant reads after that).
        var result = SIMD3<Float>.zero
        for step in 1 ... 20 {
            result = drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // original start + new bend + tip
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(2.5, 0, 0)), 1e-4)
        XCTAssertEqual(component.controlPoints[2], result)
        XCTAssertEqual(result.x, 2.5, accuracy: 1e-4)
        XCTAssertGreaterThan(result.z, 0.05) // actually followed the turn, not clamped near zero
    }

    func testUpdate_briefOffAxisBlip_doesNotInsertABend() throws {
        // Regression coverage for the reported "any little movement... causes a bend" problem:
        // a handful of frames that read as a different dominant axis, immediately followed by a
        // return to the original heading, must never accumulate enough consecutive evidence to
        // commit — this is exactly what an un-pinch flinch or a brief hand resettle looks like.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // A brief blip toward +Z — enough steps to individually read as +Z-dominant (per the
        // hand-traced dominance crossover in testUpdate_turningToADifferentAxis...), but far
        // short of turnConfirmationFrames (6) before heading back toward +X.
        for step in 1 ... 4 {
            drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }
        // Settle back onto +X — the streak must have been reset by the blip's inconsistency, not
        // just paused, so this alone can't finish an already-in-progress streak from the blip.
        var result = SIMD3<Float>.zero
        for step in 1 ... 10 {
            result = drag.update(rawPosition: SIMD3(2.5 + Float(step) * 0.05, 0, 0.2))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // no bend — the blip never committed
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_implausibleTrackingGlitchBurst_doesNotInsertABend() throws {
        // Regression coverage for a distinct failure mode from the blip test above: not a few
        // frames of genuinely inconsistent *hand* motion, but a short burst of samples no real
        // hand could have produced — a hand-tracking glitch (occlusion, low confidence, a stale
        // extrapolated reading) — immediately followed by tracking recovering and reporting the
        // hand's real, unglitched position again. A single such glitch frame is already harmless
        // on its own (it briefly touches the recent window as its newest, then again as its
        // oldest sample nine calls later, each in isolation — never enough by itself to build
        // turnConfirmationFrames' streak). A multi-frame burst is the real risk: several
        // consecutive implausible samples can, together, read as sustained dominance in the
        // recent window even though none of them reflect where the hand actually was.
        // maximumFrameStep bounds how far the *effective* tracked position can follow such a
        // burst per frame, keeping it well short of ever reading as dominant before tracking
        // recovers.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // A 4-frame glitch burst, implausibly far in +Z (nowhere close to achievable hand speed
        // at any plausible frame rate), each frame's reading independently no more plausible than
        // the last.
        for _ in 1 ... 7 {
            drag.update(rawPosition: SIMD3(2.5, 0, 3.0))
        }
        // Tracking recovers: genuine +X extension resumes from the hand's real, unglitched path.
        var result = SIMD3<Float>.zero
        for step in 1 ... 15 {
            result = drag.update(rawPosition: SIMD3(2.5 + Float(step) * 0.05, 0, 0))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // no bend from the glitch burst
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_borderlineOffAxisDrift_neverInsertsABendNoMatterHowLongItPersists() throws {
        // A heading roughly 45 degrees off the locked axis is genuinely ambiguous — not clearly
        // "the user turned", not clearly "just noise". Per axisDominanceMargin, this must never
        // cross into dominant at all, no matter how long it's sustained, since simd's exact
        // 45-degree tiebreak plus the 0.2 margin puts it just on the "not dominant" side.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        var result = SIMD3<Float>.zero
        for step in 1 ... 30 {
            // Equal parts +X and +Z every step, so the recent-window heading stays pinned at
            // exactly 45 degrees the whole time, not just transiently while the window fills.
            result = drag.update(rawPosition: SIMD3(2.5 + Float(step) * 0.05, 0, Float(step) * 0.05))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // never dominant enough to commit
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testEnd_evenWithATurnLikeRelease_neverInsertsABend() throws {
        // Regression coverage: pinch/gesture release is commonly accompanied by a small
        // involuntary hand movement as the gesture resolves. `end` is what a caller should call
        // on that final frame instead of `update`, specifically so a release that happens to
        // read like a direction change doesn't insert an unwanted bend right as the user lets go.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // Exactly the kind of sample that DOES trigger a bend via `update` (see
        // testUpdate_turningToADifferentAxis_insertsA90DegreeBend) — the whole point is that
        // `end` must not react to it the same way.
        let result = drag.end(rawPosition: SIMD3(2.5, 0, 0.5))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // no bend inserted
        // Constrained against the still-locked +X axis — the z component is ignored entirely,
        // not followed into a new bend.
        XCTAssertLessThan(simd_distance(result, SIMD3(2.5, 0, 0)), 1e-5)
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_retractingPastABendThisDragCreated_undoesItAndResumesOnThePriorAxis() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        // Extend along +X, then turn to +Z — same setup as
        // testUpdate_turningToADifferentAxis_insertsA90DegreeBend, committing a bend at (2.5,0,0).
        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // 24 steps to clear both axisDominanceMargin and turnConfirmationFrames — see
        // testUpdate_turningToADifferentAxis_insertsA90DegreeBend for the hand-traced crossover.
        for step in 1 ... 24 {
            drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }
        var component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // bend committed

        // Now retract in -Z, past the bend's own z (0) — not just shrinking the +Z segment, but
        // pulling all the way back through the point where the turn happened. A constant (not
        // escalating) target well past zero, repeated for enough steps that maximumFrameStep's
        // clamp has room to walk the effective position all the way down to it — the tip's
        // accumulated +Z travel from the turn loop above means a single step can't just jump
        // straight past zero anymore — while bounding how far past zero it ends up overshooting
        // to exactly that target, not however far 20 escalating steps would have reached.
        for _ in 1 ... 20 {
            drag.update(rawPosition: SIMD3(2.5, 0, -0.3))
        }

        component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // the bend is gone
        XCTAssertEqual(component.controlPoints, [SIMD3(0, 0, 0), SIMD3(2.5, 0, 0)])

        // And the drag has resumed on the restored (pre-bend) +X axis: redirecting to +Y from
        // here creates a fresh bend at (2.5,0,0), same as a completely ordinary first turn would.
        var result = SIMD3<Float>.zero
        for step in 1 ... 24 {
            result = drag.update(rawPosition: SIMD3(2.5, Float(step) * 0.05, 0))
        }

        component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3)
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(2.5, 0, 0)), 1e-4)
        XCTAssertEqual(component.controlPoints[2], result)
        XCTAssertGreaterThan(result.y, 0.05)
    }

    func testUpdate_smallRetraction_doesNotUndoTheBend() throws {
        // Shrinking the current segment without ever crossing behind the bend that started it
        // should behave exactly as before this feature existed — no undo, just a clamp.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // 24 steps to clear both axisDominanceMargin and turnConfirmationFrames — see
        // testUpdate_turningToADifferentAxis_insertsA90DegreeBend for the hand-traced crossover.
        for step in 1 ... 24 {
            drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }
        // Retract, but stop short of the bend's own z (0) — only shrinks the +Z segment.
        drag.update(rawPosition: SIMD3(2.5, 0, 0.1))

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // still there
    }

    func testEnd_pastABend_doesNotUndoIt() throws {
        // Same reasoning as end() never inserting a bend from release jitter: it shouldn't remove
        // one either.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // 24 steps to clear both axisDominanceMargin and turnConfirmationFrames — see
        // testUpdate_turningToADifferentAxis_insertsA90DegreeBend for the hand-traced crossover.
        for step in 1 ... 24 {
            drag.update(rawPosition: SIMD3(2.5, 0, Float(step) * 0.05))
        }

        drag.end(rawPosition: SIMD3(2.5, 0, -0.5)) // well past the bend

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3) // bend untouched
    }

    func testUpdate_reversingDirection_neverInsertsABendAndClampsAtMinimumSegmentLength() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }
        // Reverse hard, well past the neighbor's own position (0,0,0) — a straight-back reversal
        // isn't a 90-degree corner (see TubeEndpointDrag.update's reversal exclusion), so this
        // should never insert a bend, no matter how far back it's pulled.
        var result = SIMD3<Float>.zero
        for step in 1 ... 70 {
            result = drag.update(rawPosition: SIMD3(2.5 - Float(step) * 0.05, 0, 0))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // never grew — no spurious bend
        XCTAssertEqual(result.x, 0.05, accuracy: 1e-4) // floored, not driven to/past the neighbor
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_draggingStart_insertsBendAdjacentToIndexZero() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: true))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(-Float(step) * 0.05, 0, 0))
        }
        var result = SIMD3<Float>.zero
        for step in 1 ... 20 {
            result = drag.update(rawPosition: SIMD3(-0.5, 0, Float(step) * 0.05))
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 3)
        // The dragged tip stays at index 0 for the whole drag (isStart), the new bend lands at
        // index 1, and the original far end (2,0,0) is undisturbed at index 2.
        XCTAssertEqual(component.controlPoints[0], result)
        XCTAssertLessThan(simd_distance(component.controlPoints[1], SIMD3(-0.5, 0, 0)), 1e-4)
        XCTAssertEqual(component.controlPoints[2], SIMD3(2, 0, 0))
    }

    func testUpdate_naturalArmArcWhileExtending_neverInsertsASpuriousBend() throws {
        // Regression coverage for a real reported case: a hand held out and swept sideways
        // doesn't travel in a straight line — it travels in an arc, because it's pivoting from a
        // shoulder/elbow, not sliding on a rail. This simulates that arc geometrically (a hand
        // pivoting around a point behind/beside the body, arm-length radius) and asserts that
        // sweeping through a full natural range of motion while extending along +X never reads as
        // a deliberate turn into +Z, no matter how far the sweep goes.
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 10 {
            drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
        }

        // Arm-length pivot (0.5m), swept through 70 degrees over 140 samples — a wide, slow,
        // entirely natural reach to the side. Position(theta) = anchor + r*(sin theta, 0, 1-cos
        // theta): starts moving purely along +X (d/dtheta at theta=0 is pure +X) and curves into
        // +Z as theta grows, exactly like a hand arcing back toward the body while reaching right.
        let radius: Float = 0.5
        let anchor = SIMD3<Float>(2.5, 0, 0)
        var result = SIMD3<Float>.zero
        for step in 1 ... 140 {
            let theta = Float(step) / 140 * (70 * .pi / 180)
            let position = anchor + SIMD3(radius * sin(theta), 0, radius * (1 - cos(theta)))
            result = drag.update(rawPosition: position)
        }

        let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
        XCTAssertEqual(component.controlPoints.count, 2) // still one straight segment — no bend
        XCTAssertEqual(component.controlPoints[1], result)
    }

    func testUpdate_returnValueAlwaysMatchesWhatWasWrittenToTheTube() throws {
        let entityId = try XCTUnwrap(ProceduralGeometryExtension.shared.createTubeEntity(
            controlPoints: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)], radius: 0.1, radialSegments: 8
        ))
        var drag = try XCTUnwrap(TubeEndpointDrag(tubeId: entityId, isStart: false))

        for step in 1 ... 5 {
            let result = drag.update(rawPosition: SIMD3(2 + Float(step) * 0.05, 0, 0))
            let component = try XCTUnwrap(scene.get(component: TubePathComponent.self, for: entityId))
            XCTAssertEqual(component.controlPoints.last, result)
        }
    }
}
