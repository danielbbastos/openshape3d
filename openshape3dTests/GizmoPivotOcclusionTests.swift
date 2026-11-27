//
//  GizmoPivotOcclusionTests.swift
//  openshape3dTests
//
//  A gizmo handle the centre dot sits on is hidden (and not grabbable):
//  Shapr3D never draws the dot over an arrow or a square.
//

import XCTest
import SwiftUI
@testable import openshape3d

final class GizmoPivotOcclusionTests: XCTestCase {
    private let center = CGPoint(x: 200, y: 200)

    func testAnArrowUnderTheDotIsCovered() {
        let arrow = MoveGizmoOverlay.arrowPath(center: CGPoint(x: 204, y: 196), direction: CGPoint(x: 0, y: -1))
        XCTAssertTrue(MoveGizmoOverlay.pivotCovers(arrow, center: center))
    }

    func testAnArrowJustTouchingTheRimIsCovered() {
        // The arrow's tail end starts 8.5 pt from the dot's centre: under the dot.
        let arrow = MoveGizmoOverlay.arrowPath(center: CGPoint(x: 200, y: 200 - 8.5 - 13.5),
                                               direction: CGPoint(x: 0, y: -1))
        XCTAssertTrue(MoveGizmoOverlay.pivotCovers(arrow, center: center))
    }

    func testAnArrowOutAtItsArmIsNot() {
        let arrow = MoveGizmoOverlay.arrowPath(center: CGPoint(x: 200, y: 140), direction: CGPoint(x: 0, y: -1))
        XCTAssertFalse(MoveGizmoOverlay.pivotCovers(arrow, center: center))
    }

    func testAPlaneSquareSwungBehindTheDotIsCovered() {
        let square = Path(CGRect(x: 190, y: 185, width: 24, height: 24))
        XCTAssertTrue(MoveGizmoOverlay.pivotCovers(square, center: center))
    }

    func testAFrontViewHidesNothingAtRest() {
        // True isometric projection at the gizmo's on-screen size (a unit
        // is ~100 pt, so the arrows sit ~80 pt out).
        let project: (SIMD3<Float>) -> CGPoint? = { v in
            let x = CGFloat(v.x - v.z) * 0.866, y = CGFloat(v.y) - CGFloat(v.x + v.z) * 0.5
            return CGPoint(x: 200 + x * 100, y: 200 - y * 100)
        }
        for part in [GizmoPart.xAxis, .yAxis, .zAxis, .xyPlane, .yzPlane, .zxPlane] {
            XCTAssertFalse(MoveGizmoOverlay.isHiddenByPivot(part, project: project, scale: false), "\(part)")
        }
    }
}
