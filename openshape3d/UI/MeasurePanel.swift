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
    /// A phone (compact width): the panel docks above the bottom bar as a
    /// sheet that collapses to its header, instead of a floating card over
    /// a viewport too narrow to keep it out of the way.
    var compact = false
    /// The bottom bar's height, to dock above it.
    var bottomInset: CGFloat = 0

    /// Where the user dragged the card, from its home under the top edge.
    @AppStorage("os3d.measurePanelOffsetX") private var savedX = 0.0
    @AppStorage("os3d.measurePanelOffsetY") private var savedY = 0.0
    /// The phone sheet is down to its header.
    @AppStorage("os3d.measurePanelCollapsed") private var collapsed = false
    @GestureState private var drag: CGSize = .zero
    /// The phone sheet's readings, measured, so it is no taller than them.
    @State private var contentHeight: CGFloat = 0

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        GeometryReader { proxy in
            if compact {
                sheet(height: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 8)
                    .padding(.bottom, bottomInset)
            } else {
                card
                    .frame(width: min(320, proxy.size.width - 32))
                    .offset(clamped(CGSize(width: savedX + drag.width, height: savedY + drag.height), in: proxy.size))
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 8)
            }
        }
    }

    /// The phone layout: grabber, header, and the readings in a scroll view
    /// no taller than 40 % of the screen, so the model stays in view.
    private func sheet(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { collapsed.toggle() } }
                .accessibilityLabel(collapsed ? "Show measurements" : "Hide measurements")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("MeasurePanelGrabber")
            header
            if !collapsed {
                // As tall as the readings, scrolling only past 40 % of the
                // screen, so the model stays in view above it.
                // A scroll view only once they outgrow that: iOS 26's scroll
                // edge effect fades rows near its top edge, so short lists
                // are drawn plain.
                let measured = contents.background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
                Group {
                    if contentHeight > height * 0.4 {
                        ScrollView { measured }.frame(height: height * 0.4)
                    } else {
                        measured
                    }
                }
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            }
        }
        .padding(14)
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Self.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: -2)
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            // Swipe down to collapse, up to expand.
            if value.translation.height > 30 { withAnimation(.snappy) { collapsed = true } }
            if value.translation.height < -30 { withAnimation(.snappy) { collapsed = false } }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MeasurePanel")
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
            contents
        }
        .padding(14)
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Self.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MeasurePanel")
    }

    /// Deltas switch, readings and pins: the same in both layouts.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Include X, Y, Z Deltas", isOn: Binding(
                get: { viewModel.measureDeltas },
                set: { viewModel.measureDeltas = $0 }))
                .font(.subheadline)
                .accessibilityIdentifier("MeasureDeltasToggle")
            Divider()
            Text("Pin to Always Show").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let picked = viewModel.measurePickSummary {
                Text("Selected: " + picked)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MeasurePickSummary")
            }
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
                    let lit = viewModel.highlightedPinID == pin.id
                    HStack {
                        Text(PinnedMeasurementsOverlay.text(for: viewModel.livePin(pin).pin))
                            .font(.subheadline)
                            .monospacedDigit()
                            .accessibilityIdentifier("PinnedMeasurementValue")
                        Spacer()
                        Button {
                            viewModel.unpinMeasurement(pin.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete")
                        .accessibilityIdentifier("DeletePinnedMeasurement")
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(lit ? Color.orange.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            viewModel.highlightedPinID = pin.id
                        } else if lit {
                            viewModel.highlightedPinID = nil
                        }
                    }
                    .onTapGesture { viewModel.highlightedPinID = lit ? nil : pin.id }
                }
            }
        }
    }

    /// Solid, not a material: over the light viewport a translucent
    /// material turned mid-grey in dark mode and greyed out every caption.
    /// The system background keeps full contrast in light and dark.
    static let fill = Color(uiColor: .systemBackground).opacity(0.97)
    static let border = Color(uiColor: .separator)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
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
                Label {
                    Text(viewModel.measureType.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: viewModel.measureType.icon).foregroundStyle(Color.accentColor)
                }
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
        .gesture(compact ? nil : DragGesture(minimumDistance: 4)
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
        EditorViewModel.formattedReading(value, quantity: quantity)
    }
}
