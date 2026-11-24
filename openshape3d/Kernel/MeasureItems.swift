//
//  MeasureItems.swift
//  openshape3d
//
//  Picks → `MeasureItem`s in world space: a whole body, one of its faces or
//  edges, or a sketch entity. A body with a B-rep is measured on the exact
//  geometry (its kernel face / edge by the shared 1-based index); a
//  mesh-only body falls back to its render triangles.
//

import Foundation
import simd

nonisolated extension MeasureItem {

    /// The body's B-rep moved into world space, or nil (mesh-only body).
    static func worldBRep(of body: Body) -> BRepHandle? {
        guard let brep = body.brep else { return nil }
        return OCCTKernel.transformed(brep, by: body.transform)
    }

    /// World-space triangles of `triangles` (triangle numbers) of the
    /// body's render mesh; every triangle when nil.
    static func worldTriangles(of body: Body, triangles: [Int]? = nil) -> [SIMD3<Double>] {
        let mesh = body.render
        let count = mesh.indices.count / 3
        var out: [SIMD3<Double>] = []
        let list = triangles ?? Array(0..<count)
        out.reserveCapacity(list.count * 3)
        for t in list where t >= 0 && t < count {
            for k in 0..<3 {
                let local = SIMD3<Double>(mesh.positions[Int(mesh.indices[t * 3 + k])])
                out.append(body.transform.applying(to: local))
            }
        }
        return out
    }

    /// A whole body: its volume and centre of gravity.
    static func body(_ body: Body, world: BRepHandle? = nil) -> MeasureItem {
        let triangles = worldTriangles(of: body)
        let shape = world ?? worldBRep(of: body)
        if let shape, OCCTKernel.solidCount(shape) > 0,
           case .solid(let volume, let centroid)? = OCCTKernel.measureGeometry(shape, kind: .body, index: 0),
           volume > 0 {
            return MeasureItem(ref: .body(body.id), geometry: .solid(volume: volume, centroid: centroid),
                               triangles: triangles,
                               kernel: MeasureKernelPiece(shape: shape, kind: .body, index: 0))
        }
        return MeasureItem(ref: .body(body.id),
                           geometry: .solid(volume: MeasureKit.volume(of: body),
                                            centroid: meshCentroid(triangles)),
                           triangles: triangles)
    }

    /// A face: kernel face `kernelIndex` when the body has a B-rep, else
    /// the picked render triangles (`triangles`, a `PlanarFace` / smooth
    /// region's triangle numbers).
    static func face(of body: Body, kernelIndex: Int?, triangles: [Int],
                     world: BRepHandle? = nil) -> MeasureItem {
        let worldTris = worldTriangles(of: body, triangles: triangles)
        let ref = Ref.face(body.id, kernelIndex ?? -(triangles.min() ?? 0) - 1)
        if let kernelIndex, let shape = world ?? worldBRep(of: body),
           case .surface(let surface, let area, let centroid)? =
            OCCTKernel.measureGeometry(shape, kind: .face, index: kernelIndex) {
            return MeasureItem(ref: ref, geometry: .surface(surface, area: area, centroid: centroid),
                               triangles: worldTris,
                               kernel: MeasureKernelPiece(shape: shape, kind: .face, index: kernelIndex))
        }
        return MeasureItem(ref: ref, geometry: meshSurface(worldTris), triangles: worldTris)
    }

    /// An edge: kernel edge `kernelIndex` when the body has a B-rep; else
    /// the picked polyline (world space).
    static func edge(of body: Body, kernelIndex: Int?, polyline: [SIMD3<Double>],
                     world: BRepHandle? = nil) -> MeasureItem {
        let ref = Ref.edge(body.id, kernelIndex ?? -1)
        if let kernelIndex, let shape = world ?? worldBRep(of: body),
           case .curve(let curve, let length, let start, let end)? =
            OCCTKernel.measureGeometry(shape, kind: .edge, index: kernelIndex) {
            let drawn: [SIMD3<Double>]
            if case .line = curve { drawn = [start, end] } else { drawn = polyline.isEmpty ? [start, end] : polyline }
            return MeasureItem(ref: ref, geometry: .curve(curve, length: length, polyline: drawn),
                               kernel: MeasureKernelPiece(shape: shape, kind: .edge, index: kernelIndex))
        }
        var length = 0.0
        for i in polyline.indices.dropFirst() { length += simd_length(polyline[i] - polyline[i - 1]) }
        let curve: MeasureCurve = polyline.count == 2 ? .line(polyline[0], polyline[1]) : .other
        return MeasureItem(ref: ref, geometry: .curve(curve, length: length, polyline: polyline))
    }

    /// A sketch entity on its plane. Lines and circles / arcs are exact;
    /// every other shape is its drawn polyline (a rectangle, polygon,
    /// ellipse or spline measures its perimeter).
    static func sketchEntity(_ entity: SketchEntity, sketchID: SketchID, plane: SketchPlane) -> MeasureItem {
        let ref = Ref.sketchEntity(sketchID, entity.id)
        let normal = simd_normalize(plane.normal)
        let length = MeasureKit.length(of: entity)
        func world(_ points: [SIMD2<Double>], closed: Bool) -> [SIMD3<Double>] {
            var out = points.map(plane.toWorld)
            if closed, let first = out.first { out.append(first) }
            return out
        }
        let geometry: Geometry
        switch entity {
        case let .line(_, a, b):
            let pa = plane.toWorld(a), pb = plane.toWorld(b)
            geometry = .curve(.line(pa, pb), length: length, polyline: [pa, pb])
        case let .circle(_, c, r):
            let points = SketchEntity.arcPoints(center: c, radius: r, startAngle: 0,
                                                endAngle: 2 * .pi - 1e-9, segmentsPerTurn: 96)
            geometry = .curve(.circle(center: plane.toWorld(c), axis: normal, radius: r, sweep: 2 * .pi),
                              length: length, polyline: world(points, closed: true))
        case let .arc(_, c, r, s, e):
            let sweep = SketchEntity.arcSweep(startAngle: s, endAngle: e)
            let points = SketchEntity.arcPoints(center: c, radius: r, startAngle: s, endAngle: e,
                                                segmentsPerTurn: 96)
            geometry = .curve(.circle(center: plane.toWorld(c), axis: normal, radius: r, sweep: sweep),
                              length: length, polyline: world(points, closed: false))
        case let .rect(_, lo, hi):
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            geometry = .curve(.other, length: length, polyline: world(corners, closed: true))
        case let .ellipse(_, c, rx, ry, rot):
            let points = SketchEntity.ellipsePoints(center: c, radiusX: rx, radiusY: ry, rotation: rot, segments: 96)
            geometry = .curve(.other, length: length, polyline: world(points, closed: true))
        case let .polygon(_, c, r, n, rot):
            let points = SketchEntity.polygonPoints(center: c, radius: r, sides: n, rotation: rot)
            geometry = .curve(.other, length: length, polyline: world(points, closed: true))
        case let .spline(_, points, closed):
            geometry = .curve(.other, length: length,
                              polyline: world(SketchEntity.splinePoints(points, closed: closed), closed: closed))
        }
        return MeasureItem(ref: ref, geometry: geometry)
    }

    // MARK: Mesh fallbacks

    static func meshCentroid(_ triangles: [SIMD3<Double>]) -> SIMD3<Double> {
        // Area-weighted triangle centroids: the surface's centre, which for
        // a mesh-only body stands in for the centre of gravity.
        var sum = SIMD3<Double>.zero, total = 0.0
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            sum += (a + b + c) / 3 * area
            total += area
        }
        return total > 0 ? sum / total : .zero
    }

    /// A face from triangles alone: flat when every triangle shares one
    /// normal (to 1e-6), else `.other`.
    static func meshSurface(_ triangles: [SIMD3<Double>]) -> Geometry {
        var area = 0.0
        var normal: SIMD3<Double>?
        var flat = true
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            area += len / 2
            guard len > 1e-12 else { continue }
            let n = cross / len
            if let normal {
                if simd_dot(normal, n) < 1 - 1e-6 { flat = false }
            } else {
                normal = n
            }
        }
        let centroid = meshCentroid(triangles)
        if flat, let normal {
            return .surface(.plane(origin: centroid, normal: normal), area: area, centroid: centroid)
        }
        return .surface(.other, area: area, centroid: centroid)
    }
}
