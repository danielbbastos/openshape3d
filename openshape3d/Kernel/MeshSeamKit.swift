//
//  MeshSeamKit.swift
//  openshape3d
//
//  How open a mesh really is. `isWatertight` is all or nothing, and about
//  half of ordinary mesh cuts on Float-stored bodies fail it on cracks of
//  1e-7 mm, which render, measure and export fine. A cut is refused only for
//  an opening with real width.
//

import Foundation
import Euclid

nonisolated enum MeshSeamKit {

    /// Openings narrower than this (mm) are hairline seams.
    static let hairlineMM = 1e-3

    /// The widest opening: how far the middle of any boundary edge lies from
    /// the rest of the boundary. A closed mesh, or one with only zero-width
    /// cracks, reads (about) 0.
    static func openingWidth(of mesh: Euclid.Mesh) -> Double {
        var uses = [LineSegment: Int]()
        for polygon in mesh.polygons {
            for edge in polygon.undirectedEdges { uses[edge, default: 0] += 1 }
        }
        let boundary = uses.filter { !$0.value.isMultiple(of: 2) }.map { $0.key }
        var widest = 0.0
        for (i, edge) in boundary.enumerated() {
            let span = edge.end - edge.start
            // An edge shorter than a hairline can't bound a wider opening.
            guard span.length > hairlineMM else { continue }
            let middle = (edge.start + edge.end) / 2
            var nearest = Double.infinity
            for (j, other) in boundary.enumerated() where j != i {
                let along = other.end - other.start
                let lengthSquared = along.dot(along)
                guard lengthSquared > 0 else { continue }
                let t = max(0, min(1, (middle - other.start).dot(along) / lengthSquared))
                nearest = min(nearest, (middle - (other.start + along * t)).length)
                if nearest <= widest { break } // can't raise the maximum
            }
            widest = max(widest, nearest)
        }
        return widest
    }

    /// True when a boolean opened `result` further than its input already was
    /// (an imported open mesh may stay as open as it came in).
    static func boolean(_ result: Euclid.Mesh, opened input: Euclid.Mesh) -> Bool {
        let after = openingWidth(of: result)
        return after > hairlineMM && after > openingWidth(of: input) + hairlineMM
    }

    static func refusalMessage(for name: String) -> String {
        "This would leave a hole in the mesh “\(name)”, so nothing was changed. "
            + "Change the size or position a little, so faces don't line up exactly, and try again."
    }
}
