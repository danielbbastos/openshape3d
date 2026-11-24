//
//  MeasureQueryTests.swift
//  openshape3dTests
//
//  Measure ▸ Object Measurements (spec §16.3): the rows for faces, edges,
//  bodies and sketch entities, exact from the kernel and from the mesh
//  fallback. Pure values: OCCT solids and Bodies, never a DocumentSession.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class MeasureQueryTests: XCTestCase {

    // MARK: Fixtures

    /// An x × y × z box with its min corner at `at`.
    private func box(_ x: Double, _ y: Double, _ z: Double, at: SIMD3<Double> = .zero) throws -> Body {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let rect = Profile(loop: [SIMD2(at.x, at.y), SIMD2(at.x + x, at.y),
                                  SIMD2(at.x + x, at.y + y), SIMD2(at.x, at.y + y)],
                           kind: .polygonal, sourceEntityIDs: Set(ids), edgeEntityIDs: ids)
        let solid = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: rect, holes: [], extras: [], zMin: at.z, zMax: at.z + z,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        return try body(solid)
    }

    /// A tube (or a solid cylinder when `inner` is 0) along +Y, `height` tall.
    private func tube(outer: Double, inner: Double = 0, height: Double) throws -> Body {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let rect = Profile(loop: [SIMD2(inner, 0), SIMD2(outer, 0), SIMD2(outer, height), SIMD2(inner, height)],
                           kind: .polygonal, sourceEntityIDs: Set(ids), edgeEntityIDs: ids)
        let solid = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: rect, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0), angleRadians: 2 * .pi))
        return try body(solid)
    }

    private func body(_ solid: BRepHandle, transform: Transform3D = .identity) throws -> Body {
        var body = Body(id: BodyID(), name: "Part", transform: transform, primitive: nil,
                        euclidMesh: Euclid.Mesh([]), revision: 0)
        XCTAssertTrue(body.adoptBRep(solid))
        return body
    }

    /// The kernel face of `body` whose plane normal is `normal`, or whose
    /// cylinder has `radius`.
    private func faceIndex(_ body: Body, normal: SIMD3<Double>? = nil, radius: Double? = nil) throws -> Int {
        let world = try XCTUnwrap(MeasureItem.worldBRep(of: body))
        let info = OCCTKernel.faceInfo(world)
        let match = info.first { face in
            switch face.signature?.kind {
            case .planar?: return normal.map { simd_dot($0, face.normal) > 1 - 1e-9 } ?? false
            case .cylindrical(let r)?: return radius.map { abs($0 - r) < 1e-9 } ?? false
            default: return false
            }
        }
        return try XCTUnwrap(match?.index)
    }

    private func face(_ body: Body, normal: SIMD3<Double>? = nil, radius: Double? = nil) throws -> MeasureItem {
        MeasureItem.face(of: body, kernelIndex: try faceIndex(body, normal: normal, radius: radius), triangles: [])
    }

    private func row(_ kind: MeasureRow.Kind, in rows: [MeasureRow]) -> MeasureRow? {
        rows.first { $0.kind == kind }
    }

    override func tearDown() {
        MeasureQuery.exact = { OCCTKernel.minimumDistance($0, $1) }
        super.tearDown()
    }

    // MARK: Single items and sums

    func testFaceAreasSumAcrossTheSelection() throws {
        let part = try box(10, 20, 30)
        let top = try face(part, normal: SIMD3(0, 0, 1))
        let side = try face(part, normal: SIMD3(1, 0, 0))
        XCTAssertEqual(row(.area, in: MeasureQuery.rows(for: [top], deltas: false))?.value ?? 0, 200, accuracy: 1e-6)
        let both = MeasureQuery.rows(for: [top, side, try face(part, normal: SIMD3(0, 1, 0))], deltas: false)
        XCTAssertEqual(row(.area, in: both)?.value ?? 0, 200 + 600 + 300, accuracy: 1e-6)
    }

    func testABodyReadsItsExactVolume() throws {
        let cylinder = try tube(outer: 10, height: 20)
        let rows = MeasureQuery.rows(for: [MeasureItem.body(cylinder)], deltas: false)
        XCTAssertEqual(row(.volume, in: rows)?.value ?? 0, .pi * 100 * 20, accuracy: 1e-6)
    }

    func testACylinderFaceReadsRadiusAndDiameter() throws {
        let cylinder = try tube(outer: 10, height: 20)
        let rows = MeasureQuery.rows(for: [try face(cylinder, radius: 10)], deltas: false)
        XCTAssertEqual(row(.radius, in: rows)?.value ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(row(.diameter, in: rows)?.value ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(row(.area, in: rows)?.value ?? 0, 2 * .pi * 10 * 20, accuracy: 1e-6)
    }

    func testASketchArcReadsItsCentralAngle() {
        let arc = SketchEntity.arc(id: UUID(), center: .zero, radius: 5, startAngle: 0, endAngle: .pi / 3)
        let item = MeasureItem.sketchEntity(arc, sketchID: SketchID(), plane: .ground)
        let rows = MeasureQuery.rows(for: [item], deltas: false)
        XCTAssertEqual(row(.angle, in: rows)?.value ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(row(.radius, in: rows)?.value ?? 0, 5, accuracy: 1e-12)
        XCTAssertEqual(row(.length, in: rows)?.value ?? 0, 5 * .pi / 3, accuracy: 1e-9)
    }

    // MARK: Pairs

    func testOppositeFacesAreParallelAtTheBoxHeight() throws {
        let part = try box(10, 20, 30)
        let rows = MeasureQuery.rows(for: [try face(part, normal: SIMD3(0, 0, 1)),
                                           try face(part, normal: SIMD3(0, 0, -1))], deltas: false)
        XCTAssertEqual(row(.parallelDistance, in: rows)?.value ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(row(.minDistance, in: rows)?.value ?? 0, 30, accuracy: 1e-6)
        XCTAssertEqual(row(.angle, in: rows)?.value ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(row(.perpendicularAngle, in: rows))
    }

    func testAdjacentFacesMeetAtRightAngles() throws {
        let part = try box(10, 20, 30)
        let rows = MeasureQuery.rows(for: [try face(part, normal: SIMD3(0, 0, 1)),
                                           try face(part, normal: SIMD3(1, 0, 0))], deltas: false)
        XCTAssertEqual(row(.angle, in: rows)?.value ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(row(.minDistance, in: rows)?.value ?? -1, 0, accuracy: 1e-6)
        XCTAssertNil(row(.parallelDistance, in: rows))
        XCTAssertNil(row(.perpendicularAngle, in: rows), "90° has no perpendicular complement to show")
    }

    func testConcentricCylindersReadTheirRadialDifference() throws {
        let pipe = try tube(outer: 10, inner: 6, height: 20)
        let rows = MeasureQuery.rows(for: [try face(pipe, radius: 10), try face(pipe, radius: 6)], deltas: false)
        XCTAssertEqual(row(.parallelDistance, in: rows)?.value ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(row(.centralDistance, in: rows)?.value ?? -1, 0, accuracy: 1e-9)
    }

    func testTwoBodiesReadTheDistanceBetweenTheirCentresOfGravity() throws {
        let a = try box(10, 10, 10)
        let b = try box(10, 10, 10, at: SIMD3(30, 40, 0))
        let rows = MeasureQuery.rows(for: [MeasureItem.body(a), MeasureItem.body(b)], deltas: false)
        XCTAssertEqual(row(.centralDistance, in: rows)?.value ?? 0, 50, accuracy: 1e-6)
        // Closest corners: (10,10,·) to (30,40,·).
        XCTAssertEqual(row(.minDistance, in: rows)?.value ?? 0, simd_length(SIMD2(20.0, 30.0)), accuracy: 1e-6)
    }

    func testSkewSketchLinesReadTheirShortestSpan() {
        let lower = SketchEntity.line(id: UUID(), a: SIMD2(-10, 0), b: SIMD2(10, 0))
        let upper = SketchEntity.line(id: UUID(), a: SIMD2(0, -10), b: SIMD2(0, 10))
        let a = MeasureItem.sketchEntity(lower, sketchID: SketchID(), plane: .ground)
        let b = MeasureItem.sketchEntity(upper, sketchID: SketchID(), plane: .offsetGround(y: 5))
        let rows = MeasureQuery.rows(for: [a, b], deltas: false)
        XCTAssertEqual(row(.minDistance, in: rows)?.value ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(row(.angle, in: rows)?.value ?? 0, 90, accuracy: 1e-9)
    }

    func testDeltasAddTheAxisComponents() {
        let p = MeasureItem.point(SIMD3(0, 0, 0)), q = MeasureItem.point(SIMD3(3, 4, 12))
        XCTAssertEqual(MeasureQuery.rows(for: [p, q], deltas: false).map(\.kind), [.distance])
        let rows = MeasureQuery.rows(for: [p, q], deltas: true)
        XCTAssertEqual(rows.map(\.kind), [.distance, .dx, .dy, .dz])
        XCTAssertEqual(rows.map(\.value), [13, 3, 4, 12])
    }

    func testThreePointsReadTheAngleAtTheMiddleOne() {
        let rows = MeasureQuery.rows(for: [.point(SIMD3(1, 0, 0)), .point(.zero), .point(SIMD3(0, 0, 1))],
                                     deltas: false)
        XCTAssertEqual(rows.map(\.kind), [.angle])
        XCTAssertEqual(rows.first?.value ?? 0, 90, accuracy: 1e-12)
    }

    // MARK: Kernel and fallback agree

    /// A moved body measures where it is drawn, and its kernel faces keep
    /// their numbering through the move (the picker maps a tap to that
    /// index before the transform is applied).
    func testAMovedBodyKeepsItsFaceNumbering() throws {
        let local = try box(10, 20, 30)
        var moved = local
        moved.transform.translation = SIMD3(5, -7, 11)
        moved.transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let before = OCCTKernel.faceInfo(try XCTUnwrap(local.brep))
        let after = OCCTKernel.faceInfo(try XCTUnwrap(MeasureItem.worldBRep(of: moved)))
        XCTAssertEqual(before.count, after.count)
        for (b, a) in zip(before, after) {
            XCTAssertEqual(b.index, a.index)
            XCTAssertEqual(b.area, a.area, accuracy: 1e-9)
            let expected = moved.transform.applying(to: b.centroid)
            XCTAssertLessThan(simd_length(expected - a.centroid), 1e-9, "face \(b.index)")
        }
    }

    func testTheMeshFallbackMatchesTheKernelOnFlatFaces() throws {
        let a = try box(10, 10, 10)
        let b = try box(4, 4, 4, at: SIMD3(20, 3, 3))
        let kernel = MeasureQuery.rows(for: [MeasureItem.body(a), MeasureItem.body(b)], deltas: false)
        MeasureQuery.exact = { _, _ in nil }
        let mesh = MeasureQuery.rows(for: [MeasureItem.body(a), MeasureItem.body(b)], deltas: false)
        XCTAssertEqual(row(.minDistance, in: kernel)?.value ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(row(.minDistance, in: mesh)?.value ?? 0, 10, accuracy: 1e-4)
    }

    func testSegmentAndTriangleClosestPoints() {
        let span = MeasureQuery.segmentSegmentSpan(SIMD3(0, 0, 0), SIMD3(10, 0, 0),
                                                   SIMD3(5, -5, 3), SIMD3(5, 5, 3))
        XCTAssertEqual(span.distance, 3, accuracy: 1e-12)
        XCTAssertEqual(span.a, SIMD3(5, 0, 0))
        let through = MeasureQuery.segmentTriangleSpan(SIMD3(0.2, 0.2, -1), SIMD3(0.2, 0.2, 1),
                                                       .zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        XCTAssertEqual(through.distance, 0, accuracy: 1e-12)
        let q = MeasureQuery.closestOnTriangle(SIMD3(2, 2, 5), .zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        XCTAssertLessThan(simd_length(q - SIMD3(0.5, 0.5, 0)), 1e-12)
    }
}
