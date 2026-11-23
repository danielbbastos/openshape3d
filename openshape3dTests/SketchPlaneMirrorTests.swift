//
//  SketchPlaneMirrorTests.swift
//  openshape3dTests
//
//  Mirror ▸ sketch shapes across a 3D plane from the model view: a plane at
//  right angles keeps the copy in the same sketch; any other plane puts it
//  on a new sketch at the reflected plane. Pure values.
//

import XCTest
import simd
@testable import openshape3d

final class SketchPlaneMirrorTests: XCTestCase {

    private func assertClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(simd_distance(a, b), 0, accuracy: 1e-9, "\(a) vs \(b)", file: file, line: line)
    }

    private let triangle: [SketchEntity] = [
        .line(id: UUID(), a: SIMD2(5, 0), b: SIMD2(15, 0)),
        .line(id: UUID(), a: SIMD2(15, 0), b: SIMD2(10, 8)),
        .line(id: UUID(), a: SIMD2(10, 8), b: SIMD2(5, 0)),
    ]

    /// XY sketch mirrored across the YZ plane (x = 0): perpendicular, so the
    /// copy lands in the same sketch with x negated.
    func testPerpendicularPlaneKeepsTheCopyInTheSameSketch() {
        let result = SketchPlaneMirror.mirror(triangle, on: .worldXY,
                                              acrossOrigin: .zero, normal: SIMD3(1, 0, 0))
        guard case .sameSketch(let copies) = result else { return XCTFail("expected the same sketch") }
        XCTAssertEqual(copies.count, 3)
        guard case let .line(_, a, b) = copies[0] else { return XCTFail("expected a line") }
        XCTAssertEqual(a.x, -5, accuracy: 1e-9); XCTAssertEqual(a.y, 0, accuracy: 1e-9)
        XCTAssertEqual(b.x, -15, accuracy: 1e-9); XCTAssertEqual(b.y, 0, accuracy: 1e-9)
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: triangle.map(\.id)), "fresh ids")
    }

    /// An offset mirror plane at right angles: x = 20 sends x → 40 − x.
    func testOffsetPerpendicularPlaneMirrorsAcrossTheMeetingLine() {
        let result = SketchPlaneMirror.mirror(triangle, on: .worldXY,
                                              acrossOrigin: SIMD3(20, 0, 0), normal: SIMD3(-1, 0, 0))
        guard case .sameSketch(let copies) = result,
              case let .line(_, a, _) = copies[0] else { return XCTFail("expected the same sketch") }
        XCTAssertEqual(a.x, 35, accuracy: 1e-9)
        XCTAssertEqual(a.y, 0, accuracy: 1e-9)
    }

    /// A ground sketch mirrored across the plane y = 5 (parallel): a new
    /// sketch at y = 10 whose points are the world reflections.
    func testParallelPlaneMakesANewSketchAtTheReflectedPlane() {
        let result = SketchPlaneMirror.mirror(triangle, on: .ground,
                                              acrossOrigin: SIMD3(0, 5, 0), normal: SIMD3(0, 1, 0))
        guard case let .newSketch(plane, copies) = result else { return XCTFail("expected a new sketch") }
        XCTAssertEqual(plane.origin.y, 10, accuracy: 1e-9)
        for (source, copy) in zip(triangle, copies) {
            guard case let .line(_, sa, sb) = source, case let .line(_, ca, cb) = copy else {
                return XCTFail("expected lines")
            }
            let reflected = { (p: SIMD2<Double>) in
                SketchPlaneMirror.reflect(SketchPlane.ground.toWorld(p), origin: SIMD3(0, 5, 0), normal: SIMD3(0, 1, 0))
            }
            assertClose(plane.toWorld(ca), reflected(sa))
            assertClose(plane.toWorld(cb), reflected(sb))
        }
    }

    /// An oblique plane: every copied point is the 3D reflection of its source.
    func testObliquePlaneReflectsEveryPointIn3D() {
        let origin = SIMD3<Double>(3, 1, -2)
        let normal = simd_normalize(SIMD3<Double>(1, 1, 0.5))
        let result = SketchPlaneMirror.mirror(triangle, on: .worldXY, acrossOrigin: origin, normal: normal)
        guard case let .newSketch(plane, copies) = result else { return XCTFail("expected a new sketch") }
        for (source, copy) in zip(triangle, copies) {
            guard case let .line(_, sa, _) = source, case let .line(_, ca, _) = copy else {
                return XCTFail("expected lines")
            }
            assertClose(plane.toWorld(ca),
                        SketchPlaneMirror.reflect(SketchPlane.worldXY.toWorld(sa), origin: origin, normal: normal))
        }
    }

    /// A rectangle across a slanted meeting line becomes its four sides.
    func testRectangleAcrossASlantedMeetingLineBecomesFourSides() {
        let rect: [SketchEntity] = [.rect(id: UUID(), min: SIMD2(1, 3), max: SIMD2(4, 5))]
        // Vertical plane through the origin whose trace in XY has slope 1.
        let normal = simd_normalize(SIMD3<Double>(1, -1, 0))
        let result = SketchPlaneMirror.mirror(rect, on: .worldXY, acrossOrigin: .zero, normal: normal)
        guard case .sameSketch(let copies) = result else { return XCTFail("expected the same sketch") }
        XCTAssertEqual(copies.count, 4)
        guard case let .line(_, a, _) = copies[0] else { return XCTFail("expected lines") }
        // Across y = x the corner (1, 3) goes to (3, 1).
        XCTAssertEqual(a.x, 3, accuracy: 1e-9)
        XCTAssertEqual(a.y, 1, accuracy: 1e-9)
    }
}
