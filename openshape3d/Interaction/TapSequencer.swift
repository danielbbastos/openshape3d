//
//  TapSequencer.swift
//  openshape3d
//
//  Tells single taps from double-taps without losing any. A single-tap
//  recognizer that requires a double-tap recognizer to fail drops a tap that
//  lands while it is still waiting for that failure: quick taps in different
//  places (sketch points 0.4 s apart) went missing. Here every tap is
//  recognized at once and this decides what it was. Pure value; the gesture
//  controller owns the timer.
//

import CoreGraphics
import Foundation

nonisolated struct TapSequencer {

    struct Tap: Equatable {
        var point: CGPoint
        var time: TimeInterval
        var byFinger: Bool
        var shift: Bool
        /// An Apple Pencil, not a finger or a pointer.
        var byPencil: Bool = false
    }

    enum Event: Equatable {
        case single(Tap)
        /// At the first tap's point.
        case double(Tap)
    }

    /// Longest gap between two taps that still makes a double-tap.
    var interval: TimeInterval = 0.35
    /// Farthest apart, in points, two taps of a double-tap may land.
    var slop: CGFloat = 44

    private(set) var pending: Tap?
    /// Bumped with each new pending tap, so a stale timer flushes nothing.
    private(set) var generation = 0

    /// A tap was recognized. Returns what to deliver now; when `pending` is
    /// set afterwards, call `flush(generation:)` after `interval`.
    mutating func tap(_ tap: Tap) -> [Event] {
        if let first = pending {
            if tap.time - first.time <= interval,
               hypot(tap.point.x - first.point.x, tap.point.y - first.point.y) <= slop {
                pending = nil
                var both = first
                both.byFinger = first.byFinger && tap.byFinger
                both.byPencil = first.byPencil && tap.byPencil
                return [.double(both)]
            }
            pending = tap
            generation += 1
            return [.single(first)]
        }
        pending = tap
        generation += 1
        return []
    }

    /// The double-tap window closed: the pending tap was a single tap.
    mutating func flush(generation: Int) -> [Event] {
        guard generation == self.generation, let first = pending else { return [] }
        pending = nil
        return [.single(first)]
    }
}
