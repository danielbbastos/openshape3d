//
//  MeasureQuery.swift
//  openshape3d
//
//  Measure (spec §16.3): what is measured and what it
//  measures. A pick becomes a `MeasureItem` (a point, an edge or sketch
//  curve, a face, or a whole body) in WORLD space; `MeasureQuery.rows`
//  turns one or more of them into the rows the Measure panel and the
//  selection info bar show — length / area / volume (summed), radius and
//  diameter, angle and perpendicular angle, minimum / central / parallel
//  distance, and the X/Y/Z components.
//
//  Pure values. Exact answers come from the kernel when an item knows the
//  B-rep piece it came from (`MeasureItem.kernel`); `MeasureQuery.exact`
//  is the OCCT seam, and the triangle / segment fallback covers mesh-only
//  bodies and sketch geometry.
//

import Foundation
import simd

// MARK: - Items

/// The analytic shape of a measured face.
nonisolated enum MeasureSurface: Equatable, Sendable {
    case plane(origin: SIMD3<Double>, normal: SIMD3<Double>)
    case cylinder(point: SIMD3<Double>, axis: SIMD3<Double>, radius: Double)
    case cone(apex: SIMD3<Double>, axis: SIMD3<Double>, semiAngle: Double, referenceRadius: Double)
    case sphere(center: SIMD3<Double>, radius: Double)
    case other
}

/// The analytic shape of a measured edge or sketch curve.
nonisolated enum MeasureCurve: Equatable, Sendable {
    case line(SIMD3<Double>, SIMD3<Double>)
    /// `sweep` in radians; 2π for a full circle.
    case circle(center: SIMD3<Double>, axis: SIMD3<Double>, radius: Double, sweep: Double)
    case other
}

/// The B-rep piece an item came from, for exact distances. `shape` is the
/// body's B-rep already moved into world space.
nonisolated struct MeasureKernelPiece: @unchecked Sendable {
    enum Kind: Int, Sendable { case body = 0, face = 1, edge = 2 }
    var shape: BRepHandle
    var kind: Kind
    /// 1-based kernel index; ignored for `.body`.
    var index: Int
}

nonisolated struct MeasureItem: Identifiable, @unchecked Sendable {

    /// What was picked — its identity in the document, so a second tap on
    /// the same thing deselects it and a panel row can highlight it.
    enum Ref: Hashable, Sendable {
        case point(UUID)
        case body(BodyID)
        case face(BodyID, Int)
        case edge(BodyID, Int)
        case sketchEntity(SketchID, UUID)
    }

    enum Geometry {
        case point(SIMD3<Double>)
        /// An edge or sketch curve. `polyline` is the drawn curve, in order.
        case curve(MeasureCurve, length: Double, polyline: [SIMD3<Double>])
        case surface(MeasureSurface, area: Double, centroid: SIMD3<Double>)
        case solid(volume: Double, centroid: SIMD3<Double>)
    }

    var ref: Ref
    var geometry: Geometry
    /// The item as triangles (faces, bodies), for the mesh distance fallback
    /// and for highlighting.
    var triangles: [SIMD3<Double>] = []
    var kernel: MeasureKernelPiece?
    /// A world point that lies ON the item (a face's point nearest its
    /// centroid, an edge's middle, a body's centre of gravity): how a pin
    /// finds the item again after the model changes.
    var anchor: SIMD3<Double>?

    var id: Ref { ref }

    static func point(_ p: SIMD3<Double>, id: UUID = UUID()) -> MeasureItem {
        MeasureItem(ref: .point(id), geometry: .point(p), anchor: p)
    }
}

// MARK: - Rows

nonisolated struct MeasureRow: Identifiable, Equatable, Sendable {

    enum Kind: String, CaseIterable, Sendable {
        case length, area, volume, radius, diameter
        case angle, perpendicularAngle
        case distance, minDistance, centralDistance, parallelDistance
        case dx, dy, dz
    }

    enum Quantity: String, Codable, Sendable { case length, angle, area, volume }

    var kind: Kind
    /// Millimetres, degrees, mm² or mm³ by `quantity`.
    var value: Double
    /// What the row measures between, drawn when it is highlighted or
    /// pinned: a span's two ends, an angle's arm–vertex–arm, or nothing.
    var points: [SIMD3<Double>] = []
    /// The items this reading is about — lit up when it is highlighted.
    var refs: [MeasureItem.Ref] = []

    var id: Kind { kind }

    var quantity: Quantity {
        switch kind {
        case .angle, .perpendicularAngle: .angle
        case .area: .area
        case .volume: .volume
        default: .length
        }
    }

    var title: String {
        switch kind {
        case .length: "Length"
        case .area: "Area"
        case .volume: "Volume"
        case .radius: "Radius"
        case .diameter: "Diameter"
        case .angle: "Angle"
        case .perpendicularAngle: "Perpendicular angle"
        case .distance: "Distance"
        case .minDistance: "Minimum distance"
        case .centralDistance: "Central distance"
        case .parallelDistance: "Parallel distance"
        case .dx: "X-axis"
        case .dy: "Y-axis"
        case .dz: "Z-axis"
        }
    }
}

// MARK: - The query

nonisolated enum MeasureQuery {

    /// A shortest span between two items: its length and both ends.
    struct Span: Equatable {
        var distance: Double
        var a: SIMD3<Double>
        var b: SIMD3<Double>
    }

    /// Exact minimum distance between two kernel pieces (OCCT). Replaceable
    /// so tests can run the fallback alone.
    nonisolated(unsafe) static var exact: (MeasureKernelPiece, MeasureKernelPiece) -> Span? = {
        OCCTKernel.minimumDistance($0, $1)
    }

    /// Directions closer than this to parallel count as parallel (≈0.0008°).
    static let parallelTolerance = 1e-8
    /// Lengths under this are zero (mm).
    static let lengthEpsilon = 1e-9

    /// The rows for these items, in the order the panel lists them.
    /// `deltas` adds the X/Y/Z components of every distance.
    static func rows(for items: [MeasureItem], deltas: Bool) -> [MeasureRow] {
        guard !items.isEmpty else { return [] }
        let all = items.map(\.ref)
        if items.count == 3, let pts = allPoints(items) {
            guard let angle = MeasureKit.angleDegrees(pts[0], vertex: pts[1], pts[2]) else { return [] }
            return [MeasureRow(kind: .angle, value: angle, points: pts, refs: all)]
        }
        if items.count == 2 {
            return pairRows(items[0], items[1], deltas: deltas).map { row in
                var row = row
                row.refs = all
                return row
            }
        }
        return sumRows(items)
    }

    // MARK: One kind, one or many

    private static func sumRows(_ items: [MeasureItem]) -> [MeasureRow] {
        var length = 0.0, area = 0.0, volume = 0.0
        var curves = 0, surfaces = 0, solids = 0
        for item in items {
            switch item.geometry {
            case .point: break
            case .curve(_, let l, _): length += l; curves += 1
            case .surface(_, let a, _): area += a; surfaces += 1
            case .solid(let v, _): volume += v; solids += 1
            }
        }
        func refs(_ keep: (MeasureItem.Geometry) -> Bool) -> [MeasureItem.Ref] {
            items.filter { keep($0.geometry) }.map(\.ref)
        }
        var rows: [MeasureRow] = []
        if curves > 0 {
            rows.append(MeasureRow(kind: .length, value: length,
                                   refs: refs { if case .curve = $0 { true } else { false } }))
        }
        if surfaces > 0 {
            rows.append(MeasureRow(kind: .area, value: area,
                                   refs: refs { if case .surface = $0 { true } else { false } }))
        }
        if solids > 0 {
            rows.append(MeasureRow(kind: .volume, value: volume,
                                   refs: refs { if case .solid = $0 { true } else { false } }))
        }
        if items.count == 1 {
            rows += roundRows(items[0]).map { row in
                var row = row
                row.refs = [items[0].ref]
                return row
            }
        }
        return rows
    }

    /// Radius and diameter of a round item; an arc's central angle.
    private static func roundRows(_ item: MeasureItem) -> [MeasureRow] {
        let radius: Double?
        var center: SIMD3<Double>?
        var arcAngle: Double?
        switch item.geometry {
        case .curve(.circle(let c, _, let r, let sweep), _, _):
            radius = r
            center = c
            if sweep < 2 * .pi - 1e-9 { arcAngle = sweep * 180 / .pi }
        case .surface(.cylinder(_, _, let r), _, _):
            radius = r
        case .surface(.sphere(let c, let r), _, _):
            radius = r
            center = c
        case .surface(.cone(_, _, _, let r), _, _):
            radius = r > lengthEpsilon ? r : nil
        default:
            radius = nil
        }
        guard let radius else { return [] }
        var rows = [MeasureRow(kind: .radius, value: radius, points: center.map { [$0] } ?? []),
                    MeasureRow(kind: .diameter, value: 2 * radius)]
        if let arcAngle { rows.append(MeasureRow(kind: .angle, value: arcAngle)) }
        return rows
    }

    // MARK: Two items

    private static func pairRows(_ a: MeasureItem, _ b: MeasureItem, deltas: Bool) -> [MeasureRow] {
        // Two points: the plain point-to-point distance.
        if case .point(let p) = a.geometry, case .point(let q) = b.geometry {
            var rows = [MeasureRow(kind: .distance, value: simd_length(q - p), points: [p, q])]
            if deltas { rows += deltaRows(p, q) }
            return rows
        }

        var rows: [MeasureRow] = []
        let da = direction(of: a), db = direction(of: b)
        if let da, let db {
            let cosine = min(abs(simd_dot(da, db)), 1)
            let angle = acos(cosine) * 180 / .pi
            rows.append(MeasureRow(kind: .angle, value: angle))
            if angle > 1e-6, angle < 90 - 1e-6 {
                rows.append(MeasureRow(kind: .perpendicularAngle, value: 90 - angle))
            }
        }

        let span = minimumSpan(a, b).map { centered($0, a, b) }
        if let span {
            rows.append(MeasureRow(kind: .minDistance, value: span.distance, points: [span.a, span.b]))
        }
        if let central = centralSpan(a, b) {
            rows.append(MeasureRow(kind: .centralDistance, value: central.distance, points: [central.a, central.b]))
        }
        if let parallel = parallelSpan(a, b) {
            // A radial difference has no single span to draw.
            let drawn = parallel.a == parallel.b ? [] : [parallel.a, parallel.b]
            rows.append(MeasureRow(kind: .parallelDistance, value: parallel.distance, points: drawn))
        }
        if deltas, let span { rows += deltaRows(span.a, span.b) }
        return rows
    }

    private static func deltaRows(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> [MeasureRow] {
        let d = q - p
        return [MeasureRow(kind: .dx, value: abs(d.x), points: [p, SIMD3(q.x, p.y, p.z)]),
                MeasureRow(kind: .dy, value: abs(d.y), points: [p, SIMD3(p.x, q.y, p.z)]),
                MeasureRow(kind: .dz, value: abs(d.z), points: [p, SIMD3(p.x, p.y, q.z)])]
    }

    private static func allPoints(_ items: [MeasureItem]) -> [SIMD3<Double>]? {
        var out: [SIMD3<Double>] = []
        for item in items {
            guard case .point(let p) = item.geometry else { return nil }
            out.append(p)
        }
        return out
    }

    // MARK: Directions, centres, parallels

    /// The direction an angle is measured from: a line's direction, a flat
    /// face's normal, a round thing's axis. Nil for everything else.
    static func direction(of item: MeasureItem) -> SIMD3<Double>? {
        let raw: SIMD3<Double>
        switch item.geometry {
        case .curve(.line(let p, let q), _, _): raw = q - p
        case .curve(.circle(_, let axis, _, _), _, _): raw = axis
        case .surface(.plane(_, let n), _, _): raw = n
        case .surface(.cylinder(_, let axis, _), _, _): raw = axis
        case .surface(.cone(_, let axis, _, _), _, _): raw = axis
        default: return nil
        }
        let length = simd_length(raw)
        return length > lengthEpsilon ? raw / length : nil
    }

    /// A centre point or a central axis (point + unit direction).
    enum Center {
        case point(SIMD3<Double>)
        case axis(SIMD3<Double>, SIMD3<Double>)
    }

    /// Circles, arcs and spheres have a centre; cylinders and cones an axis;
    /// a body its centre of gravity ("central distance").
    static func center(of item: MeasureItem) -> Center? {
        switch item.geometry {
        case .curve(.circle(let c, _, _, _), _, _): return .point(c)
        case .surface(.sphere(let c, _), _, _): return .point(c)
        case .surface(.cylinder(let p, let axis, _), _, _): return .axis(p, simd_normalize(axis))
        case .surface(.cone(let apex, let axis, _, _), _, _): return .axis(apex, simd_normalize(axis))
        case .solid(_, let centroid): return .point(centroid)
        case .point(let p): return .point(p)
        default: return nil
        }
    }

    /// Central distance: from the centre or axis of one item to the other
    /// item's centre or axis — or, when it has none, to the item itself
    /// (a line, a flat face). Nil unless at least one side is round or a
    /// body, and never for two plain points (that is `.distance`).
    static func centralSpan(_ a: MeasureItem, _ b: MeasureItem) -> Span? {
        let ca = center(of: a), cb = center(of: b)
        if case .point = a.geometry, case .point = b.geometry { return nil }
        let aRound = ca != nil && !isPoint(a), bRound = cb != nil && !isPoint(b)
        guard aRound || bRound else { return nil }
        switch (ca, cb) {
        case let (.some(x), .some(y)):
            return span(between: x, y)
        case let (.some(x), nil):
            return span(from: x, to: b)
        case let (nil, .some(y)):
            return span(from: y, to: a).map { Span(distance: $0.distance, a: $0.b, b: $0.a) }
        default:
            return nil
        }
    }

    private static func isPoint(_ item: MeasureItem) -> Bool {
        if case .point = item.geometry { return true }
        return false
    }

    private static func span(between x: Center, _ y: Center) -> Span? {
        switch (x, y) {
        case let (.point(p), .point(q)):
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.point(p), .axis(o, d)):
            let q = closestOnLine(p, o, d)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.axis(o, d), .point(q)):
            let p = closestOnLine(q, o, d)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.axis(o1, d1), .axis(o2, d2)):
            return lineLineSpan(o1, d1, o2, d2)
        }
    }

    /// From a centre to an item that has none: a line or a flat face.
    private static func span(from x: Center, to item: MeasureItem) -> Span? {
        let point: SIMD3<Double>
        switch x {
        case .point(let p): point = p
        case .axis(let o, let d):
            // An axis to a face or line: only meaningful when parallel to it.
            switch item.geometry {
            case .surface(.plane(let po, let n), _, _):
                let nn = simd_normalize(n)
                guard abs(simd_dot(d, nn)) < 1e-6 else { return nil }
                let dist = simd_dot(o - po, nn)
                return Span(distance: abs(dist), a: o, b: o - dist * nn)
            case .curve(.line(let p, let q), _, _):
                return lineLineSpan(o, d, p, simd_normalize(q - p))
            default:
                return nil
            }
        }
        switch item.geometry {
        case .surface(.plane(let po, let n), _, _):
            let nn = simd_normalize(n)
            let dist = simd_dot(point - po, nn)
            return Span(distance: abs(dist), a: point, b: point - dist * nn)
        case .curve(.line(let p, let q), _, _):
            let dir = q - p
            guard simd_length(dir) > lengthEpsilon else { return nil }
            let c = closestOnLine(point, p, simd_normalize(dir))
            return Span(distance: simd_length(c - point), a: point, b: c)
        default:
            return nil
        }
    }

    /// Parallel distance: two parallel lines / flat faces / a line and a
    /// parallel face; or, for concentric round items, the radial difference.
    static func parallelSpan(_ a: MeasureItem, _ b: MeasureItem) -> Span? {
        if let radial = radialDifference(a, b) { return radial }
        guard let da = direction(of: a), let db = direction(of: b) else { return nil }
        switch (a.geometry, b.geometry) {
        case let (.surface(.plane(oa, _), _, _), .surface(.plane(ob, _), _, _)):
            guard 1 - abs(simd_dot(da, db)) < parallelTolerance else { return nil }
            let dist = simd_dot(ob - oa, da)
            let from = centroid(of: a) ?? oa
            return Span(distance: abs(dist), a: from, b: from + dist * da)
        case let (.curve(.line(p, _), _, _), .curve(.line(q, _), _, _)):
            guard 1 - abs(simd_dot(da, db)) < parallelTolerance else { return nil }
            let c = closestOnLine(p, q, db)
            return Span(distance: simd_length(c - p), a: p, b: c)
        case let (.curve(.line(p, q), _, _), .surface(.plane(o, _), _, _)):
            return lineFaceSpan(p, q, da, o, db)
        case let (.surface(.plane(o, _), _, _), .curve(.line(p, q), _, _)):
            return lineFaceSpan(p, q, db, o, da).map { Span(distance: $0.distance, a: $0.b, b: $0.a) }
        default:
            return nil
        }
    }

    private static func lineFaceSpan(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ lineDir: SIMD3<Double>,
                                     _ origin: SIMD3<Double>, _ normal: SIMD3<Double>) -> Span? {
        guard abs(simd_dot(lineDir, normal)) < 1e-6 else { return nil }
        let mid = (p + q) / 2
        let dist = simd_dot(mid - origin, normal)
        return Span(distance: abs(dist), a: mid, b: mid - dist * normal)
    }

    /// Concentric arcs, circles, cylinders and spheres: |r₁ − r₂|.
    private static func radialDifference(_ a: MeasureItem, _ b: MeasureItem) -> Span? {
        func round(_ item: MeasureItem) -> (center: Center, radius: Double)? {
            switch item.geometry {
            case .curve(.circle(let c, let axis, let r, _), _, _): return (.axis(c, simd_normalize(axis)), r)
            case .surface(.cylinder(let p, let axis, let r), _, _): return (.axis(p, simd_normalize(axis)), r)
            case .surface(.sphere(let c, let r), _, _): return (.point(c), r)
            default: return nil
            }
        }
        guard let ra = round(a), let rb = round(b) else { return nil }
        let tolerance = 1e-6 * max(1, ra.radius, rb.radius)
        switch (ra.center, rb.center) {
        case let (.point(p), .point(q)):
            guard simd_length(q - p) < tolerance else { return nil }
        case let (.axis(o1, d1), .axis(o2, d2)):
            guard 1 - abs(simd_dot(d1, d2)) < parallelTolerance,
                  simd_length(closestOnLine(o2, o1, d1) - o2) < tolerance else { return nil }
        case let (.point(p), .axis(o, d)), let (.axis(o, d), .point(p)):
            guard simd_length(closestOnLine(p, o, d) - p) < tolerance else { return nil }
        }
        return Span(distance: abs(ra.radius - rb.radius), a: .zero, b: .zero)
    }

    private static func centroid(of item: MeasureItem) -> SIMD3<Double>? {
        switch item.geometry {
        case .surface(_, _, let c), .solid(_, let c): return c
        case .point(let p): return p
        case .curve(_, _, let polyline):
            guard !polyline.isEmpty else { return nil }
            return polyline.reduce(.zero, +) / Double(polyline.count)
        }
    }

    // MARK: Minimum distance

    /// Between two parallel faces or edges that overlap, every straight-
    /// across span is a shortest one, and the kernel hands back whichever it
    /// met first — often at a far corner, where it reads like the WIDEST
    /// gap. Draw the span through the middle of the overlap instead. Same
    /// length; only where it is drawn changes.
    static func centered(_ span: Span, _ a: MeasureItem, _ b: MeasureItem) -> Span {
        let tolerance = max(1e-6, span.distance * 1e-6)
        switch (a.geometry, b.geometry) {
        case let (.curve(.line(p1, q1), _, _), .curve(.line(p2, q2), _, _)):
            let d = q1 - p1
            let ll = simd_dot(d, d)
            guard ll > 0, let db = direction(of: b), 1 - abs(simd_dot(simd_normalize(d), db)) < parallelTolerance
            else { return span }
            // Overlap of B's ends along A, as A's parameter.
            let t2 = simd_dot(p2 - p1, d) / ll, t3 = simd_dot(q2 - p1, d) / ll
            let lo = max(0, min(t2, t3)), hi = min(1, max(t2, t3))
            guard lo <= hi else { return span }
            let onA = p1 + d * ((lo + hi) / 2)
            let onB = closestOnSegment(onA, p2, q2)
            let length = simd_length(onB - onA)
            return abs(length - span.distance) <= tolerance ? Span(distance: span.distance, a: onA, b: onB) : span
        case (.surface(.plane, _, let ca), .surface(.plane(let ob, let nb), _, let cb)):
            guard !a.triangles.isEmpty, !b.triangles.isEmpty, let da = direction(of: a),
                  1 - abs(simd_dot(da, simd_normalize(nb))) < parallelTolerance else { return span }
            let n = simd_normalize(nb)
            // Try the middle between the two faces first, then each centre.
            for seed in [(ca + cb) / 2, ca, cb] {
                guard let onA = MeasureItem.closestOnTriangles(seed, a.triangles) else { continue }
                let onB = onA - simd_dot(onA - ob, n) * n
                guard let check = MeasureItem.closestOnTriangles(onB, b.triangles),
                      simd_length(check - onB) <= max(1e-4, tolerance) else { continue }
                let length = simd_length(onB - onA)
                if abs(length - span.distance) <= max(1e-4, tolerance) {
                    return Span(distance: span.distance, a: onA, b: onB)
                }
            }
            return span
        default:
            return span
        }
    }

    /// The shortest span between two items: exact from the kernel when both
    /// came from a B-rep, otherwise from their points, segments and
    /// triangles.
    static func minimumSpan(_ a: MeasureItem, _ b: MeasureItem) -> Span? {
        if let ka = a.kernel, let kb = b.kernel, let exact = exact(ka, kb) { return exact }
        return approximateSpan(a, b)
    }

    /// Exact for points, segments and triangles; a curve is its polyline,
    /// a face or body its triangles.
    static func approximateSpan(_ a: MeasureItem, _ b: MeasureItem) -> Span? {
        let pa = primitives(of: a), pb = primitives(of: b)
        guard !pa.isEmpty, !pb.isEmpty else { return nil }
        var best: Span?
        func consider(_ s: Span) {
            if best == nil || s.distance < best!.distance { best = s }
        }
        for x in pa {
            for y in pb {
                consider(span(x, y))
                if let best, best.distance < lengthEpsilon { return best }
            }
        }
        return best
    }

    enum Primitive {
        case point(SIMD3<Double>)
        case segment(SIMD3<Double>, SIMD3<Double>)
        case triangle(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
    }

    static func primitives(of item: MeasureItem) -> [Primitive] {
        switch item.geometry {
        case .point(let p):
            return [.point(p)]
        case .curve(_, _, let polyline):
            guard polyline.count > 1 else { return polyline.map { .point($0) } }
            return (1..<polyline.count).map { .segment(polyline[$0 - 1], polyline[$0]) }
        case .surface, .solid:
            let t = item.triangles
            return stride(from: 0, to: t.count - 2, by: 3).map { .triangle(t[$0], t[$0 + 1], t[$0 + 2]) }
        }
    }

    private static func span(_ x: Primitive, _ y: Primitive) -> Span {
        switch (x, y) {
        case let (.point(p), .point(q)):
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.point(p), .segment(s, e)):
            let q = closestOnSegment(p, s, e)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.segment(s, e), .point(q)):
            let p = closestOnSegment(q, s, e)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.point(p), .triangle(t0, t1, t2)):
            let q = closestOnTriangle(p, t0, t1, t2)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.triangle(t0, t1, t2), .point(q)):
            let p = closestOnTriangle(q, t0, t1, t2)
            return Span(distance: simd_length(q - p), a: p, b: q)
        case let (.segment(s1, e1), .segment(s2, e2)):
            return segmentSegmentSpan(s1, e1, s2, e2)
        case let (.segment(s, e), .triangle(t0, t1, t2)):
            return segmentTriangleSpan(s, e, t0, t1, t2)
        case let (.triangle(t0, t1, t2), .segment(s, e)):
            let r = segmentTriangleSpan(s, e, t0, t1, t2)
            return Span(distance: r.distance, a: r.b, b: r.a)
        case let (.triangle(a0, a1, a2), .triangle(b0, b1, b2)):
            // The closest pair lies on an edge of one of the two triangles,
            // unless they cross (distance 0, which an edge also finds).
            var best = segmentTriangleSpan(a0, a1, b0, b1, b2)
            for (s, e) in [(a1, a2), (a2, a0)] {
                let r = segmentTriangleSpan(s, e, b0, b1, b2)
                if r.distance < best.distance { best = r }
            }
            for (s, e) in [(b0, b1), (b1, b2), (b2, b0)] {
                let r = segmentTriangleSpan(s, e, a0, a1, a2)
                if r.distance < best.distance { best = Span(distance: r.distance, a: r.b, b: r.a) }
            }
            return best
        }
    }

    // MARK: Closest-point geometry

    static func closestOnLine(_ p: SIMD3<Double>, _ o: SIMD3<Double>, _ d: SIMD3<Double>) -> SIMD3<Double> {
        o + simd_dot(p - o, d) * d
    }

    static func closestOnSegment(_ p: SIMD3<Double>, _ s: SIMD3<Double>, _ e: SIMD3<Double>) -> SIMD3<Double> {
        let d = e - s
        let ll = simd_dot(d, d)
        guard ll > 0 else { return s }
        return s + min(max(simd_dot(p - s, d) / ll, 0), 1) * d
    }

    /// Shortest span between two infinite lines (unit directions).
    static func lineLineSpan(_ o1: SIMD3<Double>, _ d1: SIMD3<Double>,
                             _ o2: SIMD3<Double>, _ d2: SIMD3<Double>) -> Span {
        let w = o1 - o2
        let b = simd_dot(d1, d2)
        let denom = 1 - b * b
        if denom < 1e-12 {
            let q = closestOnLine(o1, o2, d2)
            return Span(distance: simd_length(q - o1), a: o1, b: q)
        }
        let d = simd_dot(d1, w), e = simd_dot(d2, w)
        let s = (b * e - d) / denom
        let t = (e - b * d) / denom
        let p = o1 + s * d1, q = o2 + t * d2
        return Span(distance: simd_length(q - p), a: p, b: q)
    }

    /// Ericson, Real-Time Collision Detection §5.1.9.
    static func segmentSegmentSpan(_ p1: SIMD3<Double>, _ q1: SIMD3<Double>,
                                   _ p2: SIMD3<Double>, _ q2: SIMD3<Double>) -> Span {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s = 0.0, t = 0.0
        if a <= 1e-18 && e <= 1e-18 {
            s = 0; t = 0
        } else if a <= 1e-18 {
            t = min(max(f / e, 0), 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= 1e-18 {
                s = min(max(-c / a, 0), 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = a * e - b * b
                s = denom > 1e-18 ? min(max((b * f - c * e) / denom, 0), 1) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0; s = min(max(-c / a, 0), 1)
                } else if t > 1 {
                    t = 1; s = min(max((b - c) / a, 0), 1)
                }
            }
        }
        let c1 = p1 + d1 * s, c2 = p2 + d2 * t
        return Span(distance: simd_length(c2 - c1), a: c1, b: c2)
    }

    /// Ericson §5.1.5.
    static func closestOnTriangle(_ p: SIMD3<Double>, _ a: SIMD3<Double>,
                                  _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + d1 / (d1 - d3) * ab }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + d2 / (d2 - d6) * ac }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (d4 - d3) / ((d4 - d3) + (d5 - d6)) * (c - b)
        }
        let denom = 1 / (va + vb + vc)
        return a + ab * (vb * denom) + ac * (vc * denom)
    }

    static func segmentTriangleSpan(_ s: SIMD3<Double>, _ e: SIMD3<Double>, _ a: SIMD3<Double>,
                                    _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Span {
        // Through the triangle: distance 0 at the crossing.
        let n = simd_cross(b - a, c - a)
        let ds = simd_dot(s - a, n), de = simd_dot(e - a, n)
        if ds * de < 0 {
            let x = s + (e - s) * (ds / (ds - de))
            if simd_length(closestOnTriangle(x, a, b, c) - x) < 1e-9 {
                return Span(distance: 0, a: x, b: x)
            }
        }
        var best: Span = {
            let q = closestOnTriangle(s, a, b, c)
            return Span(distance: simd_length(q - s), a: s, b: q)
        }()
        let qe = closestOnTriangle(e, a, b, c)
        if simd_length(qe - e) < best.distance { best = Span(distance: simd_length(qe - e), a: e, b: qe) }
        for (x, y) in [(a, b), (b, c), (c, a)] {
            let r = segmentSegmentSpan(s, e, x, y)
            if r.distance < best.distance { best = r }
        }
        return best
    }
}
