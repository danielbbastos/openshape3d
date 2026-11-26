//
//  BlendDragCapTests.swift
//  openshape3dTests
//
//  The arrow stops at the largest chamfer the kernel can build, as it does
//  for fillets, instead of running into "too large for the local geometry".
//  `OCCTKernel.maxChamferDistance` must name a setback that builds, with a
//  slightly larger one refused.
//

import XCTest
import simd
@testable import openshape3d

final class BlendDragCapTests: XCTestCase {

    /// A 30 × 12 × 30 block (y up); the top front edge runs along x at y 12.
    private func block() throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 30, depth: 30, height: 12), placement: .identity))
    }

    private func topFrontEdgeMidpoint(_ brep: BRepHandle) throws -> SIMD3<Double> {
        let mids = OCCTKernel.edgeMidpoints(brep).values
        return try XCTUnwrap(mids.max { a, b in (a.y + a.z) < (b.y + b.z) })
    }

    func testTheChamferCapBuildsAndJustAboveItDoesNot() throws {
        let brep = try block()
        let mid = try topFrontEdgeMidpoint(brep)
        let tol = OCCTKernel.matchTolerance(for: brep)
        let cap = OCCTKernel.maxChamferDistance(brep, at: [mid], tolerance: tol)
        XCTAssertGreaterThan(cap, 1, "a 12 mm face takes a sizeable chamfer")
        XCTAssertLessThanOrEqual(cap, 12.001, "never past the face it eats into")
        if case .failure(let e) = OCCTKernel.chamferResult(brep, at: [mid], distance: cap, tolerance: tol) {
            XCTFail("the cap itself must build: \(e)")
        }
        if case .success = OCCTKernel.chamferResult(brep, at: [mid], distance: cap * 1.2 + 0.5, tolerance: tol) {
            XCTFail("well past the cap must not build")
        }
    }

    func testTheFilletCapStillWorks() throws {
        let brep = try block()
        let mid = try topFrontEdgeMidpoint(brep)
        let cap = OCCTKernel.maxFilletRadius(brep, at: [mid], tolerance: OCCTKernel.matchTolerance(for: brep))
        XCTAssertGreaterThan(cap, 1)
    }
}
