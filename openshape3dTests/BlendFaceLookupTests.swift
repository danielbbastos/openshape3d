//
//  BlendFaceLookupTests.swift
//  openshape3dTests
//
//  `FeatureGraph.blendFeature(forBody:facePoints:)`: a tap on a fillet's
//  round (or a chamfer's bevel) finds the feature that made it, so it can be
//  reopened; the flat faces beside it, other bodies, and suppressed or
//  rolled-back blends do not.
//

import XCTest
import simd
@testable import openshape3d

final class BlendFaceLookupTests: XCTestCase {

    private let body = BodyID(), other = BodyID()
    private let maker = FeatureID(), fillet = FeatureID()

    /// The top front edge of a 20×20×10 box centred on x and z: y = 10, z = 10.
    private var topFront: EdgeRef {
        EdgeRef(body: BodyRef(producer: maker, bodyID: body),
                signature: EdgeSignature(midpoint: SIMD3(0, 10, 10), direction: SIMD3(1, 0, 0), length: 20,
                                         normalA: SIMD3(0, 1, 0), normalB: SIMD3(0, 0, 1)))
    }

    private func graph(_ kind: (BodyRef, [EdgeRef]) -> FeatureKind, suppressed: Bool = false,
                       rollback: Int? = nil) -> FeatureGraph {
        var node = FeatureNode(id: fillet, name: "Blend", kind: kind(BodyRef(producer: maker, bodyID: body), [topFront]),
                               outputBodyIDs: [body])
        node.suppressed = suppressed
        return FeatureGraph(nodes: [node], rollbackIndex: rollback)
    }

    private func filletGraph(suppressed: Bool = false, rollback: Int? = nil) -> FeatureGraph {
        graph({ .fillet(body: $0, edges: $1, radius: Expr(value: 3)) }, suppressed: suppressed, rollback: rollback)
    }

    /// Points of the r 3 round that replaced the edge: centre (y 7, z 7).
    private var round: [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for x in stride(from: -10.0, through: 10.0, by: 5) {
            for step in 0...8 {
                let a = Double(step) / 8 * .pi / 2
                out.append(SIMD3(x, 7 + 3 * sin(a), 7 + 3 * cos(a)))
            }
        }
        return out
    }

    func testTheRoundFindsItsFillet() {
        XCTAssertEqual(filletGraph().blendFeature(forBody: body, facePoints: round), fillet)
    }

    func testTheFlatTopBesideItIsNotTheFillet() {
        let top: [SIMD3<Double>] = [SIMD3(-10, 10, -10), SIMD3(10, 10, -10), SIMD3(10, 10, 7), SIMD3(-10, 10, 7)]
        XCTAssertNil(filletGraph().blendFeature(forBody: body, facePoints: top))
    }

    func testAChamferBevelFindsItsChamfer() {
        let g = graph { .chamfer(body: $0, edges: $1, setback: Expr(value: 2)) }
        let bevel: [SIMD3<Double>] = [SIMD3(-10, 8, 10), SIMD3(10, 8, 10), SIMD3(10, 10, 8), SIMD3(-10, 10, 8)]
        XCTAssertEqual(g.blendFeature(forBody: body, facePoints: bevel), fillet)
    }

    func testOnlyAnActiveBlendOfThatBody() {
        XCTAssertNil(filletGraph().blendFeature(forBody: other, facePoints: round), "another body")
        XCTAssertNil(filletGraph(suppressed: true).blendFeature(forBody: body, facePoints: round), "suppressed")
        XCTAssertNil(filletGraph(rollback: 0).blendFeature(forBody: body, facePoints: round), "rolled back")
    }

    func testPointsPastTheEdgesEndsAreElsewhere() {
        let past = round.map { $0 + SIMD3(30, 0, 0) }
        XCTAssertNil(filletGraph().blendFeature(forBody: body, facePoints: past))
    }
}
