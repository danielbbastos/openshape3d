//
//  SketchPlaneMirror.swift
//  openshape3d
//
//  Mirror ▸ sketch shapes across a 3D plane (spec §5.6), from the model
//  view — the same face / plane picks as a body mirror. Pure values; the
//  editor turns the result into one undoable command.
//
//  Two outcomes:
//  * The mirror plane cuts the sketch plane at right angles: the image lies
//    in the SAME sketch plane, mirrored across the line where the planes
//    meet — so the copies go into the same sketch (a mirrored half next to
//    its original, ready to close into one profile).
//  * Any other plane: the image lies on the reflected sketch plane. Reflect
//    the plane's frame along with the geometry and every point keeps its
//    plane-local coordinates, so the copy is the same entities on a new
//    sketch at the reflected plane.
//

import Foundation
import simd

nonisolated enum SketchPlaneMirror {

    enum Result {
        /// Add these (fresh ids) to the source sketch.
        case sameSketch([SketchEntity])
        /// A new sketch on `plane` holding these (fresh ids).
        case newSketch(plane: SketchPlane, entities: [SketchEntity])
    }

    /// `point` reflected across the plane through `origin` with `normal`.
    static func reflect(_ point: SIMD3<Double>, origin: SIMD3<Double>, normal: SIMD3<Double>) -> SIMD3<Double> {
        let n = simd_normalize(normal)
        return point - 2 * simd_dot(point - origin, n) * n
    }

    /// A direction reflected across a plane with `normal`.
    static func reflectDirection(_ v: SIMD3<Double>, normal: SIMD3<Double>) -> SIMD3<Double> {
        let n = simd_normalize(normal)
        return v - 2 * simd_dot(v, n) * n
    }

    /// The mirror of `entities` (lying on `sketchPlane`) across the plane
    /// through `mirrorOrigin` with `mirrorNormal`.
    static func mirror(
        _ entities: [SketchEntity], on sketchPlane: SketchPlane,
        acrossOrigin mirrorOrigin: SIMD3<Double>, normal mirrorNormal: SIMD3<Double>
    ) -> Result {
        let n = simd_normalize(mirrorNormal)
        let sketchNormal = simd_normalize(sketchPlane.normal)

        // Perpendicular planes: the mirror line is where they meet, in the
        // sketch's own coordinates. Its direction is in both planes.
        if abs(simd_dot(n, sketchNormal)) < 1e-6 {
            let direction3 = simd_normalize(simd_cross(n, sketchNormal))
            // A point of the line: the sketch origin moved onto the mirror
            // plane along n (n lies in the sketch plane here).
            let onLine3 = sketchPlane.origin - simd_dot(sketchPlane.origin - mirrorOrigin, n) * n
            let a = sketchPlane.toLocal(onLine3)
            let b = sketchPlane.toLocal(onLine3 + direction3)
            let axis = b - a
            let slanted = abs(axis.x) > 1e-9 && abs(axis.y) > 1e-9
            return .sameSketch(entities.flatMap { entity -> [SketchEntity] in
                // A rectangle across a slanted line is a rotated rectangle,
                // which `.rect` cannot hold: its four reflected sides.
                if slanted, case let .rect(_, lo, hi) = entity {
                    let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
                        .map { reflectPoint($0, acrossA: a, b: b) }
                    return (0..<4).map { .line(id: UUID(), a: corners[$0], b: corners[($0 + 1) % 4]) }
                }
                return [mirroredSketchEntity(entity, acrossA: a, b: b)]
            })
        }

        // Any other plane: reflect the frame; local coordinates carry over.
        let plane = SketchPlane(
            origin: reflect(sketchPlane.origin, origin: mirrorOrigin, normal: n),
            xAxis: reflectDirection(sketchPlane.xAxis, normal: n),
            yAxis: reflectDirection(sketchPlane.yAxis, normal: n)
        )
        return .newSketch(plane: plane, entities: entities.map(Self.freshCopy))
    }

    /// The same entity with a new id.
    static func freshCopy(_ entity: SketchEntity) -> SketchEntity {
        switch entity {
        case let .line(_, a, b): .line(id: UUID(), a: a, b: b)
        case let .rect(_, lo, hi): .rect(id: UUID(), min: lo, max: hi)
        case let .circle(_, c, r): .circle(id: UUID(), center: c, radius: r)
        case let .arc(_, c, r, s, e): .arc(id: UUID(), center: c, radius: r, startAngle: s, endAngle: e)
        case let .ellipse(_, c, rx, ry, rot): .ellipse(id: UUID(), center: c, radiusX: rx, radiusY: ry, rotation: rot)
        case let .polygon(_, c, r, n, rot): .polygon(id: UUID(), center: c, radius: r, sides: n, rotation: rot)
        case let .spline(_, points, closed): .spline(id: UUID(), points: points, closed: closed)
        }
    }
}
