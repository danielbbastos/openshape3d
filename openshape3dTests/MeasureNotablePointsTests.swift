//
//  MeasureNotablePointsTests.swift
//  openshape3dTests
//
//  Measure's notable points: corners, edge middles and circle centres from
//  the kernel edges (not every facet corner of a tessellated rim).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class MeasureNotablePointsTests: XCTestCase {

    private func body(_ solid: BRepHandle) -> Body {
        var body = Body(id: BodyID(), name: "Part", transform: .identity, primitive: nil,
                        euclidMesh: Euclid.Mesh([]), revision: 0)
        XCTAssertTrue(body.adoptBRep(solid))
        return body
    }

    private func contains(_ points: [SIMD3<Double>], _ p: SIMD3<Double>) -> Bool {
        points.contains { simd_length($0 - p) < 1e-6 }
    }

    func testABoxOffersItsCornersAndEdgeMiddles() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let rect = Profile(loop: [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)],
                           kind: .polygonal, sourceEntityIDs: Set(ids), edgeEntityIDs: ids)
        let solid = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: rect, holes: [], extras: [], zMin: 0, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let points = MeasureNotablePoints.points(of: body(solid))
        XCTAssertEqual(points.count, 8 + 12, "8 corners and 12 edge middles")
        XCTAssertTrue(contains(points, SIMD3(4, 4, 4)))
        XCTAssertTrue(contains(points, SIMD3(2, 0, 0)), "the middle of an edge")
    }

    func testACylinderOffersBothCapCentres() throws {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let rect = Profile(loop: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 20), SIMD2(0, 20)],
                           kind: .polygonal, sourceEntityIDs: Set(ids), edgeEntityIDs: ids)
        let solid = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: rect, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0), angleRadians: 2 * .pi))
        let points = MeasureNotablePoints.points(of: body(solid))
        XCTAssertTrue(contains(points, .zero), "bottom cap centre")
        XCTAssertTrue(contains(points, SIMD3(0, 20, 0)), "top cap centre")
        XCTAssertLessThan(points.count, 16, "rim facets are not notable points")
    }

    func testRepeatsCountOnce() {
        let p = SIMD3<Double>(1, 2, 3)
        XCTAssertEqual(MeasureNotablePoints.deduplicated([p, p + SIMD3(1e-9, 0, 0), SIMD3(0, 0, 0)]).count, 2)
    }
}
