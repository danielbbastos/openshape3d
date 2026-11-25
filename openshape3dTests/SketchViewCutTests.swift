//
//  SketchViewCutTests.swift
//  openshape3dTests
//
//  The flat sketch view's "hide the model in front of the sketch" cut:
//  which side of the sketch plane stays drawn, and when no cut is made at
//  all. Pure values — no session, no viewport.
//

import XCTest
import simd
@testable import openshape3d

final class SketchViewCutTests: XCTestCase {

    // MARK: - Which side is kept

    func testKeepsTheSideAwayFromTheCamera() {
        // Ground plane (normal +Y), camera above it: keep what's below.
        let keep = EditorViewModel.keptSide(of: .ground, eye: SIMD3(0, 100, 0))
        XCTAssertEqual(keep, SIMD3(0, -1, 0))
    }

    func testCameraUnderThePlaneKeepsWhatIsAbove() {
        let keep = EditorViewModel.keptSide(of: .ground, eye: SIMD3(0, -40, 10))
        XCTAssertEqual(keep, SIMD3(0, 1, 0))
    }

    func testNoCameraMeansNoCut() {
        XCTAssertNil(EditorViewModel.keptSide(of: .ground, eye: nil))
    }

    // MARK: - When to cut

    /// A part standing on the ground, sketched on the ground from above:
    /// nothing lies below the plane, so nothing is cut — the part stays.
    func testSketchOnTheGroundUnderAPartCutsNothing() {
        let cut = EditorViewModel.sketchCut(
            plane: .ground, keep: SIMD3(0, -1, 0),
            sceneBounds: (min: SIMD3(-10, 0, -10), max: SIMD3(10, 20, 10)))
        XCTAssertNil(cut)
    }

    /// A sketch through the middle of a part cuts away the half in front.
    func testSketchThroughAPartCutsInFrontOfThePlane() {
        var mid = SketchPlane.ground
        mid.origin = SIMD3(0, 10, 0)
        let keep = SIMD3<Double>(0, -1, 0)
        let cut = EditorViewModel.sketchCut(
            plane: mid, keep: keep,
            sceneBounds: (min: SIMD3(-10, 0, -10), max: SIMD3(10, 20, 10)))
        XCTAssertNotNil(cut)
        XCTAssertEqual(cut?.keep, keep)
        // The cut sits a hair toward the camera, so the sketch itself (and a
        // face lying exactly on the sketch plane) stays on the kept side.
        XCTAssertEqual(cut?.point.y ?? 0, 10.01, accuracy: 1e-9)
    }

    /// A sketch on the top face of a part (camera above) keeps the whole part.
    func testSketchOnATopFaceKeepsThePart() {
        var top = SketchPlane.ground
        top.origin = SIMD3(0, 20, 0)
        let cut = EditorViewModel.sketchCut(
            plane: top, keep: SIMD3(0, -1, 0),
            sceneBounds: (min: SIMD3(-10, 0, -10), max: SIMD3(10, 20, 10)))
        // The part is entirely on the kept side; the cut removes nothing of
        // it, and the plane sits above the top face.
        XCTAssertNotNil(cut)
        XCTAssertGreaterThan(cut?.point.y ?? 0, 20)
    }

    func testEmptySceneCutsNothing() {
        XCTAssertNil(EditorViewModel.sketchCut(plane: .ground, keep: SIMD3(0, -1, 0), sceneBounds: nil))
    }
}
