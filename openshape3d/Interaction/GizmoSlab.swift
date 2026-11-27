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

    /// A move arrow centred on its arm's end, lying on whichever of the two
    /// cube faces holding its axis turns more toward the eye — so it always
    /// reads as a shape, never a sliver.
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

    /// Of the two gizmo axes square to `axis`, the one (as a plane normal)
    /// most in line with the eye.
    static func arrowPlaneNormal(axis: SIMD3<Float>, eyeDirection: SIMD3<Float>) -> SIMD3<Float> {
        let candidates = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
            .filter { abs(simd_dot($0, axis)) < 0.5 }
        let eye = simd_length_squared(eyeDirection) > 0 ? simd_normalize(eyeDirection) : SIMD3<Float>(0, 0, 1)
        return candidates.max { abs(simd_dot($0, eye)) < abs(simd_dot($1, eye)) } ?? SIMD3<Float>(0, 0, 1)
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
