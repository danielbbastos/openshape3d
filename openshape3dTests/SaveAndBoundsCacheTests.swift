//
//  SaveAndBoundsCacheTests.swift
//  openshape3dTests
//
//  The two caches behind a fast undo on a large model: a mesh's bounding
//  box is worked out once per set of positions, and autosave re-encodes
//  only bodies whose geometry changed since it last wrote them.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class SaveAndBoundsCacheTests: XCTestCase {

    private func mesh(_ points: [SIMD3<Float>]) -> RenderMesh {
        RenderMesh(positions: points, normals: points.map { _ in SIMD3(0, 1, 0) },
                   indices: [0, 1, 2])
    }

    func testBoundsFollowTheirPositions() {
        var m = mesh([SIMD3(0, 0, 0), SIMD3(1, 2, 3), SIMD3(-1, 0, 0)])
        XCTAssertEqual(m.localAABB.min, SIMD3(-1, 0, 0))
        XCTAssertEqual(m.localAABB.max, SIMD3(1, 2, 3))

        let copy = m
        m.positions[1] = SIMD3(5, 5, 5)
        XCTAssertEqual(m.localAABB.max, SIMD3(5, 5, 5), "a changed vertex moves the box")
        XCTAssertEqual(copy.localAABB.max, SIMD3(1, 2, 3), "a copy keeps its own box")

        m.positions = [SIMD3(10, 10, 10), SIMD3(11, 11, 11), SIMD3(12, 12, 12)]
        XCTAssertEqual(m.localAABB.min, SIMD3(10, 10, 10), "new positions, new box")
    }

    func testTheBoxIsNotPartOfTheMeshValue() {
        let a = mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        let b = mesh([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        _ = a.localAABB   // one filled, one not
        XCTAssertEqual(a, b)
    }

    func testSavedGeometryNoticesEveryGeometryChange() {
        let body = Body(name: "Box", euclidMesh: .cube(size: 2), revision: 1)
        let saved = SavedGeometry(body)
        XCTAssertTrue(saved.matches(body), "unchanged")

        var moved = body
        moved.transform.translation = SIMD3(5, 0, 0)
        moved.name = "Renamed"
        moved.isHidden = true
        XCTAssertTrue(saved.matches(moved), "placement, name and visibility are not geometry")

        var reshaped = body
        reshaped.render.positions[0] += SIMD3(0.5, 0, 0)
        XCTAssertFalse(saved.matches(reshaped), "a moved vertex is new geometry")

        var rebuilt = body
        rebuilt.render = Body(name: "Box", euclidMesh: .cube(size: 3), revision: 2).render
        XCTAssertFalse(saved.matches(rebuilt), "a new mesh is new geometry")

        var primitive = body
        primitive.primitive = .box(width: 2, depth: 2, height: 2)
        XCTAssertFalse(saved.matches(primitive), "a primitive change is new geometry")
    }
}
