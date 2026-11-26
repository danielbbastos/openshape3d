//
//  PinnedMeasurementsOverlay.swift
//  openshape3d
//
//  Labels for pinned measurements (spec §16.3, "Pin to Always Show"): each
//  reading rides its span's midpoint or sits inside its angle. In Measure
//  mode every label carries an ✕ that unpins it.
//

import SwiftUI
import simd

struct PinnedMeasurementsOverlay: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        let pins = viewModel.showPinnedMeasurements ? viewModel.session.document.pinnedMeasurements : []
        let measuring: Bool = { if case .measuring = viewModel.mode { return true }; return false }()
        // As each reads now: a pin measures its items again when the model
        // changes (`EditorViewModel.livePin`).
        let live = pins.map { viewModel.livePin($0).pin }
        let anchors = live.map { viewModel.cameraControl?.worldToScreenPoint($0.labelAnchor) }
        let texts = live.map(Self.text(for:))
        // Placed one by one: a label that would cover an earlier one moves
        // down until it is clear, so readings at one spot stay readable.
        let sizes = texts.map { Self.estimatedSize(of: $0, withUnpin: measuring) }
        let positions = Self.layOut(anchors: anchors, sizes: sizes)
        ZStack {
            ForEach(Array(live.enumerated()), id: \.element.id) { index, pin in
                if let position = positions[index] {
                    HStack(spacing: 4) {
                        Text(texts[index])
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        if measuring {
                            Button {
                                viewModel.unpinMeasurement(pin.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Unpin")
                            .accessibilityIdentifier("UnpinMeasurement")
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    // Dark text on a solid label with the measure-blue rim:
                    // blue on a translucent material read blue-on-blue.
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.blue, lineWidth: 1.5))
                    .foregroundStyle(.primary)
                    .position(position)
                    .allowsHitTesting(measuring)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("PinnedMeasurement")
                }
            }
        }
        // `worldToScreenPoint` is in full-screen coordinates (see MoveDistanceOverlay).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// A label's size before it is drawn: caption digits are about 7 pt
    /// wide; padding, the rim and the unpin button on top.
    static func estimatedSize(of text: String, withUnpin: Bool) -> CGSize {
        CGSize(width: CGFloat(text.count) * 7 + 16 + (withUnpin ? 20 : 0), height: 24)
    }

    /// Label centres, in order: each at its anchor, or moved down past any
    /// earlier label it would cover. Nil where the anchor is off screen.
    nonisolated static func layOut(anchors: [CGPoint?], sizes: [CGSize]) -> [CGPoint?] {
        var placed: [CGRect] = []
        var out: [CGPoint?] = []
        for (anchor, size) in zip(anchors, sizes) {
            guard let anchor else { out.append(nil); continue }
            var center = anchor
            func frame(_ c: CGPoint) -> CGRect {
                CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            }
            // At most a few steps: enough for a stack of readings.
            for _ in 0..<12 {
                guard let hit = placed.first(where: { $0.insetBy(dx: -2, dy: -2).intersects(frame(center)) }) else { break }
                center.y = hit.maxY + 4 + size.height / 2
            }
            placed.append(frame(center))
            out.append(center)
        }
        return out
    }

    static func text(for pin: PinnedMeasurement) -> String {
        switch pin.kind {
        case .distance: return EditorViewModel.formattedLength(pin.value)
        case .angle: return EditorViewModel.formattedAngle(pin.value)
        case .row:
            let value = MeasurePanel.text(value: pin.value, quantity: pin.quantity ?? .length)
            return pin.rowTitle.map { "\($0) \(value)" } ?? value
        }
    }
}
