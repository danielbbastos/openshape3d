//
//  MoveGizmoOverlay.swift
//  openshape3d
//
//  The move/rotate gizmo, drawn in 2D (SwiftUI) instead of as a Metal mesh so
//  it matches the extrude handle's flat, outlined look:
//
//   • axis translate arrows — solid flat arrows with a dark outline, exactly
//     like the extrude pull handle;
//   • rotation handles — thin double-headed arrows on a curve;
//   • plane-move handles — tiles lying IN their own plane (so the square
//     leans with the model and shows which way it drags);
//   • the pivot — a dot, or a crosshair once tapped (drag it to reposition
//     the whole control without moving the model).
//
//  Purely visual: it projects the gizmo's own local part anchors (the same
//  positions the 3D hit test in `GizmoGeometry` uses) to screen, so a tap on a
//  drawn handle lands on its 3D drag target. Hit-testing and drag math stay in
//  the viewport — this view never takes a touch.
//

import SwiftUI
import simd

struct MoveGizmoOverlay: View {
    @Bindable var viewModel: EditorViewModel

    // Extrude-handle palette: dark outline behind a light/coloured fill.
    private static let outline = Color(white: 0.08)
    private static let fill = Color.white
    private static let highlight = Color(red: 0.20, green: 0.52, blue: 1.0)
    private static let pivot = Color(red: 0.20, green: 0.80, blue: 0.85)
    /// The armed-pivot crosshair (Shapr3D uses a violet crosshair here).
    private static let reposition = Color(red: 0.55, green: 0.36, blue: 0.96)

    private let axes: [GizmoPart] = [.xAxis, .yAxis, .zAxis]
    private let rings: [GizmoPart] = [.xRing, .yRing, .zRing]

    var body: some View {
        let _ = viewModel.cameraEpoch
        if let origin = viewModel.gizmoOrigin,
           let control = viewModel.cameraControl,
           let center = control.worldToScreenPoint(dbl(origin)) {
            let scale = control.gizmoWorldScale(at: origin)
            let ctx = ProjectionContext(origin: origin, scale: scale, basis: viewModel.gizmoBasis, control: control)

            ZStack(alignment: .topLeading) {
                // Face-rotate shows ONLY the rings (+ pivot) so the control reads
                // as a pure rotate; body/move/scale keep their plane handles.
                if !viewModel.faceRotateActive {
                    planeTiles(ctx)
                }
                // A selected face translates/scales only — hide the rotation rings
                // unless the Rotate tool armed them.
                if viewModel.gizmoAllowsRotation {
                    ForEach(rings, id: \.self) { rotationArc($0, ctx) }
                }
                // Scale mode shows square grips at the axis ends (drag any to
                // scale about the centre); move mode shows the directional arrows;
                // rotate mode shows neither (rings only).
                if !viewModel.faceRotateActive {
                    if viewModel.gizmoIsScale {
                        ForEach(axes, id: \.self) { scaleHandle($0, ctx, center: center) }
                    } else {
                        ForEach(axes, id: \.self) { axisArrow($0, ctx) }
                    }
                }
                pivotDot(at: center)
            }
            .allowsHitTesting(false)   // drags are hit-tested in 3D by the viewport
            .ignoresSafeArea()         // full-bleed Metal viewport, inset SwiftUI
        }
    }

    // MARK: - Axis scale grip (square head with a stem trailing to the pivot)

    /// A Shapr3D-style scale grip: a rounded-square head at the axis end with a
    /// thin rectangular stem trailing back toward the centre pivot, so it reads
    /// as "drag me outward/inward to scale". Drawn outline-behind-fill (like the
    /// arrows) so the whole key shape carries one continuous dark outline.
    @ViewBuilder
    private func scaleHandle(_ part: GizmoPart, _ ctx: ProjectionContext, center: CGPoint) -> some View {
        if let shape = Self.handleShape(part, project: ctx.project, scale: true),
           !Self.pivotCovers(shape, center: center) {
            Self.solidHandle(shape, lit: viewModel.litGizmoPart == part)
                .accessibilityIdentifier("GizmoScale-\(part.axisName)")
        }
    }

    /// A Shapr3D-style scale grip: a rounded-square head at the axis end with
    /// a short stem trailing back toward the pivot.
    static func scaleGripPath(tip: CGPoint, center: CGPoint) -> Path {
        let dx = center.x - tip.x, dy = center.y - tip.y
        let len = hypot(dx, dy)
        let ux = len > 0.5 ? dx / len : 0, uy = len > 0.5 ? dy / len : 1
        let head: CGFloat = 20, stem: CGFloat = 15, stemW: CGFloat = 8
        let s0 = CGPoint(x: tip.x + ux * (head / 2 - 3), y: tip.y + uy * (head / 2 - 3))
        let s1 = CGPoint(x: tip.x + ux * (head / 2 + stem), y: tip.y + uy * (head / 2 + stem))
        let stemShape = Path { p in p.move(to: s0); p.addLine(to: s1) }
            .strokedPath(StrokeStyle(lineWidth: stemW, lineCap: .round))
        let headShape = Path(roundedRect: CGRect(x: tip.x - head / 2, y: tip.y - head / 2,
                                                 width: head, height: head),
                             cornerRadius: 5, style: .continuous)
        return stemShape.union(headShape)
    }

    // MARK: - Handle shapes (shared by drawing and the viewport's hit test)

    /// The face of a handle on screen, before its rim: nil when the part
    /// isn't drawn (an arrow pointing at the eye, a plane seen edge-on, a
    /// ring with no visible arc). `scale` picks scale grips over arrows.
    static func handleShape(_ part: GizmoPart, project: (SIMD3<Float>) -> CGPoint?,
                            scale: Bool, eye: SIMD3<Float>? = nil) -> Path? {
        if let eye, !scale || part.isPlane,
           let faces = slabFaces(part, project: project, eye: eye) {
            return faces.dropFirst().reduce(faces.first?.path ?? Path()) { $0.union($1.path) }
        }
        if part.isRing {
            let pts = GizmoScreenLayout.ringPolyline(part, project: project)
            return pts.count >= 3 ? curvedArrowPath(pts) : nil
        }
        if part.isPlane {
            guard let tile = GizmoScreenLayout.visiblePlaneQuads(project: project)
                .first(where: { $0.part == part }) else { return nil }
            let path = Path { p in p.addLines(tile.quad); p.closeSubpath() }
            // Corners rounded outward the way the arrows are.
            return path.union(path.strokedPath(StrokeStyle(lineWidth: 4, lineJoin: .round)))
        }
        guard let tip = GizmoScreenLayout.axisAnchor(part, project: project) else { return nil }
        if scale {
            guard let center = project(.zero) else { return nil }
            return scaleGripPath(tip: tip, center: center)
        }
        guard let base = project(part.axisDirection * (GizmoScreenLayout.armLocal * 0.35)) else { return nil }
        let dx = tip.x - base.x, dy = tip.y - base.y
        let len = hypot(dx, dy)
        guard len > 6 else { return nil }
        return arrowPath(center: tip, direction: CGPoint(x: dx / len, y: dy / len))
    }

    /// Radius of the centre dot.
    static let pivotRadius: CGFloat = 8

    /// Whether the centre dot sits on a handle (with its rim). Orbiting can
    /// swing an arrow or a square behind the centre; Shapr3D hides it then
    /// rather than drawing the dot over it, and it can't be grabbed.
    static func pivotCovers(_ shape: Path, center: CGPoint) -> Bool {
        // The dot overlaps the handle once it reaches into the handle's rim
        // (more than a hairline): at rest the plane squares' inner corners
        // sit a few points clear of it.
        let reach = pivotRadius + rimWidth * 0.5
        if shape.contains(center) { return true }
        for k in 0..<16 {
            let a = CGFloat(k) / 16 * 2 * .pi
            if shape.contains(CGPoint(x: center.x + cos(a) * reach, y: center.y + sin(a) * reach)) {
                return true
            }
        }
        return false
    }

    /// The same test for a part, from the projection alone (the viewport's
    /// hit test asks this, so a hidden handle is never grabbed).
    static func isHiddenByPivot(_ part: GizmoPart, project: (SIMD3<Float>) -> CGPoint?,
                                scale: Bool, eye: SIMD3<Float>? = nil) -> Bool {
        guard let center = project(.zero),
              let shape = handleShape(part, project: project, scale: scale, eye: eye) else { return false }
        return pivotCovers(shape, center: center)
    }

    // MARK: - 3D slabs (plane squares and move arrows)

    /// A world-space eye in the gizmo's own units and axes.
    static func eyeLocal(_ eye: SIMD3<Double>?, origin: SIMD3<Float>, scale: Float,
                         basis: GizmoBasis) -> SIMD3<Float>? {
        guard let eye, scale > 0 else { return nil }
        let world = SIMD3<Float>(Float(eye.x), Float(eye.y), Float(eye.z))
        return basis.local((world - origin) / scale)
    }

    /// One projected face of a slab, ready to paint.
    struct ProjectedFace {
        var path: Path
        var face: GizmoSlab.Face
    }

    /// The slab a square or arrow is drawn as, nil for anything else.
    static func slab(_ part: GizmoPart, eye: SIMD3<Float>) -> GizmoSlab? {
        part.isPlane ? GizmoSlab.square(part) : GizmoSlab.arrow(part, eye: eye)
    }

    /// The faces of a part's slab that turn toward the eye, projected, in
    /// paint order. Nil when the part isn't drawn: a square seen edge-on
    /// (the same rule the hit test uses), an arrow pointing at the eye.
    static func slabFaces(_ part: GizmoPart, project: (SIMD3<Float>) -> CGPoint?,
                          eye: SIMD3<Float>) -> [ProjectedFace]? {
        if part.isPlane {
            guard GizmoScreenLayout.visiblePlaneQuads(project: project).contains(where: { $0.part == part })
            else { return nil }
        } else {
            guard let tip = GizmoScreenLayout.axisAnchor(part, project: project),
                  let base = project(part.axisDirection * (GizmoScreenLayout.armLocal * 0.35)),
                  hypot(tip.x - base.x, tip.y - base.y) > 6 else { return nil }
        }
        guard let slab = slab(part, eye: eye) else { return nil }
        var out: [ProjectedFace] = []
        for face in slab.visibleFaces(eye: eye) {
            var points: [CGPoint] = []
            for p in face.points {
                guard let s = project(p) else { return nil }
                points.append(s)
            }
            out.append(ProjectedFace(path: Path { $0.addLines(points); $0.closeSubpath() }, face: face))
        }
        return out.isEmpty ? nil : out
    }

    /// How brightly a wall is lit: a light fixed to the camera, above and to
    /// the left of the eye, so the two walls you see take different greys.
    static func wallLight(normal: SIMD3<Float>, eye: SIMD3<Float>, at point: SIMD3<Float>,
                          up: SIMD3<Float>) -> Float {
        let back = simd_normalize(eye - point)
        var screenUp = up - back * simd_dot(up, back)
        screenUp = simd_length_squared(screenUp) > 1e-8 ? simd_normalize(screenUp) : SIMD3(0, 1, 0)
        let right = simd_cross(screenUp, back)
        let toward: SIMD3<Float> = back * Float(0.6)
        let above: SIMD3<Float> = screenUp * Float(0.8)
        let left: SIMD3<Float> = right * Float(-0.5)
        let light = simd_normalize(toward + above + left)
        return max(0, simd_dot(normal, light))
    }

    /// A slab painted as Shapr3D's: grey walls (two tones from the light),
    /// then the white top facing you. Blue when lit. No outline or shadow.
    static func slabView(_ faces: [ProjectedFace], lit: Bool, eye: SIMD3<Float>,
                         up: SIMD3<Float>) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(faces.indices, id: \.self) { i in
                faceView(faces[i], lit: lit, eye: eye, up: up)
            }
        }
    }

    /// The colour of one face: the top white (blue when lit), a wall a grey
    /// set by how much it faces the camera's light.
    static func faceColor(_ face: GizmoSlab.Face, lit: Bool, eye: SIMD3<Float>, up: SIMD3<Float>) -> Color {
        if face.isCap {
            return lit ? Color(red: 0.36, green: 0.62, blue: 1.0) : Color(white: 0.96)
        }
        let k = Double(wallLight(normal: face.normal, eye: eye, at: face.centre, up: up))
        if lit {
            return Color(red: 0.10 + 0.12 * k, green: 0.30 + 0.20 * k, blue: 0.70 + 0.20 * k)
        }
        return Color(white: 0.40 + 0.28 * k)
    }

    /// One face filled, with a hairline in its own colour that closes the
    /// seams between neighbouring faces.
    private static func faceView(_ f: ProjectedFace, lit: Bool, eye: SIMD3<Float>, up: SIMD3<Float>) -> some View {
        let color = faceColor(f.face, lit: lit, eye: eye, up: up)
        return ZStack {
            f.path.fill(color)
            f.path.stroke(color, lineWidth: 0.6)
        }
    }

    // MARK: - Solid handle look (Shapr3D: a white slab with grey sides)

    /// Width of the grey rim round every handle's white face.
    static let rimWidth: CGFloat = 2.5

    /// One handle drawn the way Shapr3D's are: a flat white face (blue when
    /// lit) inside an even grey rim — the slab's sides seen round its top —
    /// with no outline, shading or shadow.
    static func solidHandle(_ path: Path, lit: Bool) -> some View {
        let silhouette = path.union(path.strokedPath(StrokeStyle(lineWidth: rimWidth * 2, lineJoin: .round)))
        let box = silhouette.boundingRect.insetBy(dx: -1, dy: -1)
        let dx = -box.minX, dy = -box.minY
        let face = lit ? Color(red: 0.36, green: 0.62, blue: 1.0) : Color(white: 0.95)
        let rim = lit ? Color(red: 0.16, green: 0.40, blue: 0.82) : Color(white: 0.56)
        return ZStack {
            silhouette.offsetBy(dx: dx, dy: dy).fill(rim)
            path.offsetBy(dx: dx, dy: dy).fill(face)
        }
        .frame(width: box.width, height: box.height)
        .position(x: box.midX, y: box.midY)
    }

    // MARK: - Axis translate arrow (flat, outlined — like the extrude handle)

    @ViewBuilder
    private func axisArrow(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        if let eye = ctx.eye,
           let faces = Self.slabFaces(part, project: ctx.project, eye: eye),
           let shape = Self.handleShape(part, project: ctx.project, scale: false, eye: eye),
           let center = ctx.project(.zero), !Self.pivotCovers(shape, center: center),
           let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project),
           let base = ctx.project(part.axisDirection * (GizmoScreenLayout.armLocal * 0.35)) {
            // An axis turning toward the eye fades as it shortens.
            let len = hypot(tip.x - base.x, tip.y - base.y)
            Self.slabView(faces, lit: viewModel.litGizmoPart == part, eye: eye,
                          up: ctx.basis.local(SIMD3(0, 1, 0)))
                .opacity(min(1, Double(len) / 24))
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("GizmoAxis-\(part.axisName)")
                .accessibilityValue(viewModel.litGizmoPart == part ? "lit" : "idle")
        }
    }

    /// A block arrow centred on `center`, pointing along the unit `direction`:
    /// a broad head on a short shaft, corners rounded.
    static func arrowPath(center: CGPoint, direction d: CGPoint) -> Path {
        let headLength: CGFloat = 13, headHalf: CGFloat = 11.5
        let shaftHalf: CGFloat = 4.5, shaftLength: CGFloat = 14
        let total = headLength + shaftLength
        let n = CGPoint(x: -d.y, y: d.x)
        let tip = CGPoint(x: center.x + d.x * total / 2, y: center.y + d.y * total / 2)
        func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + d.x * along + n.x * across, y: tip.y + d.y * along + n.y * across)
        }
        var polygon = Path()
        polygon.addLines([
            pt(0, 0), pt(-headLength, headHalf), pt(-headLength, shaftHalf),
            pt(-total, shaftHalf), pt(-total, -shaftHalf), pt(-headLength, -shaftHalf),
            pt(-headLength, -headHalf),
        ])
        polygon.closeSubpath()
        // Round every corner by the same small radius.
        return polygon.union(polygon.strokedPath(StrokeStyle(lineWidth: 3, lineJoin: .round)))
    }

    // MARK: - Rotation handle (double-headed arrow on a curve)

    /// Project the visible arc of a rotation ring (centred at 45° in the ring
    /// basis, ~66° wide) so the drawn curve follows its on-screen ellipse.
    @ViewBuilder
    private func rotationArc(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        if let shape = Self.handleShape(part, project: ctx.project, scale: false),
           let center = ctx.project(.zero), !Self.pivotCovers(shape, center: center) {
            // A double-ended curved arrow, pushed OUT past the move arrows
            // (radius from GizmoScreenLayout) so it reads as its own control.
            // One shape — band plus both heads — so it has one outline.
            // One accessibility element for the whole handle so the UI suite
            // can read its lit state.
            Self.solidHandle(shape, lit: viewModel.litGizmoPart == part)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("GizmoRing-\(part.axisName)")
                .accessibilityValue(viewModel.litGizmoPart == part ? "lit" : "idle")
        }
    }

    /// A band along `pts` with a triangular arrowhead at each end, as one path.
    static func curvedArrowPath(_ pts: [CGPoint]) -> Path {
        let band = Path { $0.addLines(pts) }
            .strokedPath(StrokeStyle(lineWidth: 6, lineCap: .butt, lineJoin: .round))
        var shape = band
        for (tip, from) in [(pts[0], pts[1]), (pts[pts.count - 1], pts[pts.count - 2])] {
            let dx = tip.x - from.x, dy = tip.y - from.y
            let len = hypot(dx, dy)
            guard len > 0.5 else { continue }
            let ux = dx / len, uy = dy / len
            let nx = -uy, ny = ux
            let size: CGFloat = 13
            // The head starts a little back along the band so they overlap.
            let headTip = CGPoint(x: tip.x + ux * size * 0.55, y: tip.y + uy * size * 0.55)
            let base = CGPoint(x: headTip.x - ux * size, y: headTip.y - uy * size)
            var head = Path()
            head.move(to: headTip)
            head.addLine(to: CGPoint(x: base.x + nx * size * 0.62, y: base.y + ny * size * 0.62))
            head.addLine(to: CGPoint(x: base.x - nx * size * 0.62, y: base.y - ny * size * 0.62))
            head.closeSubpath()
            shape = shape.union(head.union(head.strokedPath(StrokeStyle(lineWidth: 2, lineJoin: .round))))
        }
        return shape
    }

    // MARK: - Plane-move handle (a tile lying IN its plane)

    /// The plane tiles, drawn as the projected quads they actually are: each
    /// square lies in the plane it drags along, so it leans with the model and
    /// tells the user which way it will move (Shapr3D draws them the same way).
    /// A screen-aligned square said nothing about its plane — and worse, it
    /// disagreed with the hit test, which is the quad.
    @ViewBuilder
    private func planeTiles(_ ctx: ProjectionContext) -> some View {
        // Edge-on tiles are dropped here and by the hit test alike, so what is
        // drawn is exactly what is grabbable.
        let tiles = GizmoScreenLayout.visiblePlaneQuads(project: ctx.project)
        let center = ctx.project(.zero)
        let eye = ctx.eye
        ForEach(tiles) { tile in
            if let eye, let center,
               let faces = Self.slabFaces(tile.part, project: ctx.project, eye: eye),
               let shape = Self.handleShape(tile.part, project: ctx.project, scale: false, eye: eye),
               !Self.pivotCovers(shape, center: center) {
                Self.slabView(faces, lit: viewModel.litGizmoPart == tile.part, eye: eye,
                              up: ctx.basis.local(SIMD3(0, 1, 0)))
                    // Fade a tile as it tips toward edge-on, so it never reads
                    // as a crisp target while it is collapsing into a line.
                    .opacity(min(1, Double(tile.area) / 90))
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("GizmoPlane-\(tile.part.axisName)")
            }
        }
    }

    // MARK: - Pivot (tap it to reposition the whole control)

    @ViewBuilder
    private func pivotDot(at p: CGPoint) -> some View {
        if viewModel.gizmoRepositionArmed {
            crosshair(at: p)
        } else {
            ZStack {
                Circle().fill(Color(white: 0.56))
                    .frame(width: Self.pivotRadius * 2, height: Self.pivotRadius * 2)
                Circle().fill(Color(white: 0.95))
                    .frame(width: (Self.pivotRadius - Self.rimWidth) * 2,
                           height: (Self.pivotRadius - Self.rimWidth) * 2)
                Circle().fill(Self.pivot).frame(width: 7, height: 7)
            }
            .position(p)
        }
    }

    /// The armed pivot: a crosshair you drag to drop the gizmo somewhere else
    /// (the bodies stay put). Tapping the centre again puts the dot back.
    @ViewBuilder
    private func crosshair(at p: CGPoint) -> some View {
        let r: CGFloat = 17
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Path { path in
                    if i == 0 {
                        path.move(to: CGPoint(x: p.x - r, y: p.y))
                        path.addLine(to: CGPoint(x: p.x + r, y: p.y))
                    } else {
                        path.move(to: CGPoint(x: p.x, y: p.y - r))
                        path.addLine(to: CGPoint(x: p.x, y: p.y + r))
                    }
                }
                .stroke(Self.reposition, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            Circle().stroke(Self.reposition, lineWidth: 2.5)
                .frame(width: 15, height: 15)
                .position(p)
        }
        .accessibilityIdentifier("GizmoPivotCrosshair")
    }

    private func dbl(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }
}

/// Projects gizmo-local offsets (unit-scale, origin at zero) to screen points.
private struct ProjectionContext {
    let origin: SIMD3<Float>
    let scale: Float
    var basis: GizmoBasis = .world
    let control: any ViewportCameraControl

    /// The camera's eye in gizmo-local units, for the slabs' face culling.
    var eye: SIMD3<Float>? {
        MoveGizmoOverlay.eyeLocal(control.cameraEyePosition, origin: origin, scale: scale, basis: basis)
    }

    func project(_ local: SIMD3<Float>) -> CGPoint? {
        let world = origin + basis.world(local) * scale
        return control.worldToScreenPoint(
            SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }
}
