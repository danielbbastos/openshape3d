//
//  GizmoSlabTests.swift
//  openshape3dTests
//
//  The gizmo's squares and arrows are thin 3D slabs: only the faces turned
//  toward the eye are drawn, the cap facing you on top.
//

import XCTest
import simd
@testable import openshape3d

final class GizmoSlabTests: XCTestCase {
    private func ground() throws -> GizmoSlab { try XCTUnwrap(GizmoSlab.square(.zxPlane)) }

    func testFromStraightAboveTheGroundSquareShowsOnlyItsTop() throws {
        let faces = try ground().visibleFaces(eye: SIMD3(0.25, 10, 0.25))
        XCTAssertEqual(faces.count, 1)
        XCTAssertTrue(faces[0].isCap)
        XCTAssertGreaterThan(faces[0].normal.y, 0.99)
    }

    func testFromACornerTheGroundSquareShowsItsTopAndTwoWalls() throws {
        // Looking into the gizmo's inside corner from the (+X, +Y, +Z) side.
        let faces = try ground().visibleFaces(eye: SIMD3(6, 5, 6))
        let caps = faces.filter(\.isCap)
        XCTAssertEqual(caps.count, 1)
        XCTAssertGreaterThan(caps[0].normal.y, 0.99)
        // The two near walls (+X, +Z); the rounded corner between them adds
        // a few narrow facets, all facing between those two.
        let walls = faces.filter { !$0.isCap }
        XCTAssertTrue(walls.contains { $0.normal.x > 0.99 })
        XCTAssertTrue(walls.contains { $0.normal.z > 0.99 })
        XCTAssertFalse(walls.contains { $0.normal.x < -0.5 || $0.normal.z < -0.5 })
        // The cap is painted last, on top of the walls.
        XCTAssertTrue(faces.last?.isCap ?? false)
    }

    func testFromBelowTheBottomCapShows() throws {
        let caps = try ground().visibleFaces(eye: SIMD3(0.25, -10, 0.25)).filter(\.isCap)
        XCTAssertEqual(caps.count, 1)
        XCTAssertLessThan(caps[0].normal.y, -0.99)
    }

    func testAnArrowLiesOnTheFaceThatTurnsTowardTheEye() {
        // The X arrow: from above it lies on the ground, from the front on
        // the XY wall.
        let fromAbove = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0.2, 5, 1))
        XCTAssertEqual(fromAbove, SIMD3(0, 1, 0))
        let fromFront = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0.2, 1, 5))
        XCTAssertEqual(fromFront, SIMD3(0, 0, 1))
    }

    func testWallsFaceOutward() throws {
        let slab = try ground()
        let centre = slab.outline.reduce(.zero, +) / Float(slab.outline.count)
        for wall in slab.faces where !wall.isCap {
            XCTAssertGreaterThan(simd_dot(wall.normal, wall.centre - centre), 0)
        }
    }
}
