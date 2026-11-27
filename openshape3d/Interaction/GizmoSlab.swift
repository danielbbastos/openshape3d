//
//  GizmoSlab.swift
//  openshape3d
//
//  The move gizmo's plane squares and arrows as small 3D solids, the way
//  Shapr3D draws them. Picture the gizmo as the inside corner of a cube
//  whose farthest corner is the centre dot: the ground face and the two back
//  walls. Each square and arrow is a thin slab lying on one of those faces;
//  you see its white top and the grey side walls turned toward you.
//
//  Pure geometry in gizmo-local units (the same space `GizmoScreenLayout`
//  projects): build the prism, then ask which of its faces face the eye.
//  `MoveGizmoOverlay` projects and paints them.
//

import simd

nonisolated struct GizmoSlab: Equatable {
    /// The outline, in gizmo-local space, on the slab's mid-plane.
    var outline: [SIMD3<Float>]
    /// Unit normal of the plane the slab lies in.
    var normal: SIMD3<Float>
    var thickness: Float

    /// About 4 pt on screen: one gizmo unit is ~0.24 of the half view height.
    static let defaultThickness: Float = 0.025

    nonisolated struct Face: Equatable {
        var points: [SIMD3<Float>]
        var normal: SIMD3<Float>
        var isCap: Bool

        var centre: SIMD3<Float> {
            points.reduce(.zero, +) / Float(max(points.count, 1))
        }
    }

    /// Both caps and one wall per outline edge, each with its outward normal.
    var faces: [Face] {
        guard outline.count >= 3 else { return [] }
        let half = normal * (thickness / 2)
        var faces = [
            Face(points: outline.map { $0 + half }, normal: normal, isCap: true),
            Face(points: outline.reversed().map { $0 - half }, normal: -normal, isCap: true),
        ]
        // Which way round the outline runs decides which side is outside.
        var turn: Float = 0
        for i in outline.indices {
            turn += simd_dot(simd_cross(outline[i], outline[(i + 1) % outline.count]), normal)
        }
        let outward: Float = turn >= 0 ? 1 : -1
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let edge = b - a
            guard simd_length_squared(edge) > 1e-12 else { continue }
            let wall = simd_normalize(simd_cross(edge, normal)) * outward
            faces.append(Face(points: [a + half, b + half, b - half, a - half], normal: wall, isCap: false))
        }
        return faces
    }

    /// The faces turned toward an eye at `eye` (gizmo-local), walls first
    /// from far to near, then the one cap that faces the eye — the order to
    /// paint them in.
    func visibleFaces(eye: SIMD3<Float>) -> [Face] {
        let shown = faces.filter { simd_dot($0.normal, eye - $0.centre) > 1e-6 }
        let walls = shown.filter { !$0.isCap }
            .sorted { simd_length($0.centre - eye) > simd_length($1.centre - eye) }
        return walls + shown.filter(\.isCap)
    }

    // MARK: - The gizmo's slabs

    /// A plane square: the tile `GizmoGeometry` hit-tests, on its own plane.
    static func square(_ part: GizmoPart, thickness: Float = defaultThickness) -> GizmoSlab? {
        guard part.isPlane else { return nil }
        let n = part.axisDirection
        let (u, v) = axesInPlane(normal: n)
        let lo = GizmoGeometry.planeMin, hi = GizmoGeometry.planeMax
        let corners = [u * lo + v * lo, u * hi + v * lo, u * hi + v * hi, u * lo + v * hi]
        return GizmoSlab(outline: rounded(corners, radius: 0.03, normal: n), normal: n, thickness: thickness)
    }

    /// Arrow outline sizes, gizmo units.
    static let arrowLength: Float = 0.28
    static let arrowHeadLength: Float = 0.13
    static let arrowHeadHalf: Float = 0.12
    static let arrowShaftHalf: Float = 0.047

    /// A move arrow centred on its arm's end, lying on the cube face that
    /// turns toward the eye — turning smoothly about its own axis from one
    /// face to the other as the view orbits (see `arrowPlaneNormal`).
    static func arrow(_ part: GizmoPart, eye: SIMD3<Float>, thickness: Float = defaultThickness) -> GizmoSlab? {
        guard !part.isPlane, !part.isRing else { return nil }
        let a = part.axisDirection
        let centre = a * GizmoScreenLayout.armLocal
        let normal = arrowPlaneNormal(axis: a, eyeDirection: eye - centre)
        let across = simd_cross(normal, a)
        let tip = centre + a * (arrowLength / 2)
        func pt(_ along: Float, _ side: Float) -> SIMD3<Float> { tip + a * along + across * side }
        let corners = [
            pt(0, 0), pt(-arrowHeadLength, arrowHeadHalf), pt(-arrowHeadLength, arrowShaftHalf),
            pt(-arrowLength, arrowShaftHalf), pt(-arrowLength, -arrowShaftHalf),
            pt(-arrowHeadLength, -arrowShaftHalf), pt(-arrowHeadLength, -arrowHeadHalf),
        ]
        return GizmoSlab(outline: rounded(corners, radius: 0.018, normal: normal), normal: normal, thickness: thickness)
    }

    /// Half the turn, radians, over which an arrow eases from one face to
    /// the other, centred on the 45° view where the old rule snapped.
    static let arrowTurnHalfWindow: Float = 25 * .pi / 180

    /// The plane an arrow lies in, as its normal. The arrow turns about its
    /// own `axis`. While one of the two cube faces holding that axis is
    /// clearly the one facing the eye, the arrow lies flat on it. Through a
    /// window around 45°, where the faces hand over, it turns smoothly from
    /// one to the other instead of snapping 90°.
    static func arrowPlaneNormal(axis: SIMD3<Float>, eyeDirection: SIMD3<Float>) -> SIMD3<Float> {
        let others = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
            .filter { abs(simd_dot($0, axis)) < 0.5 }
        guard others.count == 2 else { return SIMD3(0, 0, 1) }
        let p = others[0], q = others[1]
        let ex = simd_dot(eyeDirection, p), ey = simd_dot(eyeDirection, q)
        // The eye's angle round the axis, folded into the quadrant between
        // the two faces: 0 = square to face `p`, π/2 = square to face `q`.
        let theta = atan2(abs(ey), abs(ex))
        let lo = Float.pi / 4 - arrowTurnHalfWindow, hi = Float.pi / 4 + arrowTurnHalfWindow
        let t = min(max((theta - lo) / (hi - lo), 0), 1)
        let phi = Float.pi / 2 * (t * t * (3 - 2 * t))
        let sx: Float = ex < 0 ? -1 : 1, sy: Float = ey < 0 ? -1 : 1
        return simd_normalize(p * (sx * cos(phi)) + q * (sy * sin(phi)))
    }

    /// Curved-arrow sizes, gizmo units: band and head half-widths, and how
    /// far each head reaches past the end of the 30° arc.
    static let arcBandHalf: Float = 0.032
    static let arcHeadHalf: Float = 0.078
    static let arcHeadLength: Float = 0.1

    /// A rotation handle: the 30° arc `GizmoScreenLayout.ringPolyline` draws,
    /// as a band with an arrowhead at each end, lying in its ring's plane.
    static func arc(_ part: GizmoPart, thickness: Float = defaultThickness) -> GizmoSlab? {
        guard part.isRing else { return nil }
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        let r = GizmoScreenLayout.ringLocal
        let a0 = Float.pi / 4 - 15 * .pi / 180
        let a1 = Float.pi / 4 + 15 * .pi / 180
        let reach = arcHeadLength / r
        func at(_ angle: Float, _ radius: Float) -> SIMD3<Float> { (u * cos(angle) + v * sin(angle)) * radius }
        let steps = 12
        var outline: [SIMD3<Float>] = []
        for i in 0...steps { outline.append(at(a0 + (a1 - a0) * Float(i) / Float(steps), r + arcBandHalf)) }
        outline += [at(a1, r + arcHeadHalf), at(a1 + reach, r), at(a1, r - arcHeadHalf)]
        for i in stride(from: steps, through: 0, by: -1) {
            outline.append(at(a0 + (a1 - a0) * Float(i) / Float(steps), r - arcBandHalf))
        }
        outline += [at(a0, r - arcHeadHalf), at(a0 - reach, r), at(a0, r + arcHeadHalf)]
        let normal = simd_normalize(simd_cross(u, v))
        return GizmoSlab(outline: rounded(outline, radius: 0.008, normal: normal), normal: normal, thickness: thickness)
    }

    /// Two in-plane axes for a gizmo plane normal, in the plane's own order
    /// (Z → X, Y; X → Y, Z; Y → Z, X).
    static func axesInPlane(normal n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        if abs(n.z) > 0.5 { return (SIMD3(1, 0, 0), SIMD3(0, 1, 0)) }
        if abs(n.x) > 0.5 { return (SIMD3(0, 1, 0), SIMD3(0, 0, 1)) }
        return (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
    }

    /// `corners` with each corner replaced by a short arc of `radius`
    /// (capped at half of either neighbouring edge), sampled in 4 steps.
    static func rounded(_ corners: [SIMD3<Float>], radius: Float, normal: SIMD3<Float>) -> [SIMD3<Float>] {
        guard corners.count >= 3, radius > 0 else { return corners }
        var out: [SIMD3<Float>] = []
        for i in corners.indices {
            let p = corners[(i + corners.count - 1) % corners.count]
            let v = corners[i]
            let q = corners[(i + 1) % corners.count]
            let toP = p - v, toQ = q - v
            let r = min(radius, simd_length(toP) / 2, simd_length(toQ) / 2)
            guard r > 1e-6 else { out.append(v); continue }
            let a = v + simd_normalize(toP) * r
            let b = v + simd_normalize(toQ) * r
            for k in 0...3 {
                let t = Float(k) / 3
                // Quadratic Bézier a → v → b.
                out.append(a * (1 - t) * (1 - t) + v * 2 * (1 - t) * t + b * t * t)
            }
        }
        return out
    }
}
