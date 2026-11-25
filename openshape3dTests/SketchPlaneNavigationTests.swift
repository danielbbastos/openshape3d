//
//  SketchPlaneNavigationTests.swift
//  openshape3dTests
//
//  Using sketch planes (spec §2.3, §7.2). Pure values.
//

import XCTest
import simd
@testable import openshape3d

final class SketchPlaneNavigationTests: XCTestCase {

    private typealias Nav = SketchPlaneNavigation

    func testEachNamedViewDefinesAnOriginPlaneFacingTheEye() throws {
        for view in StandardView.allCases where view != .isometric {
            let eye = try XCTUnwrap(Nav.eyeDirection(of: view))
            let plane = try XCTUnwrap(Nav.originPlane(facing: eye))
            XCTAssertEqual(simd_length(plane.origin), 0, accuracy: 1e-12)
            XCTAssertEqual(simd_dot(simd_normalize(plane.normal), eye), 1, accuracy: 1e-9, view.rawValue)
        }
    }

    /// The eye directions agree with where the camera really goes.
    func testEyeDirectionsMatchTheCameraPoses() throws {
        for view in StandardView.allCases where view != .isometric {
            let eye = try XCTUnwrap(Nav.eyeDirection(of: view))
            let camera = view.applied(to: TurntableCamera())
            let offset = simd_normalize(camera.position - camera.target)
            let actual = SIMD3(Double(offset.x), Double(offset.y), Double(offset.z))
            XCTAssertEqual(simd_dot(actual, eye), 1, accuracy: 1e-5, view.rawValue)
        }
    }

    func testTopDefinesTheGroundWithItsOwnAxes() throws {
        let plane = try XCTUnwrap(Nav.originPlane(facing: SIMD3(0, 7, 0)))
        XCTAssertEqual(simd_distance(plane.xAxis, SketchPlane.ground.xAxis), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(plane.yAxis, SketchPlane.ground.yAxis), 0, accuracy: 1e-9)
    }

    func testEdgesCornersAndIsometricDefineNoPlane() {
        XCTAssertNil(Nav.eyeDirection(of: .isometric))
        XCTAssertNil(Nav.originPlane(facing: SIMD3(1, 1, 1)))
        XCTAssertNil(Nav.originPlane(facing: SIMD3(1, 1, 0)))
        XCTAssertNil(Nav.originPlane(facing: .zero))
    }

    func testTheFlightInStaysFlat() {
        var tracker = Nav.FlatTracker()
        for angle: Double in [180, 120, 45, 11, 2] {
            tracker.cameraMoved(offAxisDegrees: angle, leaveDegrees: 10)
            XCTAssertTrue(tracker.isFlat)
            XCTAssertFalse(tracker.settled)
        }
    }

    func testOrbitingAwayLeavesAndNormalToSketchReturns() {
        var tracker = Nav.FlatTracker()
        tracker.cameraMoved(offAxisDegrees: 0, leaveDegrees: 10)
        tracker.cameraMoved(offAxisDegrees: 9, leaveDegrees: 10)
        XCTAssertTrue(tracker.isFlat)
        tracker.cameraMoved(offAxisDegrees: 11, leaveDegrees: 10)
        XCTAssertFalse(tracker.isFlat)
        tracker.cameraMoved(offAxisDegrees: 5, leaveDegrees: 10)
        XCTAssertFalse(tracker.isFlat)
        tracker.cameraMoved(offAxisDegrees: 0.2, leaveDegrees: 10)
        XCTAssertTrue(tracker.isFlat)
    }
}
