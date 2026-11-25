//
//  SketchPlaneNavigation.swift
//  openshape3d
//
//  The rules behind "Using sketch planes" (spec §2.3, §7.2): which plane a
//  standard view defines, and when a flat head-on view is in effect. Pure
//  values; `EditorViewModel` owns the state.
//

import Foundation
import simd

nonisolated enum SketchPlaneNavigation {

    /// The origin plane a cube face or named view defines, facing the eye.
    /// nil off-axis: an edge, a corner or Isometric defines no plane.
    static func originPlane(facing eye: SIMD3<Double>) -> SketchPlane? {
        guard simd_length(eye) > 1e-9 else { return nil }
        let n = simd_normalize(eye)
        let axes: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        for axis in axes {
            let along = simd_dot(n, axis)
            if abs(along) > 0.9999 {
                return .readable(origin: .zero, normal: along > 0 ? axis : -axis)
            }
        }
        return nil
    }

    /// From the eye's side a named view looks from; nil for Isometric.
    static func eyeDirection(of view: StandardView) -> SIMD3<Double>? {
        switch view {
        case .front: return SIMD3(0, 0, 1)
        case .back: return SIMD3(0, 0, -1)
        case .right: return SIMD3(1, 0, 0)
        case .left: return SIMD3(-1, 0, 0)
        case .top: return SIMD3(0, 1, 0)
        case .bottom: return SIMD3(0, -1, 0)
        case .isometric: return nil
        }
    }

    /// Follows the camera's angle off a plane's normal. The flight in starts
    /// off-axis, so turning away only counts once the camera has landed.
    struct FlatTracker: Equatable {
        static let landedDegrees: Double = 1
        private(set) var settled = false
        private(set) var isFlat = true

        mutating func cameraMoved(offAxisDegrees: Double, leaveDegrees: Double) {
            if offAxisDegrees < Self.landedDegrees {
                settled = true
                isFlat = true
            } else if settled, offAxisDegrees > leaveDegrees {
                isFlat = false
            }
        }
    }
}
