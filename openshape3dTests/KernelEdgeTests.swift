//
//  KernelEdgeTests.swift
//  openshape3dTests
//
//  A body tessellated from a B-rep draws and picks the kernel's own edges
//  (`RenderMesh.kernelEdgeSegments`), not the mesh's creases: a fillet's
//  tangent edges are edges, a cylinder's seam and the bends inside one
//  curved face are not. Pure values: OCCT shapes and `Body`, no session.
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class KernelEdgeTests: XCTestCase {

    private func body(_ handle: BRepHandle) throws -> Body {
        var body = Body(name: "B", euclidMesh: .cube(size: 1), revision: 1)
        XCTAssertTrue(body.adoptBRep(handle))
        return body
    }

    private func box() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 10), placement: .identity))
    }

    /// Whether `edge` runs along the two faces smoothly (no crease).
    private func isTangent(_ edge: SelectableEdge) -> Bool {
        simd_dot(edge.normalA, edge.normalB) > 0.99
    }

    func testABoxKeepsItsTwelveEdges() throws {
        let b = try body(box())
        XCTAssertNotNil(b.render.kernelEdgeSegments)
        let edges = EdgeTopology.selectableEdges(from: b.render)
        XCTAssertEqual(edges.count, 12)
        XCTAssertFalse(edges.contains(where: isTangent))
        XCTAssertEqual(b.edges.segmentCount, 12)
    }

    func testAFilletsTangentEdgesAreDrawnAndPickable() throws {
        let brep = try box()
        var filleted: BRepHandle?
        for edge in 1...12 {
            if case let .success((handle, _)) = OCCTKernel.filletResultWithAncestry(brep, edgeIndices: [edge], radius: 3) {
                filleted = handle; break
            }
        }
        let b = try body(XCTUnwrap(filleted))
        let edges = EdgeTopology.selectableEdges(from: b.render)
        // The two straight lines where the round meets the flat faces.
        let tangent = edges.filter { isTangent($0) && $0.length > 1 }
        XCTAssertEqual(tangent.count, 2, "both tangent edges of the fillet")

        // The crease test alone finds neither.
        var creases = b.render
        creases.kernelEdgeSegments = nil
        XCTAssertFalse(EdgeTopology.selectableEdges(from: creases).contains { isTangent($0) && $0.length > 1 })
    }

    func testACylinderDrawsOnlyItsRims() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(.cylinder(radius: 5, height: 8), placement: .identity))
        let b = try body(cyl)
        let segments = try XCTUnwrap(b.render.kernelEdgeSegments)
        XCTAssertFalse(segments.isEmpty)
        let ys = Set(segments.map { ($0.y * 1000).rounded() })
        XCTAssertEqual(ys.count, 2, "every line lies on a rim: no seam down the side")
        var i = 0
        while i < segments.count {
            XCTAssertEqual(segments[i].y, segments[i + 1].y, accuracy: 1e-4, "no segment climbs the wall")
            i += 2
        }
    }

    func testSegmentsOffTheMeshAreRefused() throws {
        let b = try body(box())
        let segments = try XCTUnwrap(b.render.kernelEdgeSegments)
        XCTAssertNotNil(RenderMesh.matchingKernelEdges(segments, on: b.render))
        let moved = segments.map { $0 + SIMD3<Float>(0.5, 0, 0) }
        XCTAssertNil(RenderMesh.matchingKernelEdges(moved, on: b.render))
        XCTAssertNil(RenderMesh.matchingKernelEdges([], on: b.render))
    }

    func testNewPositionsDropTheKernelEdges() throws {
        var render = try body(box()).render
        XCTAssertNotNil(render.kernelEdgeSegments)
        render.positions = render.positions.map { $0 * 2 }
        XCTAssertNil(render.kernelEdgeSegments, "edges read off the old positions")
    }

    /// A reopened body: a mesh-free copy tessellated the same way gives the
    /// edges of the stored mesh.
    func testAReloadedBRepFindsTheSameEdges() throws {
        let brep = try box()
        let b = try body(brep)
        let reloaded = try XCTUnwrap(OCCTKernel.deserialize(XCTUnwrap(OCCTKernel.serialize(brep))))
        let segments = OCCTKernel.kernelEdgeSegments(from: reloaded, remesh: true)
        XCTAssertNotNil(RenderMesh.matchingKernelEdges(segments, on: b.render))
    }
}
