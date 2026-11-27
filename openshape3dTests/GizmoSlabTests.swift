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
        XCTAssertLessThan(simd_length(fromAbove - SIMD3(0, 1, 0)), 1e-5)
        let fromFront = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0.2, 1, 5))
        XCTAssertLessThan(simd_length(fromFront - SIMD3(0, 0, 1)), 1e-5)
    }

    func testWallsFaceOutward() throws {
        let slab = try ground()
        let centre = slab.outline.reduce(.zero, +) / Float(slab.outline.count)
        for wall in slab.faces where !wall.isCap {
            XCTAssertGreaterThan(simd_dot(wall.normal, wall.centre - centre), 0)
        }
    }

    func testAnArrowTurnsSmoothlyBetweenFaces() {
        // Orbit the eye round the X axis in 1° steps: the arrow's plane
        // normal never jumps (the old rule snapped 90° at 45°).
        var previous = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0, 1, 0))
        for degree in 1...90 {
            let a = Float(degree) * .pi / 180
            let n = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0, cos(a), sin(a)))
            XCTAssertLessThan(simd_length(n - previous), 0.08, "jump at \(degree)°")
            XCTAssertEqual(simd_dot(n, SIMD3(1, 0, 0)), 0, accuracy: 1e-5)
            previous = n
        }
        // Halfway it faces the eye squarely.
        let mid = GizmoSlab.arrowPlaneNormal(axis: SIMD3(1, 0, 0), eyeDirection: SIMD3(0, 1, 1))
        XCTAssertEqual(abs(simd_dot(mid, simd_normalize(SIMD3(0, 1, 1)))), 1, accuracy: 1e-4)
    }

    func testTheCurvedArrowLiesInItsRingPlane() throws {
        let arc = try XCTUnwrap(GizmoSlab.arc(.yRing))
        XCTAssertEqual(abs(arc.normal.y), 1, accuracy: 1e-5)
        for p in arc.outline { XCTAssertEqual(p.y, 0, accuracy: 1e-5) }
        // From above its top faces up, and it shows its outer wall from a corner.
        let caps = arc.visibleFaces(eye: SIMD3(0.5, 10, 0.5)).filter(\.isCap)
        XCTAssertEqual(caps.count, 1)
        XCTAssertGreaterThan(caps[0].normal.y, 0.99)
        XCTAssertTrue(arc.visibleFaces(eye: SIMD3(6, 3, 6)).contains { !$0.isCap })
    }

    func testSquaresStandClearOfTheCentre() throws {
        let square = try XCTUnwrap(GizmoSlab.square(.xyPlane))
        let nearest = square.outline.map { simd_length($0) }.min() ?? 0
        XCTAssertGreaterThan(nearest, 0.2)
    }
}
