//
//  TapSequencerTests.swift
//  openshape3dTests
//
//  Quick taps in different places are all delivered; two quick taps in one
//  place are a double-tap.
//

import XCTest
@testable import openshape3d

final class TapSequencerTests: XCTestCase {

    private func tap(_ x: CGFloat, _ y: CGFloat, at time: TimeInterval) -> TapSequencer.Tap {
        TapSequencer.Tap(point: CGPoint(x: x, y: y), time: time, shift: false)
    }

    func testALoneTapIsSingleOnceTheWindowCloses() {
        var taps = TapSequencer()
        XCTAssertEqual(taps.tap(tap(100, 100, at: 0)), [])
        XCTAssertEqual(taps.flush(generation: taps.generation), [.single(tap(100, 100, at: 0))])
        XCTAssertNil(taps.pending)
    }

    func testTwoQuickTapsInOnePlaceAreADoubleTapOnly() {
        var taps = TapSequencer()
        _ = taps.tap(tap(100, 100, at: 0))
        let generation = taps.generation
        XCTAssertEqual(taps.tap(tap(110, 95, at: 0.2)), [.double(tap(100, 100, at: 0))])
        XCTAssertEqual(taps.flush(generation: generation), [], "No single tap after the double")
    }

    /// The sketch-point case that used to lose taps: 0.2 s apart, far apart.
    func testQuickTapsInDifferentPlacesAreAllDelivered() {
        var taps = TapSequencer()
        let corners = [tap(311, 472, at: 0), tap(508, 472, at: 0.2), tap(508, 708, at: 0.4), tap(311, 708, at: 0.6)]
        var delivered: [TapSequencer.Event] = []
        for corner in corners {
            delivered += taps.tap(corner)
        }
        delivered += taps.flush(generation: taps.generation)
        XCTAssertEqual(delivered, corners.map { .single($0) })
    }

    func testASlowSecondTapIsTwoSingles() {
        var taps = TapSequencer()
        _ = taps.tap(tap(100, 100, at: 0))
        let stale = taps.generation
        XCTAssertEqual(taps.tap(tap(100, 100, at: 0.5)), [.single(tap(100, 100, at: 0))])
        XCTAssertEqual(taps.flush(generation: stale), [], "The first timer is stale")
        XCTAssertEqual(taps.flush(generation: taps.generation), [.single(tap(100, 100, at: 0.5))])
    }
}
