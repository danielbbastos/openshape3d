//
//  MeasureNotablePoints.swift
//  openshape3d
//
//  Measure ▸ Point-to-Point and 3-Point Angle snap to "notable points"
//  (spec §2.7): a body's corners, the middle of every edge, the
//  centre of every circle and arc, and the centre of the face under the
//  pointer. World space. A body with a B-rep reads them from its kernel
//  edges — a tessellated rim would otherwise offer every facet corner; a
//  mesh-only body offers its render vertices and straight-edge midpoints.
//

import Foundation
import simd

nonisolated enum MeasureNotablePoints {

    /// One edge's notable points.
    struct Edge: Equatable {
        var start: SIMD3<Double>
        var end: SIMD3<Double>
        var mid: SIMD3<Double>?
        var center: SIMD3<Double>?
    }

    /// Every notable point of a body, without repeats.
    static func points(of body: Body) -> [SIMD3<Double>] {
        if let world = MeasureItem.worldBRep(of: body) {
            let edges = kernelEdges(world)
            if !edges.isEmpty { return points(of: edges) }
        }
        return meshPoints(of: body)
    }

    /// Corners (ends), middles and centres of `edges`, without repeats.
    static func points(of edges: [Edge]) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for edge in edges {
            out.append(edge.start)
            out.append(edge.end)
            if let mid = edge.mid { out.append(mid) }
            if let center = edge.center { out.append(center) }
        }
        return deduplicated(out)
    }

    /// The B-rep's edges (`shape` in world space).
    static func kernelEdges(_ shape: BRepHandle) -> [Edge] {
        let mids = OCCTKernel.edgeMidpoints(shape)
        var out: [Edge] = []
        for index in mids.keys.sorted() {
            guard case .curve(let curve, _, let start, let end)? =
                    OCCTKernel.measureGeometry(shape, kind: .edge, index: index) else { continue }
            var center: SIMD3<Double>?
            if case .circle(let c, _, _, _) = curve { center = c }
            out.append(Edge(start: start, end: end, mid: mids[index], center: center))
        }
        return out
    }

    /// A mesh-only body: its render vertices, and the middle of each
    /// straight feature edge.
    static func meshPoints(of body: Body) -> [SIMD3<Double>] {
        var out = body.render.positions.map { body.transform.applying(to: SIMD3<Double>($0)) }
        for edge in EdgeTopology.selectableEdges(from: body.render) {
            out.append(body.transform.applying(to: SIMD3<Double>(edge.midpoint)))
        }
        return deduplicated(out)
    }

    /// Points closer than `tolerance` (mm) count once.
    static func deduplicated(_ points: [SIMD3<Double>], tolerance: Double = 1e-6) -> [SIMD3<Double>] {
        var seen = Set<SIMD3<Int64>>()
        var out: [SIMD3<Double>] = []
        for p in points {
            let key = SIMD3<Int64>((p / tolerance).rounded(.toNearestOrEven))
            if seen.insert(key).inserted { out.append(p) }
        }
        return out
    }
}
