//
//  MeasurePanel.swift
//  openshape3d
//
//  The Measure panel (spec §16.3): a floating card that
//  stays up while Measure is on and can be dragged anywhere over the
//  viewport. The Measure menu picks the type; "Pin to Always Show" lists the
//  readings for the current picks, each with a Pin; "Pinned" lists what is
//  kept in the model, each with Delete. Hovering a reading (pointer) or
//  tapping it (touch) highlights what it measures.
//

import SwiftUI

struct MeasurePanel: View {
    @Bindable var viewModel: EditorViewModel

    /// Where the user dragged the card, from its home under the top edge.
    @AppStorage("os3d.measurePanelOffsetX") private var savedX = 0.0
    @AppStorage("os3d.measurePanelOffsetY") private var savedY = 0.0
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            card
                .frame(width: min(320, proxy.size.width - 32))
                .offset(clamped(CGSize(width: savedX + drag.width, height: savedY + drag.height), in: proxy.size))
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 8)
        }
    }

    /// Keep at least the header on screen.
    private func clamped(_ offset: CGSize, in size: CGSize) -> CGSize {
        let half = max(0, (size.width - 160) / 2)
        return CGSize(width: min(max(offset.width, -half), half),
                      height: min(max(offset.height, 0), max(0, size.height - 80)))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Toggle("Include X, Y, Z Deltas", isOn: Binding(
                get: { viewModel.measureDeltas },
                set: { viewModel.measureDeltas = $0 }))
                .font(.subheadline)
                .accessibilityIdentifier("MeasureDeltasToggle")
            Divider()
            Text("Pin to Always Show").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if viewModel.measureRows.isEmpty {
                Text(viewModel.measurePrompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MeasurePrompt")
            } else {
                ForEach(viewModel.measureRows) { row in
                    readingRow(row)
                }
            }
            let pins = viewModel.session.document.pinnedMeasurements
            if !pins.isEmpty {
                Divider()
                Text("Pinned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(pins) { pin in
                    HStack {
                        Text(PinnedMeasurementsOverlay.text(for: pin))
                            .font(.subheadline)
                            .monospacedDigit()
                        Spacer()
                        Button {
                            viewModel.unpinMeasurement(pin.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete")
                        .accessibilityIdentifier("DeletePinnedMeasurement")
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MeasurePanel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Menu {
                ForEach(EditorViewModel.MeasureType.allCases, id: \.self) { type in
                    Button {
                        viewModel.measureType = type
                    } label: {
                        Label(type.title, systemImage: type.icon)
                    }
                    .accessibilityIdentifier("MeasureType-" + type.rawValue)
                }
            } label: {
                Label(viewModel.measureType.title, systemImage: viewModel.measureType.icon)
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("MeasureTypeMenu")
            Spacer()
            Button {
                viewModel.exitMeasure()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("CloseMeasure")
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                savedX += value.translation.width
                savedY += value.translation.height
            })
    }

    private func readingRow(_ row: MeasureRow) -> some View {
        let highlighted = viewModel.highlightedMeasureRow == row.kind
        return HStack {
            Text(row.title).font(.subheadline)
            Spacer()
            Text(Self.text(for: row))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityIdentifier(Self.valueID(for: row, type: viewModel.measureType))
            Button {
                viewModel.pinMeasurement(row)
            } label: {
                Image(systemName: "pin")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Pin")
            .accessibilityIdentifier("PinMeasurement")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(highlighted ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                viewModel.highlightedMeasureRow = row.kind
            } else if viewModel.highlightedMeasureRow == row.kind {
                viewModel.highlightedMeasureRow = nil
            }
        }
        .onTapGesture {
            viewModel.highlightedMeasureRow = highlighted ? nil : row.kind
        }
    }

    /// The UI tests' long-standing ids for a two-point distance and a
    /// three-point angle; every other reading by its kind.
    static func valueID(for row: MeasureRow, type: EditorViewModel.MeasureType) -> String {
        switch (type, row.kind) {
        case (.pointToPoint, .distance): return "MeasureDistanceValue"
        case (.threePointAngle, .angle): return "MeasureAngleValue"
        default: return "MeasureValue-" + row.kind.rawValue
        }
    }

    static func text(for row: MeasureRow) -> String {
        text(value: row.value, quantity: row.quantity)
    }

    static func text(value: Double, quantity: MeasureRow.Quantity) -> String {
        switch quantity {
        case .length: return EditorViewModel.formattedLength(value)
        case .angle: return EditorViewModel.formattedAngle(value)
        case .area: return EditorViewModel.formattedArea(value)
        case .volume: return EditorViewModel.formattedVolume(value)
        }
    }
}
