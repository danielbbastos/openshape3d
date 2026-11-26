//
//  TwoFingerPanTrackerTests.swift
//  openshape3dTests
//
//  Lifting the fingers one at a time must not pan: the reported centroid
//  jumps to the last finger, the hand has not moved.
//

import XCTest
import CoreGraphics
@testable import openshape3d

final class TwoFingerPanTrackerTests: XCTestCase {

    func testTwoFingersMovingPan() {
        var t = TwoFingerPanTracker()
        t.begin(at: CGPoint(x: 100, y: 100), touches: 2)
        XCTAssertEqual(t.move(to: CGPoint(x: 110, y: 95), touches: 2), CGSize(width: 10, height: -5))
        XCTAssertEqual(t.move(to: CGPoint(x: 115, y: 95), touches: 2), CGSize(width: 5, height: 0))
    }

    /// Fingers 80 pt apart, centroid at 100; one lifts and the centroid
    /// lands on the other, 40 pt away. No pan, then or after.
    func testLiftingOneFingerDoesNotPan() {
        var t = TwoFingerPanTracker()
        t.begin(at: CGPoint(x: 100, y: 100), touches: 2)
        _ = t.move(to: CGPoint(x: 100, y: 100), touches: 2)
        XCTAssertNil(t.move(to: CGPoint(x: 140, y: 100), touches: 1))
        XCTAssertNil(t.move(to: CGPoint(x: 141, y: 100), touches: 1))
    }

    /// A finger landing mid-pan re-anchors; movement resumes from there.
    func testAFingerLandingReanchors() {
        var t = TwoFingerPanTracker()
        t.begin(at: CGPoint(x: 100, y: 100), touches: 2)
        XCTAssertNil(t.move(to: CGPoint(x: 80, y: 100), touches: 3))
        XCTAssertEqual(t.move(to: CGPoint(x: 90, y: 100), touches: 3), CGSize(width: 10, height: 0))
    }

    func testNothingAfterEnd() {
        var t = TwoFingerPanTracker()
        t.begin(at: .zero, touches: 2)
        t.end()
        XCTAssertNil(t.move(to: CGPoint(x: 5, y: 5), touches: 2))
    }
}
