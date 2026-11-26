//
//  FaceDeformBRepTests.swift
//  openshape3dTests
//
//  Move / Scale / Rotate Face on an analytic body stay analytic
//  (`OCCTKernel.faceDeformResult`). Until 2026-11 all three deformed the
//  Euclid mesh and handed back a mesh-only body, so a fillet, a STEP export
//  or `/v1/check` after any of them lost the exact geometry — the flaw the
//  push/pull had before `PushPullBRepTests`.
//

import XCTest
import simd
@testable import openshape3d

final class FaceDeformBRepTests: XCTestCase {

    private func body(_ spec: PrimitiveSpec) throws -> Body {
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))
        return try XCTUnwrap(STEPKit.body(from: brep, name: "b", revision: 1))
    }

    /// The planar face whose outward normal is `normal` and whose plane sits
    /// furthest along it.
    private func face(_ normal: SIMD3<Float>, of body: Body) throws -> PlanarFace {
        let mesh = body.render
        var best: (offset: Float, triangle: Int)?
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[3 * t])]
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            guard simd_dot(n, normal) > 0.999 else { continue }
            let offset = simd_dot(a, normal)
            if offset > (best?.offset ?? -.infinity) { best = (offset, t) }
        }
        let seed = try XCTUnwrap(best?.triangle, "no face facing \(normal)")
        return try XCTUnwrap(FaceTopology.planarFace(in: mesh, seedTriangle: seed))
    }

    private func deform(_ body: Body, _ normal: SIMD3<Float>,
                        _ deform: OCCTKernel.FaceDeform) throws -> Result<BRepHandle, OCCTOpError> {
        OCCTKernel.faceDeformResult(try XCTUnwrap(body.brep), face: try face(normal, of: body),
                                    deform: deform)
    }

    private func assertExact(_ handle: BRepHandle, planar: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid, file: file, line: line)
        let faces = OCCTKernel.faceTypeCounts(handle)
        XCTAssertEqual(faces.planar, planar, "same faces, new planes", file: file, line: line)
        XCTAssertEqual(faces.other, 0, file: file, line: line)
    }

    private let up = SIMD3<Float>(0, 1, 0)

    // MARK: Move

    func testALateralMoveShearsTheBoxAndKeepsItsVolume() throws {
        let box = try body(.box(width: 10, depth: 6, height: 8))
        let handle = try deform(box, up, .move(SIMD3(3, 0, 0))).get()
        assertExact(handle, planar: 6)
        XCTAssertEqual(OCCTKernel.volume(handle), 480, accuracy: 1e-6, "a shear keeps the volume")
    }

    func testAMoveAlongTheNormalIsAPull() throws {
        let box = try body(.box(width: 10, depth: 6, height: 8))
        let handle = try deform(box, up, .move(SIMD3(0, 2, 0))).get()
        assertExact(handle, planar: 6)
        XCTAssertEqual(OCCTKernel.volume(handle), 10 * 6 * 10, accuracy: 1e-6)
    }

    /// The same deform as the mesh path, so a body keeps its shape whether a
    /// node replays through OCCT or falls back.
    func testAnObliqueMoveMatchesTheMeshPath() throws {
        let box = try body(.box(width: 10, depth: 6, height: 8))
        let top = try face(up, of: box)
        let delta = SIMD3<Double>(2, 1, -1.5)
        let handle = try deform(box, up, .move(delta)).get()
        let mesh = KernelOps.moveFace(mesh: box.euclidMesh(), face: top, delta: delta)
        XCTAssertEqual(OCCTKernel.volume(handle),
                       MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1),
                       accuracy: 1e-6)
    }

    /// A wall the move slides along keeps its plane, so a hole through it
    /// keeps its round edge and the cylinder behind it stays a cylinder.
    func testAHoleInAWallTheMoveSlidesAlongStaysRound() throws {
        let box = try body(.box(width: 20, depth: 20, height: 20))
        let bounds = box.render.positions.reduce(
            (min: SIMD3<Float>(repeating: .infinity), max: SIMD3<Float>(repeating: -.infinity))
        ) { (min: simd_min($0.min, $1), max: simd_max($0.max, $1)) }
        let center = SIMD3<Double>((bounds.min + bounds.max) / 2)
        let lowCentre = SIMD3(center.x, Double(bounds.min.y) + 5, center.z)
        // A Ø6 hole through the two walls the move slides along: its axis is
        // the face's other in-plane direction.
        let axis = SIMD3<Double>(0, 0, 1)
        var placement = Transform3D.identity
        placement.rotation = simd_quatd(from: SIMD3(0, 1, 0), to: axis)
        placement.translation = lowCentre - axis * 50
        let drill = try XCTUnwrap(OCCTKernel.primitiveShape(.cylinder(radius: 3, height: 100),
                                                           placement: placement))
        let holed = try OCCTKernel.booleanResult(try XCTUnwrap(box.brep), drill, op: 1).get().handle
        let holedBody = try XCTUnwrap(STEPKit.body(from: holed, name: "h", revision: 2))
        let before = OCCTKernel.volume(holed)

        let handle = try deform(holedBody, up, .move(SIMD3(4, 0, 0))).get()
        XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid)
        XCTAssertEqual(OCCTKernel.volume(handle), before, accuracy: 1e-4)
        let faces = OCCTKernel.faceTypeCounts(handle)
        XCTAssertGreaterThanOrEqual(faces.cylindrical, 1, "the bore is still a cylinder")
        XCTAssertEqual(faces.other, 0)
    }

    // MARK: Scale

    func testScalingTheTopMakesAFrustum() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let handle = try deform(box, up, .scale(0.5)).get()
        assertExact(handle, planar: 6)
        // h/3 · (A1 + A2 + √(A1·A2)) = 10/3 · (100 + 25 + 50)
        XCTAssertEqual(OCCTKernel.volume(handle), 1750.0 / 3, accuracy: 1e-6)
    }

    /// A cylinder's wall would have to become a cone: refused, so the caller
    /// keeps the mesh deform.
    func testScalingACylinderCapIsLeftToTheMeshPath() throws {
        let cylinder = try body(.cylinder(radius: 5, height: 12))   // axis +Y
        guard case .failure = try deform(cylinder, up, .scale(0.6)) else {
            return XCTFail("a curved wall cannot follow a scaled cap without bending")
        }
    }

    // MARK: Rotate

    /// A tilt about an edge-parallel axis keeps every wall flat: a wedge.
    /// The face turns rigidly, so its edges swing on arcs about the centre
    /// line and the section is a trapezoid of area 50·(1 + cos θ).
    func testATiltKeepsTheWallsFlatAndMatchesTheMeshPath() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let top = try face(up, of: box)
        let angle = 12 * Double.pi / 180
        let handle = try deform(box, up, .rotate(angle: angle, axis: SIMD3(1, 0, 0))).get()
        assertExact(handle, planar: 6)
        XCTAssertEqual(OCCTKernel.volume(handle), 500 * (1 + cos(angle)), accuracy: 1e-6)
        let mesh = KernelOps.rotateFace(mesh: box.euclidMesh(), face: top,
                                        angle: angle, axis: SIMD3(1, 0, 0))
        XCTAssertEqual(OCCTKernel.volume(handle),
                       MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1),
                       accuracy: 1e-6)
    }

    /// A twist about the face normal makes ruled (screw) walls — not planar,
    /// so the mesh path keeps doing it.
    func testATwistIsLeftToTheMeshPath() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        guard case .failure = try deform(box, up, .rotate(angle: 0.4, axis: SIMD3(0, 1, 0))) else {
            return XCTFail("a twist bends the walls")
        }
    }

    /// A tilt about a diagonal axis twists the side walls out of plane.
    func testADiagonalTiltThatWarpsTheWallsIsRefused() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let diagonal = simd_normalize(SIMD3<Double>(1, 0, 1))
        guard case .failure = try deform(box, up, .rotate(angle: 0.3, axis: diagonal)) else {
            return XCTFail("the side walls would stop being flat")
        }
    }
}

/// The parametric path: a Move Face node on a primitive replays through OCCT,
/// so the body that comes out still has its B-rep.
final class FaceDeformEvalBRepTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    func testMoveScaleAndRotateNodesKeepTheBRep() throws {
        let boxFeature = FeatureID()
        let boxID = BodyID()
        let boxNode = FeatureNode(
            id: boxFeature, name: "Box",
            kind: .primitive(spec: .box(width: 10, depth: 10, height: 10), placement: .identity),
            outputBodyIDs: [boxID])
        let seed = FeatureGraph(nodes: [boxNode]).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let table = try XCTUnwrap(seed.faceTables[boxID])
        let entry = try XCTUnwrap(table.entries
            .filter { if case .planar = $0.signature.kind { return true } else { return false } }
            .max { $0.signature.normal.y < $1.signature.normal.y })
        let top = FaceRef(body: BodyRef(producer: boxFeature, bodyID: boxID),
                          creator: boxFeature, role: entry.role, signature: entry.signature)

        let kinds: [(String, FeatureKind, Double)] = [
            ("move", .moveFace(face: top, delta: PointWrapper(SIMD3(3, 0, 0))), 1000),
            ("scale", .scaleFace(face: top, factor: Expr(value: 0.5)), 1750.0 / 3),
            ("tilt", .rotateFace(face: top, angle: Expr(value: 0.2),
                                 axis: PointWrapper(SIMD3(1, 0, 0))), 500 * (1 + cos(0.2))),
        ]
        for (label, kind, expected) in kinds {
            let node = FeatureNode(id: FeatureID(), name: label, kind: kind, outputBodyIDs: [])
            let result = FeatureGraph(nodes: [boxNode, node]).evaluate(
                sketches: [], planes: [], naming: SignatureNaming(),
                nextRevision: RevisionSource().next)
            XCTAssertNil(result.errors[node.id], "\(label): \(result.errors)")
            let body = try XCTUnwrap(result.bodies.first { $0.id == boxID })
            let brep = try XCTUnwrap(body.brep, "\(label) must keep the B-rep")
            XCTAssertTrue(OCCTKernel.healthReport(for: brep).isValid, label)
            XCTAssertEqual(OCCTKernel.volume(brep), expected, accuracy: 1e-6, label)
        }
    }
}
