//
//  BlendFaceLookup.swift
//  openshape3d
//
//  Which fillet or chamfer made a face. Tapping the round of a fillet (or
//  the bevel of a chamfer) reopens that feature with its edges and its
//  drag handle, so its size can be changed in place, as in other direct
//  modellers. A face belongs to a blend when every point of it lies within
//  the blend's size of one of the sharp edges the blend replaced: a
//  fillet's round never strays further than its radius from the edge it
//  rounded, a chamfer's bevel no further than its setback.
//
//  Points and stored edge signatures are both in the body's local space.
//

import Foundation
import simd

nonisolated extension FeatureGraph {
    /// The latest active fillet or chamfer of `bodyID` that made the face
    /// whose points are `facePoints` (body-local), or nil.
    func blendFeature(forBody bodyID: BodyID, facePoints: [SIMD3<Double>]) -> FeatureID? {
        guard !facePoints.isEmpty else { return nil }
        let active = nodes.prefix(rollbackIndex ?? nodes.count)
        for node in active.reversed() where !node.suppressed {
            let edges: [EdgeRef]
            let size: Double
            switch node.kind {
            case let .fillet(body, refs, radius) where body.bodyID == bodyID:
                edges = refs; size = radius.value
            case let .chamfer(body, refs, setback) where body.bodyID == bodyID:
                edges = refs; size = setback.value
            default:
                continue
            }
            guard size > 0 else { continue }
            // Chord sag and float rounding: a few percent of the size.
            let reach = size * 1.05 + 1e-4
            for edge in edges where Self.allWithin(reach, of: edge.signature, facePoints) {
                return node.id
            }
        }
        return nil
    }

    private static func allWithin(_ reach: Double, of edge: EdgeSignature, _ points: [SIMD3<Double>]) -> Bool {
        let length = simd_length(edge.direction)
        guard length > 1e-12 else { return false }
        let d = edge.direction / length
        let a = edge.midpoint - d * (edge.length / 2)
        // A round meets the edge's end faces square, so its points project
        // within the edge's span; a point well past either end is elsewhere.
        for p in points {
            let t = simd_dot(p - a, d)
            guard t >= -reach, t <= edge.length + reach else { return false }
            let closest = a + d * min(max(t, 0), edge.length)
            if simd_distance(p, closest) > reach { return false }
        }
        return true
    }
}
