//
//  BlendDragKindTests.swift
//  openshape3dTests
//
//  An edge picked straight off the body takes a SIGNED size from its
//  arrow: toward the body (the arrow's direction, positive) a chamfer, away
//  a fillet, and crossing zero switches between them.
//

import XCTest
@testable import openshape3d

final class BlendDragKindTests: XCTestCase {

    func testTowardTheBodyIsAChamfer() {
        let r = EditorViewModel.blendSignedSize(2.5)
        XCTAssertEqual(r.kind, .chamfer); XCTAssertEqual(r.value, 2.5)
    }

    func testAwayFromTheBodyIsAFillet() {
        let r = EditorViewModel.blendSignedSize(-3.8)
        XCTAssertEqual(r.kind, .fillet); XCTAssertEqual(r.value, 3.8)
    }

    func testZeroKeepsWhatIsShowing() {
        let r = EditorViewModel.blendSignedSize(0)
        XCTAssertNil(r.kind); XCTAssertEqual(r.value, 0)
    }

    /// A fillet of 1 mm dragged 3 mm toward the body ends a 2 mm chamfer.
    func testOneDragCrossesFromFilletToChamfer() {
        let start = -1.0
        let r = EditorViewModel.blendSignedSize(start + 3)
        XCTAssertEqual(r.kind, .chamfer); XCTAssertEqual(r.value, 2, accuracy: 1e-12)
    }
}
