//
//  SubtractCrashTests.swift
//  openshape3dTests
//
//  Crash report 2026-11-22: a symmetric Extrude subtract died in Euclid's
//  `makeWatertight()` capping a sliver hole with a zero-area triangle.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SubtractCrashTests: XCTestCase {

    /// A stored (Float) 16-gon cylinder cut by a symmetric tool on the same
    /// walls: the smallest input found that hit the assertion.
    func testSymmetricCutOnCoincidentWallsDoesNotCrash() {
        let body = EuclidBridge.euclidMesh(from: EuclidBridge.renderMesh(
            from: Euclid.Mesh.cylinder(radius: 5, height: 12, slices: 16)))
        let tool = Euclid.Mesh.extrude(Euclid.Path.circle(radius: 5, segments: 16), depth: 4.002)
        let cut = body.subtracting(tool).makeWatertight()
        XCTAssertFalse(cut.polygons.isEmpty)
    }
}

extension SubtractCrashTests {

    private func box(hidden: Bool = false, at x: Double = 0) throws -> openshape3d.Body {
        let loop = [SIMD2<Double>(-5, -5), SIMD2(5, -5), SIMD2(5, 5), SIMD2(-5, 5)]
        let handle = try XCTUnwrap(OCCTKernel.extrudeSolid(
            outer: Profile(loop: loop, kind: .polygonal, sourceEntityIDs: []), holes: [], extras: [],
            zMin: 0, zMax: 10,
            origin: .zero, xAxis: SketchPlane.ground.xAxis,
            yAxis: SketchPlane.ground.yAxis, normal: SketchPlane.ground.normal))
        var transform = Transform3D.identity
        transform.translation = SIMD3(x, 0, 0)
        var body = openshape3d.Body(
            id: BodyID(), name: "Box", transform: transform, primitive: nil,
            euclidMesh: Euclid.Mesh([]), revision: 0)
        XCTAssertTrue(body.adoptBRep(handle))
        body.isHidden = hidden
        return body
    }

    private func square(_ half: Double) -> Profile {
        Profile(loop: [SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half)],
                kind: .polygonal, sourceEntityIDs: [])
    }

    func testHiddenBodiesAreNeverToolTargets() throws {
        let shown = try box(), hidden = try box(hidden: true)
        XCTAssertEqual(BooleanCandidacy.toolTargets(in: [shown, hidden]).map(\.id), [shown.id])
    }

    /// Symmetric 3 mm a side about y = 5: a 4 × 4 × 6 pocket through the
    /// middle. The body stays a solid and keeps its pivot.
    func testSymmetricCutOfAMovedSolidStaysASolid() throws {
        let body = try box(at: 20)
        let plane = SketchPlane(origin: SIMD3(20, 5, 0),
                                xAxis: SketchPlane.ground.xAxis, yAxis: SketchPlane.ground.yAxis)
        guard case .cut(let cut) = ExtrudeCutKit.cut(
            body, outer: square(2), holes: [], extras: [],
            plane: plane, distance: 3, symmetric: true)
        else { return XCTFail("expected an exact cut") }
        XCTAssertNotNil(cut.brep)
        XCTAssertEqual(cut.transform.translation.x, 20, accuracy: 1e-9)
        XCTAssertEqual(MeasureKit.bodyVolume(cut.render, scale: 1), 1000 - 4 * 4 * 6, accuracy: 0.01)
        let bounds = cut.render.localAABB
        XCTAssertEqual(bounds.min.x, -5, accuracy: 1e-4)
        XCTAssertEqual(bounds.max.x, 5, accuracy: 1e-4)
    }

    func testACutThatRemovesEverythingIsNotCommitted() throws {
        let plane = SketchPlane(origin: SIMD3(0, 5, 0),
                                xAxis: SketchPlane.ground.xAxis, yAxis: SketchPlane.ground.yAxis)
        guard case .failed = ExtrudeCutKit.cut(
            try box(), outer: square(8), holes: [], extras: [],
            plane: plane, distance: 8, symmetric: true)
        else { return XCTFail("expected a refusal") }
    }

    func testAMeshBodyIsLeftToTheMeshPath() {
        let body = openshape3d.Body(
            id: BodyID(), name: "Mesh", transform: .identity, primitive: nil,
            euclidMesh: .cube(size: Vector(10, 10, 10)), revision: 0)
        guard case .declined = ExtrudeCutKit.cut(
            body, outer: square(2), holes: [], extras: [],
            plane: .ground, distance: 3, symmetric: true)
        else { return XCTFail("a mesh has no exact cut") }
    }

    func testAMissingFaceIsAnOpeningAndAClosedBoxIsNot() {
        let closed = Euclid.Mesh.cube(size: Vector(10, 10, 10))
        let open = Euclid.Mesh(Array(closed.polygons.dropFirst()))
        XCTAssertEqual(MeshSeamKit.openingWidth(of: closed), 0)
        XCTAssertGreaterThan(MeshSeamKit.openingWidth(of: open), 1)
        XCTAssertTrue(MeshSeamKit.boolean(open, opened: closed))
        XCTAssertFalse(MeshSeamKit.boolean(open, opened: open), "an open import may stay open")
    }

    /// Cracks of 1e-7 mm are normal after a cut and must not be refused.
    func testAHairlineCrackIsNotAnOpening() {
        let closed = Euclid.Mesh.cube(size: Vector(10, 10, 10))
        var polygons = closed.polygons
        polygons[0] = polygons[0].translated(by: Vector(2e-7, 2e-7, 2e-7))
        XCTAssertFalse(MeshSeamKit.boolean(Euclid.Mesh(polygons), opened: closed))
    }
}
