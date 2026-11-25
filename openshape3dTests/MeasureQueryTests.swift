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

    /// Each reading names the items it is about, so highlighting it can
    /// light them up: a mixed pick's length row is the edges' alone.
    func testRowsNameTheItemsTheyAreAbout() throws {
        let part = try box(10, 20, 30)
        let top = try face(part, normal: SIMD3(0, 0, 1))
        let line = MeasureItem.sketchEntity(.line(id: UUID(), a: .zero, b: SIMD2(3, 4)),
                                            sketchID: SketchID(), plane: .ground)
        let edge = MeasureItem.sketchEntity(.line(id: UUID(), a: .zero, b: SIMD2(0, 2)),
                                            sketchID: SketchID(), plane: .ground)
        let rows = MeasureQuery.rows(for: [top, line, edge], deltas: false)
        XCTAssertEqual(row(.length, in: rows)?.refs, [line.ref, edge.ref])
        XCTAssertEqual(row(.area, in: rows)?.refs, [top.ref])
        let pair = MeasureQuery.rows(for: [top, line], deltas: false)
        XCTAssertTrue(pair.allSatisfy { $0.refs == [top.ref, line.ref] })
    }

    func testAFaceAndAnEdgeKnowAPointOnThemselves() throws {
        let pipe = try tube(outer: 10, inner: 6, height: 20)
        // The annular cap's centroid is in the hole; its anchor is on it.
        let cap = try face(pipe, normal: SIMD3(0, 1, 0))
        let anchor = try XCTUnwrap(cap.anchor)
        let r = simd_length(SIMD2(anchor.x, anchor.z))
        XCTAssertGreaterThanOrEqual(r, 6 - 1e-6)
        XCTAssertLessThanOrEqual(r, 10 + 1e-6)
        XCTAssertEqual(anchor.y, 20, accuracy: 1e-9)
    }

    // MARK: Pairs

    private func circle(_ center: SIMD2<Double>, _ radius: Double, segments: Int = 96) -> Profile {
        let loop = (0..<segments).map { i -> SIMD2<Double> in
            let a = Double(i) / Double(segments) * 2 * .pi
            return center + SIMD2(cos(a), sin(a)) * radius
        }
        return Profile(loop: loop, kind: .circle(center: center, radius: radius), sourceEntityIDs: [UUID()])
    }

    /// A ring's centre of gravity is on its axis, half way up — the central
    /// distance to a face beside it starts there, not in the wall
    /// (reported: a hollow cylinder's central distance started in its wall).
    func testAHollowCylindersCentreOfGravityIsOnItsAxis() throws {
        let solid = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: circle(SIMD2(20, 0), 4.5), holes: [circle(SIMD2(20, 0), 2.5)], extras: [],
            zMin: 0, zMax: 6, origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1)))
        let ring = try body(solid)
        guard case .solid(let volume, let centroid) = MeasureItem.body(ring).geometry else { return XCTFail("a solid") }
        XCTAssertEqual(volume, .pi * (4.5 * 4.5 - 2.5 * 2.5) * 6, accuracy: 1e-6)
        XCTAssertLessThan(simd_length(centroid - SIMD3(20, 0, 3)), 1e-6, "centre of gravity \(centroid)")
    }

    /// A mesh-only body's centre of gravity comes from its volume (signed
    /// tetrahedra), not from its surface.
    func testAMeshBodysCentreOfGravityIsItsVolumes() {
        // Two unit cubes side by side along x, as triangles: a 2×1×1 bar
        // whose centre is (1, 0.5, 0.5).
        func cube(_ o: SIMD3<Double>) -> [SIMD3<Double>] {
            let p = (0..<8).map { i in o + SIMD3(Double(i & 1), Double((i >> 1) & 1), Double((i >> 2) & 1)) }
            let faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
            return faces.flatMap { f in [p[f[0]], p[f[1]], p[f[2]], p[f[0]], p[f[2]], p[f[3]]] }
        }
        let bar = cube(.zero) + cube(SIMD3(1, 0, 0))
        let centre = MeasureItem.meshVolumeCentroid(bar)
        XCTAssertLessThan(simd_length((centre ?? .zero) - SIMD3(1, 0.5, 0.5)), 1e-9, "\(String(describing: centre))")
    }

    /// The picked face with its render triangles, as the viewport builds it:
    /// every triangle whose corners lie on the plane `n·p = d`.
    private func faceWithTriangles(_ body: Body, normal: SIMD3<Double>, offset: Double) throws -> MeasureItem {
        let mesh = body.render
        let triangles = (0..<mesh.triangleCount).filter { t in
            (0..<3).allSatisfy { k in
                abs(simd_dot(SIMD3<Double>(mesh.positions[Int(mesh.indices[t * 3 + k])]), normal) - offset) < 1e-4
            }
        }
        XCTAssertFalse(triangles.isEmpty)
        return MeasureItem.face(of: body, kernelIndex: try faceIndex(body, normal: normal), triangles: triangles)
    }

    /// Two parallel faces: every straight-across span is shortest, and the
    /// one drawn goes through the middle of their overlap — not a far corner,
    /// where it looked like the widest gap.
    func testTheGapBetweenParallelFacesIsDrawnThroughTheirMiddle() throws {
        let lower = try box(10, 20, 30)
        let upper = try box(10, 20, 30, at: SIMD3(0, 0, 50))
        let rows = MeasureQuery.rows(for: [try faceWithTriangles(lower, normal: SIMD3(0, 0, 1), offset: 30),
                                           try faceWithTriangles(upper, normal: SIMD3(0, 0, -1), offset: -50)],
                                     deltas: false)
        let gap = try XCTUnwrap(row(.minDistance, in: rows))
        XCTAssertEqual(gap.value, 20, accuracy: 1e-6)
        XCTAssertEqual(gap.points.count, 2)
        XCTAssertLessThan(simd_length(gap.points[0] - SIMD3(5, 10, 30)), 1e-3, "\(gap.points)")
        XCTAssertLessThan(simd_length(gap.points[1] - SIMD3(5, 10, 50)), 1e-3, "\(gap.points)")
    }

    /// Two plates: the outer faces pinned, then the inner faces. The inner
    /// span is the same direction and inside the outer one, so it moves
    /// sideways to a spot where the faces still face each other (reported:
    /// the second pin covered the first). Same values.
    func testASecondSpanBetweenTheSameWallsMovesAside() throws {
        let left = try box(20, 20, 3)
        let right = try box(20, 20, 3, at: SIMD3(0, 0, 30))
        let outer = try XCTUnwrap(row(.parallelDistance, in: MeasureQuery.rows(
            for: [try faceWithTriangles(left, normal: SIMD3(0, 0, -1), offset: 0),
                  try faceWithTriangles(right, normal: SIMD3(0, 0, 1), offset: 33)], deltas: false)))
        XCTAssertEqual(outer.value, 33, accuracy: 1e-6)

        let innerItems = [try faceWithTriangles(left, normal: SIMD3(0, 0, 1), offset: 3),
                          try faceWithTriangles(right, normal: SIMD3(0, 0, -1), offset: -30)]
        let alone = try XCTUnwrap(row(.parallelDistance, in: MeasureQuery.rows(for: innerItems, deltas: false)))
        let span = MeasureQuery.Span(distance: alone.value, a: alone.points[0], b: alone.points[1])
        XCTAssertTrue(MeasureQuery.conflicts(span, with: [outer.points]), "centred, the two lie on one line")

        let inner = try XCTUnwrap(row(.parallelDistance, in: MeasureQuery.rows(
            for: innerItems, deltas: false, avoiding: [outer.points])))
        XCTAssertEqual(inner.value, 27, accuracy: 1e-6)
        let moved = MeasureQuery.Span(distance: inner.value, a: inner.points[0], b: inner.points[1])
        XCTAssertFalse(MeasureQuery.conflicts(moved, with: [outer.points]), "\(inner.points)")
        XCTAssertEqual(inner.points[0].z, 3, accuracy: 1e-6, "still from the inner face")
        XCTAssertEqual(inner.points[1].z, 30, accuracy: 1e-6, "to the other inner face")
        XCTAssertEqual(row(.minDistance, in: MeasureQuery.rows(for: innerItems, deltas: false,
                                                              avoiding: [outer.points]))?.points ?? [], inner.points,
                       "the minimum and parallel readings draw one line")
    }

    func testTheGapBetweenParallelEdgesIsDrawnWhereTheyOverlap() {
        let a = MeasureItem.sketchEntity(.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(10, 0)),
                                         sketchID: SketchID(), plane: .ground)
        let b = MeasureItem.sketchEntity(.line(id: UUID(), a: SIMD2(4, 5), b: SIMD2(20, 5)),
                                         sketchID: SketchID(), plane: .ground)
        let gap = row(.minDistance, in: MeasureQuery.rows(for: [a, b], deltas: false))
        XCTAssertEqual(gap?.value ?? 0, 5, accuracy: 1e-9)
        // Overlap is x 4…10 along the first line; the span sits at x = 7.
        XCTAssertEqual(gap?.points.first?.x ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(gap?.points.last?.x ?? 0, 7, accuracy: 1e-9)
    }

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
