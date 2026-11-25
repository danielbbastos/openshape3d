//
//  PinnedMeasurement.swift
//  openshape3d
//
//  Measure ▸ Pin (spec §16.3, "Pin to Always Show"): a measurement kept in
//  the model as an annotation — a distance between two points or the angle
//  at the middle of three — drawn until it is unpinned, and hidden with
//  View ▸ Show Pinned Measurements. Plain world points: a pin records what
//  was measured, it does not follow geometry that moves later.
//

import Foundation
import simd

nonisolated struct PinnedMeasurement: Identifiable, Codable, Equatable, Sendable {
    /// `row`: any other Measure row (an area, a radius, a minimum distance
    /// between faces…), kept with its reading as it was when pinned.
    enum Kind: String, Codable, Sendable { case distance, angle, row }

    var id = UUID()
    var kind: Kind
    /// Distance: the two end points. Angle: arm end, vertex, arm end.
    /// Row: what the row was measured between (2 = a span, 3 = an angle),
    /// or nothing.
    var points: [SIMD3<Double>]

    /// `row` pins only — absent in documents saved before rows could be
    /// pinned, which hold distances and angles alone.
    /// `MeasureRow.Kind` raw value: the row's title.
    var rowKind: String?
    var storedValue: Double?
    var quantity: MeasureRow.Quantity?
    /// Where the label of a row with no span sits (a face's centroid).
    var anchor: SIMD3<Double>?
    /// What was measured, so the pin can measure it again when the model
    /// changes. Nil in documents saved before pins followed their items
    /// (and for a pin whose items cannot be named): those keep the reading
    /// they were pinned with.
    var sources: [PinSource]?

    /// Millimetres for a distance, degrees for an angle; a row's own unit.
    var value: Double {
        switch kind {
        case .row:
            return storedValue ?? 0
        case .distance:
            guard points.count == 2 else { return 0 }
            return simd_length(points[1] - points[0])
        case .angle:
            guard points.count == 3 else { return 0 }
            return MeasureKit.angleDegrees(points[0], vertex: points[1], points[2]) ?? 0
        }
    }

    /// Where the label sits: the span's midpoint, or just inside the angle.
    var labelAnchor: SIMD3<Double> {
        switch kind {
        case .row:
            if let anchor { return anchor }
            if points.count == 2 { return (points[0] + points[1]) / 2 }
            if points.count == 3 { return PinnedMeasurement(kind: .angle, points: points).labelAnchor }
            return points.first ?? .zero
        case .distance:
            return points.count == 2 ? (points[0] + points[1]) / 2 : points.first ?? .zero
        case .angle:
            guard points.count == 3 else { return points.first ?? .zero }
            let v = points[1]
            let a = points[0] - v, c = points[2] - v
            let la = simd_length(a), lc = simd_length(c)
            guard la > 1e-12, lc > 1e-12 else { return v }
            let reach = min(la, lc) * 0.4
            let bisector = a / la + c / lc
            let len = simd_length(bisector)
            return len > 1e-9 ? v + bisector / len * reach : v + a / la * reach
        }
    }

    /// World segments for the renderer: the span, or the two arms.
    var segments: [SIMD3<Double>] {
        switch kind {
        case .row:
            if points.count == 2 { return points }
            if points.count == 3 { return [points[0], points[1], points[1], points[2]] }
            return []
        case .distance: return points.count == 2 ? points : []
        case .angle: return points.count == 3 ? [points[0], points[1], points[1], points[2]] : []
        }
    }
}

/// One measured item, named so a pin can find it again: a body by id; a face
/// or edge by a point on it in the BODY'S OWN coordinates (kernel face and
/// edge numbers can change when the model is edited, the nearest face to a
/// point on it is what the person meant); a notable point carried along by
/// the body it was picked on; a sketch entity; or a plain world point.
nonisolated enum PinSource: Codable, Equatable, Sendable {
    case point(SIMD3<Double>)
    case bodyPoint(body: UUID, local: SIMD3<Double>)
    case body(UUID)
    case face(body: UUID, local: SIMD3<Double>)
    case edge(body: UUID, local: SIMD3<Double>)
    case sketchEntity(sketch: UUID, entity: UUID)
}

extension PinnedMeasurement {
    /// A Measure row as a pin. A two-point distance and a three-point angle
    /// keep their own kinds (their value is recomputed from the points).
    init(row: MeasureRow, anchor: SIMD3<Double>?, sources: [PinSource]? = nil) {
        switch row.kind {
        case .distance where row.points.count == 2:
            self.init(kind: .distance, points: row.points)
        case .angle where row.points.count == 3:
            self.init(kind: .angle, points: row.points)
        default:
            self.init(kind: .row, points: row.points)
            rowKind = row.kind.rawValue
            storedValue = row.value
            quantity = row.quantity
            self.anchor = row.points.isEmpty ? anchor : nil
        }
        self.sources = sources
    }

    /// The row's title for a `row` pin; nil for a distance or an angle.
    var rowTitle: String? {
        rowKind.flatMap(MeasureRow.Kind.init(rawValue:)).map { MeasureRow(kind: $0, value: 0).title }
    }
}

struct PinMeasurementCommand: DocumentCommand {
    let title = "Pin Measurement"
    let measurement: PinnedMeasurement

    func apply(to document: inout DesignDocument) {
        document.pinnedMeasurements.append(measurement)
    }

    func revert(in document: inout DesignDocument) {
        document.pinnedMeasurements.removeAll { $0.id == measurement.id }
    }
}

struct UnpinMeasurementCommand: DocumentCommand {
    let title = "Unpin Measurement"
    let measurement: PinnedMeasurement
    let index: Int

    func apply(to document: inout DesignDocument) {
        document.pinnedMeasurements.removeAll { $0.id == measurement.id }
    }

    func revert(in document: inout DesignDocument) {
        document.pinnedMeasurements.insert(measurement, at: min(index, document.pinnedMeasurements.count))
    }
}
