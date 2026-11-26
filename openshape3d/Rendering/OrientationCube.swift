//
//  OrientationCube.swift
//  openshape3d
//
//  Screen-corner orientation cube (spec §7.2): a small camera-tracking cube
//  drawn in the overlay pass. Tapping a face or corner snaps the turntable
//  camera to that orientation. Layout + hit math live in OrientationCube
//  (shared by rendering and tap routing); OrientationCubeRenderer draws it
//  with the gizmo's unlit pipeline.
//

import Foundation
import Metal
import simd
import CoreGraphics

nonisolated enum OrientationCube {
    /// On-screen footprint (points) and placement in the top-trailing corner,
    /// below the navigation bar chrome.
    static let sizePoints: CGFloat = 92
    static let topInset: CGFloat = 96
    static let trailingInset: CGFloat = 34

    /// Cube-local half extent; the ortho volume leaves margin so the rotated
    /// cube (corner radius √3 ≈ 1.73) never clips its viewport.
    static let halfExtent: Float = 1
    static let orthoHalfExtent: Float = 1.75

    /// Width of the chamfer drawn along every edge and corner, as a fraction
    /// of the half extent. A hit whose |coordinate| on a second axis is past
    /// `1 - bevel` lies on that axis's edge bevel; on all three, a corner.
    static let bevel: Float = 0.3
    /// Hits with all three |coordinates| above this fraction of the half
    /// extent count as corner taps (two of them: an edge).
    static let cornerFraction: Float = 1 - bevel

    /// The axis tripod: three positive axes from just outside the cube's
    /// (−X, −Y, −Z) corner, X red, Y green, Z blue, like the grid's axes.
    static let tripodGap: Float = 0.14
    static let tripodLength: Float = 2 * halfExtent + 2 * tripodGap + 0.45
    static var tripodOrigin: SIMD3<Float> { SIMD3(repeating: -(halfExtent + tripodGap)) }
    static let tripodAxes: [(name: String, direction: SIMD3<Float>)] = [
        ("X", SIMD3(1, 0, 0)), ("Y", SIMD3(0, 1, 0)), ("Z", SIMD3(0, 0, 1)),
    ]

    static func rect(in viewSize: CGSize) -> CGRect {
        CGRect(
            x: viewSize.width - trailingInset - sizePoints,
            y: topInset,
            width: sizePoints,
            height: sizePoints
        )
    }

    // MARK: - Face labels (spec §7.2)

    /// A standard-view name drawn over the cube face that snaps to it.
    nonisolated struct FaceLabel: Identifiable, Equatable, Sendable {
        var id: String { name }
        /// Matches `StandardView.rawValue`, so the cube and the Views menu
        /// never disagree about which way is Front.
        var name: String
        var point: CGPoint
        /// Fades as the face turns away, so only the faces you could actually
        /// tap are named and the cube does not turn into a wall of text.
        var opacity: Double
    }

    /// Outward normal of each named face. Derived from `StandardView`: azimuth
    /// 0 / elevation 0 puts the eye on +Z, which is Front.
    static let faceNormals: [(name: String, normal: SIMD3<Float>)] = [
        (StandardView.front.rawValue, SIMD3(0, 0, 1)),
        (StandardView.back.rawValue, SIMD3(0, 0, -1)),
        (StandardView.right.rawValue, SIMD3(1, 0, 0)),
        (StandardView.left.rawValue, SIMD3(-1, 0, 0)),
        (StandardView.top.rawValue, SIMD3(0, 1, 0)),
        (StandardView.bottom.rawValue, SIMD3(0, -1, 0)),
    ]

    /// A face must be turned at least this far toward the camera to be named.
    /// Geometrically a face is visible whenever this is above 0, but the last
    /// few degrees are too foreshortened to read; 0.25 (~75° off head-on) keeps
    /// every face you could sensibly tap — including the shallow Top face of
    /// the default isometric, whose facing is only 0.43 — and drops the rest.
    static let labelMinFacing: Float = 0.25

    /// Named faces currently turned toward the camera, in screen points.
    ///
    /// Pure layout: the same projection the cube is drawn with, so a label
    /// always sits on the face it names, at any orientation.
    static func faceLabels(camera: TurntableCamera, viewSize: CGSize) -> [FaceLabel] {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let eyeOffset = camera.position - camera.target
        guard simd_length(eyeOffset) > 1e-6 else { return [] }
        let eye = simd_normalize(eyeOffset)
        let vp = viewProjection(camera: camera, viewSize: viewSize)

        return faceNormals.compactMap { face in
            let facing = simd_dot(face.normal, eye)
            guard facing > labelMinFacing else { return nil }
            // Sit slightly proud of the surface so the label is never buried
            // in the face colour at a grazing angle.
            let centre = face.normal * (halfExtent * 1.02)
            let clip = vp * SIMD4(centre.x, centre.y, centre.z, 1)
            guard abs(clip.w) > 1e-6 else { return nil }
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            let point = CGPoint(
                x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width,
                y: CGFloat(1 - (ndc.y * 0.5 + 0.5)) * viewSize.height
            )
            // Ramp from just-visible to fully opaque across the usable range.
            let t = (facing - labelMinFacing) / (1 - labelMinFacing)
            return FaceLabel(name: face.name, point: point,
                             opacity: Double(min(max(t * 1.6, 0.25), 1)))
        }
    }

    /// Where each tripod axis ends, in screen points, for its letter.
    static func axisLabels(camera: TurntableCamera, viewSize: CGSize) -> [FaceLabel] {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let vp = viewProjection(camera: camera, viewSize: viewSize)
        return tripodAxes.compactMap { axis in
            let tip = tripodOrigin + axis.direction * (tripodLength + 0.22)
            let clip = vp * SIMD4(tip.x, tip.y, tip.z, 1)
            guard abs(clip.w) > 1e-6 else { return nil }
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            // An axis pointing straight at the eye has no length on screen;
            // its letter would sit on the origin, so fade it.
            let eye = simd_normalize(camera.position - camera.target)
            let foreshortened = 1 - abs(simd_dot(axis.direction, eye))
            return FaceLabel(
                name: axis.name,
                point: CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width,
                               y: CGFloat(1 - (ndc.y * 0.5 + 0.5)) * viewSize.height),
                opacity: Double(min(1, max(0, foreshortened * 4))))
        }
    }

    /// Rotation-only view of the camera (world → view, no translation).
    static func rotationView(of camera: TurntableCamera) -> simd_float4x4 {
        var view = camera.viewMatrix
        view.columns.3 = SIMD4(0, 0, 0, 1)
        return view
    }

    /// Full view-projection for the cube: camera rotation → small ortho
    /// volume → NDC placement in the corner viewport.
    static func viewProjection(camera: TurntableCamera, viewSize: CGSize) -> simd_float4x4 {
        let ortho = Matrices.orthographic(
            halfWidth: orthoHalfExtent,
            halfHeight: orthoHalfExtent,
            // Deeper than wide: the axis tripod reaches past the cube's
            // corners, and must not be clipped as the cube turns.
            near: -3,
            far: 3
        )
        let r = rect(in: viewSize)
        var placement = matrix_identity_float4x4
        placement.columns.0.x = Float(r.width / viewSize.width)
        placement.columns.1.y = Float(r.height / viewSize.height)
        placement.columns.3.x = Float(2 * r.midX / viewSize.width - 1)
        placement.columns.3.y = Float(1 - 2 * r.midY / viewSize.height)
        return placement * ortho * rotationView(of: camera)
    }

    /// Face/corner under a tap, as the camera pose looking at it head-on;
    /// nil when the tap misses the cube. A dedicated mini ray is built in
    /// cube-local space: an ortho ray through the tap's corner-viewport
    /// coordinates, un-rotated by the camera basis.
    ///
    /// `facesOnly` (a fingertip): always the nearest face, never an edge or a
    /// corner — Shapr3D ignores the bevels under a finger, which is too
    /// coarse to aim at them; the Pencil and a pointer pick them (an edge is a
    /// 45° view between its two faces, a corner an isometric one).
    static func hitPose(
        at point: CGPoint, camera: TurntableCamera, viewSize: CGSize,
        facesOnly: Bool = false
    ) -> TurntableCamera? {
        let r = rect(in: viewSize)
        guard r.width > 0, r.contains(point) else { return nil }
        let u = Float((point.x - r.midX) / (r.width / 2))
        let v = Float(-(point.y - r.midY) / (r.height / 2))

        // Camera basis in world space (view matrix rows).
        let view = camera.viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let back = SIMD3(view.columns.0.z, view.columns.1.z, view.columns.2.z)

        let origin = right * (u * orthoHalfExtent)
            + up * (v * orthoHalfExtent)
            + back * (orthoHalfExtent * 2)
        let direction = -back
        guard let hit = intersectCube(origin: origin, direction: direction) else { return nil }

        let p = hit / halfExtent
        let normal: SIMD3<Float>
        let onBevel = SIMD3<Float>(
            abs(p.x) > cornerFraction ? (p.x < 0 ? -1 : 1) : 0,
            abs(p.y) > cornerFraction ? (p.y < 0 ? -1 : 1) : 0,
            abs(p.z) > cornerFraction ? (p.z < 0 ? -1 : 1) : 0)
        let bevelAxes = (onBevel.x != 0 ? 1 : 0) + (onBevel.y != 0 ? 1 : 0) + (onBevel.z != 0 ? 1 : 0)
        if !facesOnly, bevelAxes >= 2 {
            // An edge (two axes) or a corner (three): look down the bisector.
            normal = simd_normalize(onBevel)
        } else {
            // Face: the axis with the dominant coordinate.
            let a = abs(p)
            if a.x >= a.y && a.x >= a.z {
                normal = SIMD3(p.x < 0 ? -1 : 1, 0, 0)
            } else if a.y >= a.z {
                normal = SIMD3(0, p.y < 0 ? -1 : 1, 0)
            } else {
                normal = SIMD3(0, 0, p.z < 0 ? -1 : 1)
            }
        }
        return pose(lookingAlong: normal, from: camera)
    }

    /// Turntable pose with the eye along `normal` (unit, world space).
    /// Top/bottom look straight down / up (±elevationLimit = ±90°) and keep
    /// the current azimuth.
    static func pose(
        lookingAlong normal: SIMD3<Float>, from camera: TurntableCamera
    ) -> TurntableCamera {
        var cam = camera
        cam.roll = 0
        cam.elevation = min(
            max(asin(min(max(normal.y, -1), 1)), -TurntableCamera.elevationLimit),
            TurntableCamera.elevationLimit
        )
        if abs(normal.x) + abs(normal.z) > 1e-5 {
            cam.azimuth = atan2(normal.x, normal.z)
        }
        return cam
    }

    /// Slab intersection with the cube [-halfExtent, halfExtent]³; returns
    /// the entry point (or the origin when starting inside).
    static func intersectCube(
        origin: SIMD3<Float>, direction: SIMD3<Float>
    ) -> SIMD3<Float>? {
        var tMin = -Float.infinity
        var tMax = Float.infinity
        for i in 0..<3 {
            let o = origin[i]
            let d = direction[i]
            if abs(d) < 1e-8 {
                if abs(o) > halfExtent { return nil }
                continue
            }
            var t0 = (-halfExtent - o) / d
            var t1 = (halfExtent - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            tMin = max(tMin, t0)
            tMax = min(tMax, t1)
        }
        guard tMin <= tMax, tMax > 0 else { return nil }
        return origin + direction * max(tMin, 0)
    }
}

/// Draws the orientation cube in the overlay pass, reusing the gizmo's
/// unlit-color pipeline: a dark chamfered cube (6 faces, 12 edge bevels,
/// 8 corner facets — each a tap target), shaded per facet against a light
/// fixed to the camera so it reads as solid, dark facet outlines, and the
/// X/Y/Z tripod in the axis colours.
final class OrientationCubeRenderer {
    struct Facet {
        let vertexRange: Range<Int>
        let normal: SIMD3<Float>
        let kind: Kind
        enum Kind { case face, edge, corner }
    }

    private var vertexBuffer: MTLBuffer?
    private var facets: [Facet] = []
    private var edgeBuffer: MTLBuffer?
    private var edgeVertexCount = 0
    private var tripodBuffer: MTLBuffer?

    private static let faceColor = SIMD3<Float>(0.24, 0.245, 0.255)
    private static let bevelColor = SIMD3<Float>(0.33, 0.335, 0.345)
    private static let outlineColor = SIMD4<Float>(0.10, 0.105, 0.11, 1)
    static let axisColors: [SIMD4<Float>] = [
        SIMD4(0.85, 0.30, 0.30, 1), SIMD4(0.30, 0.70, 0.35, 1), SIMD4(0.25, 0.45, 0.90, 1),
    ]

    /// The chamfered cube's facets as triangle fans (convex polygons), with
    /// their outward normals. Pure, so tests can count them.
    static func facetPolygons() -> [(polygon: [SIMD3<Float>], normal: SIMD3<Float>, kind: Facet.Kind)] {
        let h = OrientationCube.halfExtent
        let i = h * (1 - OrientationCube.bevel)
        var out: [([SIMD3<Float>], SIMD3<Float>, Facet.Kind)] = []
        func vec(_ axis: Int, _ a: Float, _ b: Int, _ bv: Float, _ c: Int, _ cv: Float) -> SIMD3<Float> {
            var v = SIMD3<Float>.zero
            v[axis] = a; v[b] = bv; v[c] = cv
            return v
        }
        // Faces: inset squares.
        for axis in 0..<3 {
            let b = (axis + 1) % 3, c = (axis + 2) % 3
            for sign: Float in [-1, 1] {
                var n = SIMD3<Float>.zero; n[axis] = sign
                out.append(([
                    vec(axis, sign * h, b, -i, c, -i), vec(axis, sign * h, b, i, c, -i),
                    vec(axis, sign * h, b, i, c, i), vec(axis, sign * h, b, -i, c, i),
                ], n, .face))
            }
        }
        // Edges: between face `a` (sign sa) and face `b` (sign sb), along `k`.
        for k in 0..<3 {
            let a = (k + 1) % 3, b = (k + 2) % 3
            for sa: Float in [-1, 1] {
                for sb: Float in [-1, 1] {
                    var n = SIMD3<Float>.zero; n[a] = sa; n[b] = sb
                    out.append(([
                        vec(a, sa * h, b, sb * i, k, -i), vec(a, sa * h, b, sb * i, k, i),
                        vec(a, sa * i, b, sb * h, k, i), vec(a, sa * i, b, sb * h, k, -i),
                    ], simd_normalize(n), .edge))
                }
            }
        }
        // Corners: the triangle cut off each vertex.
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    out.append(([
                        SIMD3(sx * h, sy * i, sz * i), SIMD3(sx * i, sy * h, sz * i), SIMD3(sx * i, sy * i, sz * h),
                    ], simd_normalize(SIMD3(sx, sy, sz)), .corner))
                }
            }
        }
        return out
    }

    func prepare(device: MTLDevice) {
        guard vertexBuffer == nil else { return }
        var vertices: [SIMD3<Float>] = []
        var lines: [SIMD3<Float>] = []
        var built: [Facet] = []
        for (polygon, normal, kind) in Self.facetPolygons() {
            let start = vertices.count
            for k in 1..<(polygon.count - 1) {
                vertices.append(contentsOf: [polygon[0], polygon[k], polygon[k + 1]])
            }
            built.append(Facet(vertexRange: start..<vertices.count, normal: normal, kind: kind))
            // Outline just proud of the surface so it wins the depth test.
            for k in 0..<polygon.count {
                let a = polygon[k], b = polygon[(k + 1) % polygon.count]
                lines.append(contentsOf: [a * 1.004, b * 1.004])
            }
        }
        facets = built
        vertexBuffer = Self.buffer(device, vertices)
        edgeVertexCount = lines.count
        edgeBuffer = Self.buffer(device, lines)
        let o = OrientationCube.tripodOrigin
        var tripod: [SIMD3<Float>] = []
        for axis in OrientationCube.tripodAxes {
            tripod.append(contentsOf: [o, o + axis.direction * OrientationCube.tripodLength])
        }
        tripodBuffer = Self.buffer(device, tripod)
    }

    private static func buffer(_ device: MTLDevice, _ points: [SIMD3<Float>]) -> MTLBuffer? {
        points.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!,
                              length: points.count * MemoryLayout<SIMD3<Float>>.stride,
                              options: .storageModeShared)
        }
    }

    private func setColor(_ color: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        var body = BodyUniforms()
        body.modelMatrix = matrix_identity_float4x4
        body.baseColor = color
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        camera: TurntableCamera,
        viewSize: CGSize
    ) {
        guard let vertexBuffer, let edgeBuffer, let tripodBuffer,
              viewSize.width > 0, viewSize.height > 0
        else { return }

        var frame = FrameUniforms()
        frame.viewProjectionMatrix = OrientationCube.viewProjection(
            camera: camera, viewSize: viewSize
        )

        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))

        // A key light fixed to the camera (up-left, toward the viewer), so
        // whichever facets face the user stay lit as the cube turns.
        let view = OrientationCube.rotationView(of: camera)
        let light = simd_normalize(SIMD3<Float>(-0.35, 0.55, 1))
        for facet in facets {
            let n4 = view * SIMD4(facet.normal, 0)
            let lambert = max(0, simd_dot(SIMD3(n4.x, n4.y, n4.z), light))
            let base = facet.kind == .face ? Self.faceColor : Self.bevelColor
            let shade = base * (0.72 + 0.45 * lambert)
            setColor(SIMD4(simd_min(shade, SIMD3(repeating: 1)), 1), encoder: encoder)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: facet.vertexRange.lowerBound,
                vertexCount: facet.vertexRange.count
            )
        }

        setColor(Self.outlineColor, encoder: encoder)
        encoder.setVertexBuffer(edgeBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeVertexCount)

        encoder.setVertexBuffer(tripodBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        for (index, color) in Self.axisColors.enumerated() {
            setColor(color, encoder: encoder)
            encoder.drawPrimitives(type: .line, vertexStart: index * 2, vertexCount: 2)
        }
    }
}
