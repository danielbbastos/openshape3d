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
        if let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project) {
            // Direction from the head back toward the pivot; fall back to a fixed
            // heading if the head sits on top of the pivot (degenerate).
            let dx = center.x - tip.x, dy = center.y - tip.y
            let len = hypot(dx, dy)
            let ux = len > 0.5 ? dx / len : 0, uy = len > 0.5 ? dy / len : 1
            let head: CGFloat = 20, stem: CGFloat = 15, stemW: CGFloat = 8
            // Stem runs from just inside the head toward the pivot.
            let s0 = CGPoint(x: tip.x + ux * (head / 2 - 3), y: tip.y + uy * (head / 2 - 3))
            let s1 = CGPoint(x: tip.x + ux * (head / 2 + stem), y: tip.y + uy * (head / 2 + stem))
            let stemShape = stemPath(s0, s1).strokedPath(StrokeStyle(lineWidth: stemW, lineCap: .round))
            let headShape = Path(roundedRect: CGRect(x: tip.x - head / 2, y: tip.y - head / 2,
                                                     width: head, height: head),
                                 cornerRadius: 5, style: .continuous)
            Self.solidHandle(stemShape.union(headShape), lit: viewModel.litGizmoPart == part)
                .accessibilityIdentifier("GizmoScale-\(part.axisName)")
        }
    }

    // MARK: - Solid handle look (Shapr3D: a white slab with grey sides)

    /// The depth arrows, rings and scale grips show: their side falls a
    /// little below and right of the face, as if lit from the top left.
    static let slabDepth = CGSize(width: 1.5, height: 3.5)

    /// One handle drawn as a thin 3D slab, the way Shapr3D's are: the face is
    /// flat white (blue when lit), the side — the same shape pushed back by
    /// `depth` — is grey, and one thin dark line runs round the silhouette.
    /// No shading on the face and no drop shadow: the sides are what make it
    /// read as solid.
    static func solidHandle(_ path: Path, lit: Bool, depth: CGSize = slabDepth) -> some View {
        let side = extrusion(of: path, depth: depth)
        let silhouette = side.union(path)
        let box = silhouette.boundingRect.insetBy(dx: -2, dy: -2)
        let dx = -box.minX, dy = -box.minY
        let face = lit ? Color(red: 0.36, green: 0.62, blue: 1.0) : Color(white: 0.98)
        let sides = lit ? Color(red: 0.12, green: 0.36, blue: 0.80) : Color(white: 0.60)
        return ZStack {
            silhouette.offsetBy(dx: dx, dy: dy).fill(sides)
            path.offsetBy(dx: dx, dy: dy).fill(face)
            // Where the face meets its side.
            path.offsetBy(dx: dx, dy: dy)
                .stroke(Color(white: lit ? 0.10 : 0.42), style: StrokeStyle(lineWidth: 0.7, lineJoin: .round))
            silhouette.offsetBy(dx: dx, dy: dy)
                .stroke(Color(white: 0.12), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
        }
        .frame(width: box.width, height: box.height)
        .position(x: box.midX, y: box.midY)
    }

    /// The volume `path` sweeps when pushed back by `depth`: copies every
    /// point along the way, unioned, so the sides join the face with no gap.
    static func extrusion(of path: Path, depth: CGSize) -> Path {
        let length = hypot(depth.width, depth.height)
        guard length > 0.25 else { return path }
        let steps = max(1, Int(length.rounded(.up)))
        var swept = path
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            swept = swept.union(path.offsetBy(dx: depth.width * t, dy: depth.height * t))
        }
        return swept
    }

    /// A plane tile's thickness on screen: its plane normal projected, so a
    /// tile seen face-on shows no side and one tipped away shows more. The
    /// sign is chosen so the side falls below the face, like the arrows'.
    static func tileDepth(normal: SIMD3<Float>, project: (SIMD3<Float>) -> CGPoint?) -> CGSize {
        let thickness = GizmoScreenLayout.armLocal * 0.07
        guard let o = project(.zero), let n = project(normal * thickness) else { return slabDepth }
        var d = CGSize(width: n.x - o.x, height: n.y - o.y)
        if d.height < 0 || (abs(d.height) < 0.01 && d.width < 0) { d = CGSize(width: -d.width, height: -d.height) }
        // Never thinner than a hairline nor thicker than the arrows look.
        let length = hypot(d.width, d.height)
        if length > 5 { d = CGSize(width: d.width * 5 / length, height: d.height * 5 / length) }
        return d
    }

    private func stemPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        Path { p in p.move(to: a); p.addLine(to: b) }
    }

    // MARK: - Axis translate arrow (flat, outlined — like the extrude handle)

    @ViewBuilder
    private func axisArrow(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        let axis = part.axisDirection
        if let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project),
           let base = ctx.project(axis * (GizmoScreenLayout.armLocal * 0.35)) {
            let dx = tip.x - base.x, dy = tip.y - base.y
            let len = hypot(dx, dy)
            // Fade an axis that points nearly into/out of the screen (its arrow
            // would be a foreshortened smear); it is still draggable in 3D.
            if len > 6 {
                Self.solidHandle(Self.arrowPath(center: tip, direction: CGPoint(x: dx / len, y: dy / len)),
                                 lit: viewModel.litGizmoPart == part)
                    .opacity(min(1, Double(len) / 24))
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("GizmoAxis-\(part.axisName)")
                    .accessibilityValue(viewModel.litGizmoPart == part ? "lit" : "idle")
            }
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
        let pts = GizmoScreenLayout.ringPolyline(part, project: ctx.project)
        if pts.count >= 3 {
            // A double-ended curved arrow, pushed OUT past the move arrows
            // (radius from GizmoScreenLayout) so it reads as its own control.
            // One shape — band plus both heads — so it has one outline.
            // One accessibility element for the whole handle so the UI suite
            // can read its lit state.
            Self.solidHandle(Self.curvedArrowPath(pts), lit: viewModel.litGizmoPart == part)
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
        ForEach(tiles) { tile in
            planeTile(tile.part, quad: tile.quad, area: tile.area,
                      depth: Self.tileDepth(normal: tile.part.axisDirection, project: ctx.project))
        }
    }

    @ViewBuilder
    private func planeTile(_ part: GizmoPart, quad: [CGPoint], area: CGFloat, depth: CGSize) -> some View {
        let path = Path { p in
            p.addLines(quad)
            p.closeSubpath()
        }
        // Corners rounded outward the way the arrows are.
        let rounded = path.union(path.strokedPath(StrokeStyle(lineWidth: 4, lineJoin: .round)))
        Self.solidHandle(rounded, lit: viewModel.litGizmoPart == part, depth: depth)
            // Fade a tile as it tips toward edge-on, so it never reads as a
            // crisp target while it is collapsing into a line.
            .opacity(min(1, Double(area) / 90))
            .accessibilityIdentifier("GizmoPlane-\(part.axisName)")
    }

    // MARK: - Pivot (tap it to reposition the whole control)

    @ViewBuilder
    private func pivotDot(at p: CGPoint) -> some View {
        if viewModel.gizmoRepositionArmed {
            crosshair(at: p)
        } else {
            ZStack {
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color(white: 0.13), lineWidth: 1.2))
                    .frame(width: 16, height: 16)
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

    func project(_ local: SIMD3<Float>) -> CGPoint? {
        let world = origin + basis.world(local) * scale
        return control.worldToScreenPoint(
            SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }
}
