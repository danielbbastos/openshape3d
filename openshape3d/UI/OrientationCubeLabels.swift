//
//  OrientationCubeLabels.swift
//  openshape3d
//
//  Standard-view names drawn over the orientation cube (spec §7.2). The cube
//  itself is Metal; the names ride above it as SwiftUI text, which keeps them
//  crisp at any size and avoids a glyph atlas in the render pass for six words.
//
//  Only faces turned toward the camera are named, fading out as they rotate
//  away — the cube stays readable instead of becoming a wall of text, and every
//  visible name is a face you can actually tap to snap to.
//

import SwiftUI

struct OrientationCubeLabels: View {
    @Bindable var viewModel: EditorViewModel

    static func axisColor(_ name: String) -> Color {
        switch name {
        case "X": Color(red: 0.92, green: 0.36, blue: 0.36)
        case "Y": Color(red: 0.36, green: 0.78, blue: 0.40)
        default: Color(red: 0.35, green: 0.55, blue: 0.98)
        }
    }

    var body: some View {
        // Re-project as the camera turns.
        let _ = viewModel.cameraEpoch
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.cameraControl?.orientationCubeLabels() ?? []) { label in
                Text(label.name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.5), radius: 0.5)
                    .opacity(label.opacity)
                    .position(label.point)
            }
            // The tripod's letters, in the axis colours.
            ForEach(viewModel.cameraControl?.orientationCubeAxisLabels() ?? []) { label in
                Text(label.name)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.axisColor(label.name))
                    .opacity(label.opacity)
                    .position(label.point)
            }
        }
        // The cube's own tap/drag handling lives in the viewport; the names
        // must not intercept either.
        .allowsHitTesting(false)
        // The Metal viewport is full-bleed while a SwiftUI overlay is
        // safe-area inset by default; without this every projected point lands
        // ~85pt below the geometry it annotates.
        .ignoresSafeArea()
    }
}

/// Spin arrows under the orientation cube while a cube face or named view is
/// up (spec §7.2): each turns the plane 90° about the line of sight.
struct OrientationCubeSpinArrows: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        if viewModel.canSpinPlaneView {
            GeometryReader { proxy in
                let cube = OrientationCube.rect(in: proxy.size)
                HStack(spacing: 18) {
                    arrow("arrow.counterclockwise", "Spin View Left", "SpinViewLeft", clockwise: false)
                    arrow("arrow.clockwise", "Spin View Right", "SpinViewRight", clockwise: true)
                }
                .position(x: cube.midX, y: cube.maxY + 16)
            }
            // Same frame as the Metal viewport (see `OrientationCubeLabels`).
            .ignoresSafeArea()
        }
    }

    private func arrow(_ icon: String, _ label: String, _ id: String, clockwise: Bool) -> some View {
        Button {
            viewModel.spinPlaneView(clockwise: clockwise)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
