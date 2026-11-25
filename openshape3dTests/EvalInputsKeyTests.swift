//
//  EvalInputsKeyTests.swift
//  openshape3dTests
//
//  `FeatureGraph.evalInputsKey` decides whether undo/redo may skip the
//  error-badge replay. It must stay put for changes no feature reads (a line
//  in an unused sketch, a sketch's name) and move for anything a replay
//  reads (a feature, its sketch, the rollback marker).
//

import XCTest
import Euclid
import simd
@testable import openshape3d

final class EvalInputsKeyTests: XCTestCase {

    private let used = SketchID(), unused = SketchID()
    private let rect = UUID(), node = FeatureID(), body = BodyID()

    private func sketches(usedSize: Double = 10, unusedLines: Int = 0, usedName: String = "A") -> [Sketch] {
        var lines: [SketchEntity] = []
        for i in 0..<unusedLines {
            lines.append(.line(id: UUID(), a: SIMD2(0, Double(i)), b: SIMD2(5, Double(i))))
        }
        return [
            Sketch(id: used, name: usedName, plane: .ground, entities: [
                .rect(id: rect, min: SIMD2(0, 0), max: SIMD2(usedSize, usedSize))]),
            Sketch(id: unused, name: "On a face", plane: .ground, entities: lines),
        ]
    }

    private func graph(distance: Double = 10) -> FeatureGraph {
        FeatureGraph(nodes: [FeatureNode(id: node, name: "E", kind: .extrude(
            profile: ProfileRef(sketchID: used, entityIDs: [rect], holeEntityIDs: [], seedPoint: SIMD2(2, 2)),
            plane: PlaneRef(source: .sketch(used)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])])
    }

    private func key(_ g: FeatureGraph, _ s: [Sketch]) -> UInt64? {
        g.evalInputsKey(sketches: s, planes: [])
    }

    func testALineInASketchNoFeatureReadsKeepsTheKey() {
        let before = key(graph(), sketches())
        XCTAssertNotNil(before)
        XCTAssertEqual(before, key(graph(), sketches(unusedLines: 1)), "drawing the line")
        XCTAssertEqual(before, key(graph(), sketches(unusedLines: 0)), "undoing it")
    }

    func testRenamingAUsedSketchKeepsTheKey() {
        XCTAssertEqual(key(graph(), sketches()), key(graph(), sketches(usedName: "Renamed")))
    }

    func testWhatAReplayReadsMovesTheKey() {
        let base = key(graph(), sketches())
        XCTAssertNotEqual(base, key(graph(), sketches(usedSize: 12)), "the feature's own sketch")
        XCTAssertNotEqual(base, key(graph(distance: 11), sketches()), "the feature's parameters")

        var rolledBack = graph()
        rolledBack.rollbackIndex = 0
        XCTAssertNotEqual(base, key(rolledBack, sketches()), "the rollback marker")

        var suppressed = graph()
        suppressed.nodes[0].suppressed = true
        XCTAssertNotEqual(base, key(suppressed, sketches()), "suppression")

        XCTAssertNotEqual(base, key(FeatureGraph(nodes: []), sketches()), "a deleted feature")
    }

    // MARK: The open-time memo is adopted only when it describes the document

    func testAReplayMatchingTheStoredBodiesMayStandIn() {
        let stored = Body(name: "Box", euclidMesh: .cube(size: 2), revision: 7)
        var replayed = stored
        replayed.meshRevision = DocumentSession.scratchRevisionBase + 1
        XCTAssertTrue(DocumentSession.replayMatchesDocument([replayed], [stored]))
    }

    func testAReplayThatDiffersFromTheStoredBodiesIsNotAdopted() {
        let stored = Body(name: "Box", euclidMesh: .cube(size: 2), revision: 7)
        let bigger = Body(id: stored.id, name: "Box", euclidMesh: .cube(size: 3), revision: 8)
        XCTAssertFalse(DocumentSession.replayMatchesDocument([bigger], [stored]), "other bounds")

        let other = Body(name: "Other", euclidMesh: .cube(size: 2), revision: 9)
        XCTAssertFalse(DocumentSession.replayMatchesDocument([other], [stored]), "a body the document lacks")
    }

    func testScratchRevisionsStayClearOfTheDocument() {
        XCTAssertGreaterThan(DocumentSession.scratchRevisionBase, UInt64(1) << 40)
    }
}
