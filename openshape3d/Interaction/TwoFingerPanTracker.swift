//
//  TwoFingerPanTracker.swift
//  openshape3d
//
//  A two-finger pan reports the CENTROID of the fingers still down. Lifting
//  them one after the other (as everyone does) moves that centroid onto the
//  last finger, half the fingers' spread away, and applying that as camera
//  movement made the view jump on release ("snaps back a bit when I
//  release"). The same jump happens when a finger lands mid-pan. Movement
//  therefore counts only between two updates with the same two fingers
//  down; a change of finger count re-anchors without moving.
//

import CoreGraphics

nonisolated struct TwoFingerPanTracker {
    private var last: CGPoint?
    private var touches = 0

    mutating func begin(at point: CGPoint, touches count: Int) {
        last = point
        touches = count
    }

    /// How far to pan for this update, or nil when it must not move the
    /// camera (fewer than two fingers, or the finger count just changed).
    mutating func move(to point: CGPoint, touches count: Int) -> CGSize? {
        defer { last = point; touches = count }
        guard count >= 2, count == touches, let last else { return nil }
        return CGSize(width: point.x - last.x, height: point.y - last.y)
    }

    mutating func end() {
        last = nil
        touches = 0
    }
}
