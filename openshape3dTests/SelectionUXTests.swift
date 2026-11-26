//
//  SelectionUXTests.swift
//  openshape3dTests
//
//  Selection UX (plan §B13 UI, spec §8.2–8.3): select-mode toggle + marquee
//  lifecycle, the Bodies | Sketches filter chips, multi-selection info-bar
//  rows (count + combined bounds), and Select Through candidate routing.
//

import XCTest
import SwiftData
import simd
import Euclid
@testable import openshape3d

@MainActor
final class SelectionUXTests: XCTestCase {

    /// See SelectionTests.retainedViewModels: MainActor class dealloc inside
    /// an XCTest invocation crashes the simulator runtime, so view models
    /// leak deliberately.
    private static var retainedViewModels: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self,
            PersistedBody.self,
            PersistedSketch.self,
            PersistedPlane.self,
            PersistedImage.self,
            PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "Selection UX Test")
        context.insert(project)
        let viewModel = EditorViewModel(project: project, modelContext: context)
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    @discardableResult
    private func addBox(
        to viewModel: EditorViewModel, name: String, at translation: SIMD3<Double>
    ) -> Body {
        var transform = Transform3D.identity
        transform.translation = translation
        var document = viewModel.session.document // nextRevision is mutating
        let body = Body(
            name: name,
            transform: transform,
            euclidMesh: .primitive(.box(width: 2, depth: 2, height: 2)),
            revision: document.nextRevision()
        )
        viewModel.session.perform(AddBodyCommand(body: body))
        return body
    }

    /// Top-down orthographic mock projection: screen = world (x, z).
    private let topDownProject: (SIMD3<Float>) -> SIMD2<Double>? = {
        SIMD2(Double($0.x), Double($0.z))
    }

    // MARK: - Filter (AreaSelect + chips)

    func testSketchEntitiesOnlyFilterSkipsBodies() {
        let body = BodyID()
        let entity = UUID()
        let candidates = [
            AreaSelectCandidate(item: .body(body), points: [SIMD3(1, 1, 0)]),
            AreaSelectCandidate(item: .sketchEntity(entity), points: [SIMD3(2, 2, 0)]),
        ]
        let items = AreaSelect.select(
            candidates: candidates,
            dragStart: SIMD2(0, 0), dragEnd: SIMD2(10, 10),
            filter: .sketchEntitiesOnly,
            project: { SIMD2(Double($0.x), Double($0.y)) }
        )
        XCTAssertEqual(items, [.sketchEntity(entity)])
    }

    func testFilterChipsMapToFilterAndKeepOneKindOn() throws {
        let viewModel = try makeViewModel()
        XCTAssertEqual(viewModel.areaSelectFilter, .bodiesAndSketchEntities)

        viewModel.toggleAreaSelectSketches()
        XCTAssertEqual(viewModel.areaSelectFilter, .bodiesOnly)

        // Turning Bodies off while Sketches is off would leave nothing — the
        // toggle refuses.
        viewModel.toggleAreaSelectBodies()
        XCTAssertTrue(viewModel.areaSelectIncludesBodies)
        XCTAssertEqual(viewModel.areaSelectFilter, .bodiesOnly)

        viewModel.toggleAreaSelectSketches()
        viewModel.toggleAreaSelectBodies()
        XCTAssertEqual(viewModel.areaSelectFilter, .sketchEntitiesOnly)
    }

    // MARK: - Select mode + marquee lifecycle

    func testSelectModeMarqueeSelectsAdditively() throws {
        let viewModel = try makeViewModel()
        let a = addBox(to: viewModel, name: "A", at: .zero)          // x,z ∈ [-1, 1]
        let b = addBox(to: viewModel, name: "B", at: SIMD3(10, 0, 0)) // x ∈ [9, 11]

        // Outside select mode a drag never becomes a marquee.
        XCTAssertFalse(viewModel.beginMarquee(at: SIMD2(0, 0)))

        viewModel.toggleSelectMode()
        XCTAssertTrue(viewModel.selectModeActive)
        XCTAssertTrue(viewModel.selectionAdditive)

        // Window (L→R) marquee around A.
        XCTAssertTrue(viewModel.beginMarquee(at: SIMD2(-2, -2)))
        viewModel.updateMarquee(to: SIMD2(2, 2))
        XCTAssertEqual(viewModel.marqueeState?.isWindow, true)
        viewModel.endMarquee(project: topDownProject)
        XCTAssertNil(viewModel.marqueeState)
        XCTAssertEqual(viewModel.selection, [a.id])

        // Crossing (R→L) marquee over B adds to the selection (additive).
        XCTAssertTrue(viewModel.beginMarquee(at: SIMD2(12, 2)))
        viewModel.updateMarquee(to: SIMD2(8, -2))
        XCTAssertEqual(viewModel.marqueeState?.isWindow, false)
        viewModel.endMarquee(project: topDownProject)
        XCTAssertEqual(viewModel.selection, [a.id, b.id])

        viewModel.exitSelectMode()
        XCTAssertFalse(viewModel.selectModeActive)
        XCTAssertFalse(viewModel.selectionAdditive)
        XCTAssertNil(viewModel.marqueeState)
        // The selection survives leaving select mode.
        XCTAssertEqual(viewModel.selection, [a.id, b.id])
    }

    func testMarqueeIsRefusedWhileAToolOwnsInput() throws {
        let viewModel = try makeViewModel()
        addBox(to: viewModel, name: "A", at: .zero)
        viewModel.toggleSelectMode()
        viewModel.toggleMeasure() // .measuring is not a passive mode
        XCTAssertFalse(viewModel.beginMarquee(at: SIMD2(0, 0)))
    }

    // MARK: - Multi-selection info bar

    func testMultiSelectionMeasurementsShowCountAndCombinedBounds() throws {
        let viewModel = try makeViewModel()
        let a = addBox(to: viewModel, name: "A", at: .zero)
        let b = addBox(to: viewModel, name: "B", at: SIMD3(10, 0, 0))

        viewModel.toggleSelection(of: a.id)
        viewModel.toggleSelection(of: b.id)

        let rows = viewModel.selectionMeasurements
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].label, "Selected")
        XCTAssertEqual(rows[0].value, "2 bodies")
        XCTAssertEqual(rows[1].label, "Bounds")
        // Combined AABB: x -1…11, y 0…2, z -1…1.
        XCTAssertEqual(rows[1].value, "12.00 × 2.00 × 2.00 mm")
        // Two bodies also read how far apart they are: 2 mm cubes
        // 10 mm apart centre to centre leave an 8 mm gap.
        XCTAssertEqual(rows[2].label, "Minimum distance")
        XCTAssertEqual(rows[2].value, "8.00 mm")
        XCTAssertEqual(rows[3].label, "Central distance")
        XCTAssertEqual(rows[3].value, "10.00 mm")
    }

    // MARK: - Select Through

    func testBodyRenameHistoryClearsSelectionWithoutChangingGeometry() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Original", at: .zero)
        vm.selectItemBody(body.id)
        vm.renameItem(.body(body.id), to: "part24")
        XCTAssertEqual(vm.selection, [body.id])
        vm.undo()
        XCTAssertEqual(vm.session.document.body(with: body.id)?.name, "Original")
        XCTAssertTrue(vm.selection.isEmpty)
        XCTAssertEqual(vm.mode, .idle)
        vm.selectItemBody(body.id)
        vm.redo()
        XCTAssertEqual(vm.session.document.body(with: body.id)?.name, "part24")
        XCTAssertTrue(vm.selection.isEmpty)
        XCTAssertEqual(vm.mode, .idle)
        XCTAssertEqual(vm.session.document.bodies.count, 1)
        XCTAssertEqual(vm.session.document.body(with: body.id)?.transform, body.transform)
    }

    func testSelectThroughIncludesFrontAndBackFacesAlongsideBody() throws {
        let viewModel = try makeViewModel()
        addBox(to: viewModel, name: "Layered Box", at: .zero)
        viewModel.presentSelectThrough(ray: Ray(
            origin: SIMD3(0.2, 20, 0.3), direction: SIMD3(0, -1, 0)))
        let candidates = try XCTUnwrap(viewModel.selectThroughCandidates)
        XCTAssertEqual(candidates.filter { $0.name == "Layered Box" }.count, 1)
        XCTAssertEqual(candidates.filter { $0.name.hasPrefix("Face") }.count, 2,
                       "Select Through must expose front and back faces, not only the body")
    }

    func testSelectThroughFaceAndOccludedProfileChoicesDoNotEditGeometry() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Solid", at: .zero)
        let sketch = Sketch(name: "Base", plane: .ground,
                            entities: [.circle(id: UUID(), center: .zero, radius: 0.8)])
        vm.session.perform(AddSketchCommand(sketch: sketch))
        let ray = Ray(origin: SIMD3(0.2, 20, 0.3), direction: SIMD3(0, -1, 0))
        vm.presentSelectThrough(ray: ray)
        let choices = try XCTUnwrap(vm.selectThroughCandidates)
        let faces = choices.filter { if case .face = $0.target { return true }; return false }
        XCTAssertEqual(faces.count, 2)
        for (index, face) in faces.enumerated() {
            vm.chooseSelectThrough(face)
            XCTAssertEqual(vm.mode, .faceSelected(body.id))
            XCTAssertEqual(vm.toolContext?.sourceBody, body.id)
            XCTAssertEqual(try XCTUnwrap(vm.toolContext).plane.origin.y,
                           index == 0 ? 2 : 0, accuracy: 1e-6)
        }
        let profile = try XCTUnwrap(choices.first { if case .profile = $0.target { return true }; return false })
        vm.chooseSelectThrough(profile)
        XCTAssertEqual(vm.mode, .extruding)
        XCTAssertEqual(vm.toolContext?.sketchID, sketch.id)
        XCTAssertNil(vm.toolContext?.sourceBody)
        XCTAssertEqual(vm.session.document.bodies.count, 1)
        XCTAssertEqual(vm.session.document.sketches.first?.entities, sketch.entities)
        vm.cancelTool()
        XCTAssertEqual(vm.session.document.bodies.count, 1)
        vm.setItemHidden(.sketch(sketch.id), hidden: true)
        vm.presentSelectThrough(ray: ray)
        XCTAssertFalse(try XCTUnwrap(vm.selectThroughCandidates).contains {
            if case .profile = $0.target { return true }; return false
        })
        vm.chooseSelectThrough(profile) // stale hidden profile cannot arm extrusion
        XCTAssertNotEqual(vm.mode, .extruding)
        XCTAssertEqual(vm.session.document.bodies.count, 1)
    }

    func testSelectThroughListsHitsFrontToBackAndChoosingSelects() throws {
        let viewModel = try makeViewModel()
        let near = addBox(to: viewModel, name: "Near", at: SIMD3(0, 5, 0)) // y 5…7
        let far = addBox(to: viewModel, name: "Far", at: .zero)            // y 0…2

        // Ray straight down through both boxes.
        let ray = Ray(origin: SIMD3(0, 20, 0), direction: SIMD3(0, -1, 0))
        viewModel.presentSelectThrough(ray: ray)
        let candidates = try XCTUnwrap(viewModel.selectThroughCandidates)
        XCTAssertEqual(candidates.filter(\.isBody).map(\.name), ["Near", "Far"])

        viewModel.chooseSelectThrough(far.id)
        XCTAssertNil(viewModel.selectThroughCandidates)
        XCTAssertEqual(viewModel.selection, [far.id])
        XCTAssertEqual(viewModel.mode, .selected(far.id))

        // Additive (select mode): choosing the other body extends.
        viewModel.toggleSelectMode()
        viewModel.presentSelectThrough(ray: ray)
        viewModel.chooseSelectThrough(near.id)
        XCTAssertEqual(viewModel.selection, [far.id, near.id])
    }

    /// Active tools keep their long-presses: no popup while measuring.
    func testSelectThroughIsRefusedWhileAToolOwnsInput() throws {
        let viewModel = try makeViewModel()
        addBox(to: viewModel, name: "A", at: .zero)
        viewModel.toggleMeasure()
        viewModel.presentSelectThrough(
            ray: Ray(origin: SIMD3(0, 20, 0), direction: SIMD3(0, -1, 0))
        )
        XCTAssertNil(viewModel.selectThroughCandidates)
    }

    // MARK: - Items plane selection

    /// Shapr3D: a plane's Items row selects the plane and Sketch then starts
    /// on it directly (QA-01; the row used to be a no-op).
    func testItemsPlaneRowSelectsPlaneAndSketchStartsOnIt() throws {
        let vm = try makeViewModel()
        let plane = ConstructionPlane(plane: .offsetGround(y: 5), size: 20)
        vm.session.perform(AddConstructionPlaneCommand(plane: plane))

        vm.selectItemPlane(plane.id)
        XCTAssertEqual(vm.selectedPlane?.id, plane.id)
        XCTAssertEqual(vm.mode, .idle)
        // Info bar reads "1 plane" (Shapr3D) while the plane is selected.
        XCTAssertEqual(vm.selectionMeasurements.map { "\($0.label): \($0.value)" },
                       ["Selected: 1 plane"])

        vm.startSketch(tool: .line)
        guard case .sketching(_, let tool) = vm.mode else {
            return XCTFail("Sketch with a selected plane should enter a sketch, got \(vm.mode)")
        }
        XCTAssertEqual(tool, .line)
        XCTAssertEqual(vm.activeSketch?.plane, plane.plane)
        XCTAssertNil(vm.selectedPlaneID)
        XCTAssertFalse(vm.selectionMeasurements.contains { $0.value == "1 plane" })
    }

    func testItemsPlaneSelectionYieldsToBodiesDeleteAndUndo() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Box", at: .zero)
        let plane = ConstructionPlane(plane: .offsetGround(y: 5), size: 20)
        vm.session.perform(AddConstructionPlaneCommand(plane: plane))

        // Selecting a body replaces the plane selection, and a later Sketch
        // falls back to the plane picker.
        vm.selectItemPlane(plane.id)
        vm.selectItemBody(body.id)
        XCTAssertNil(vm.selectedPlaneID)
        vm.cancelTool()
        vm.selection.removeAll()
        vm.mode = .idle
        vm.startSketch(tool: .line)
        XCTAssertEqual(vm.mode, .pickingSketchPlane(tool: .line))
        vm.cancelPlanePicking()

        // Delete removes only the selected plane; undo restores it unselected.
        vm.selectItemPlane(plane.id)
        vm.deleteSelection()
        XCTAssertTrue(vm.session.document.planes.isEmpty)
        XCTAssertEqual(vm.session.document.bodies.map(\.id), [body.id])
        XCTAssertNil(vm.selectedPlaneID)
        vm.undo()
        XCTAssertEqual(vm.session.document.planes.map(\.id), [plane.id])
        XCTAssertNil(vm.selectedPlane)

        // Undoing the plane away drops a stale selection.
        vm.selectItemPlane(plane.id)
        vm.undo()
        XCTAssertTrue(vm.session.document.planes.isEmpty)
        XCTAssertNil(vm.selectedPlaneID)
    }

    // MARK: - Two parallel lines read their distance (QA-29)

    /// Shapr3D's info bar for two selected parallel lines adds the distance
    /// between them ("2 edges  279,925.293 mm  22,558.0444 mm", 2026-09-13);
    /// no per-entity dimension labels are drawn for a multi-selection there
    /// or here, so crowded labels cannot occur.
    func testTwoParallelLinesReadTheirDistance() throws {
        let vm = try makeViewModel()
        let a = UUID(), b = UUID(), c = UUID()
        let sketch = Sketch(name: "Crowd", plane: .ground, entities: [
            .line(id: a, a: SIMD2(-3, 0), b: SIMD2(3, 0)),
            .line(id: b, a: SIMD2(-3, -0.3), b: SIMD2(3, -0.3)),
            .line(id: c, a: SIMD2(0, 1), b: SIMD2(2, 3)),
        ])
        vm.session.perform(AddSketchCommand(sketch: sketch))
        vm.mode = .sketching(sketch.id, tool: nil)
        vm.selectedSketchEntityIDs = [a, b]
        let rows = vm.selectionMeasurements
        XCTAssertEqual(rows.first { $0.label == "Total Length" }?.value, "12.00 mm")
        XCTAssertEqual(rows.first { $0.label == "Distance" }?.value, "0.30 mm")
        let labels = vm.sketchDimensionLabels
        XCTAssertFalse(labels.contains { $0.isStandaloneLineLength },
                       "no per-entity length labels for a multi-selection: \(labels.map { ($0.kind, $0.text) })")
        XCTAssertLessThanOrEqual(labels.count, 1, "at most the pair's own distance candidate")
        vm.selectedSketchEntityIDs = [a, c]
        XCTAssertNil(vm.selectionMeasurements.first { $0.label == "Distance" }, "not parallel")
        vm.selectedSketchEntityIDs = [a]
        XCTAssertEqual(vm.selectionMeasurements.first { $0.label == "Length" }?.value, "6.00 mm")
        XCTAssertNil(vm.selectionMeasurements.first { $0.label == "Distance" })
    }

    // MARK: - Named views while sketching (QA-03)

    /// Shapr3D: a named view that is not the sketch's head-on view (or its
    /// underside) ends the sketch; its own head-on views keep it.
    func testNamedViewEndsSketchUnlessHeadOn() throws {
        let vm = try makeViewModel()

        // Ground sketch: Top/Bottom keep it, Front/Isometric end it.
        vm.startSketch(tool: .line)
        vm.handle(.tap(ray: Ray(origin: SIMD3(50, 10, 50), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(vm.activeSketch?.plane, .ground)
        vm.applyStandardView(.top)
        XCTAssertTrue(vm.mode.isSketching, "Top is the ground sketch's own view")
        vm.applyStandardView(.bottom)
        XCTAssertTrue(vm.mode.isSketching, "Bottom looks at the ground sketch from beneath")
        vm.applyStandardView(.front)
        XCTAssertEqual(vm.mode, .idle, "Front is edge-on to a ground sketch: the sketch ends")
        XCTAssertTrue(vm.session.document.sketches.isEmpty, "The empty sketch is discarded")

        vm.startSketch(tool: .line)
        vm.handle(.tap(ray: Ray(origin: SIMD3(50, 10, 50), direction: SIMD3(0, -1, 0))))
        vm.applyStandardView(.isometric)
        XCTAssertEqual(vm.mode, .idle, "The oblique home view ends the sketch")

        // Front-plane sketch: Front/Back keep it, Top ends it.
        vm.session.perform(AddConstructionPlaneCommand(
            plane: ConstructionPlane(plane: .worldXY, size: 20)))
        let planeID = try XCTUnwrap(vm.session.document.planes.first?.id)
        vm.selectItemPlane(planeID)
        vm.startSketch(tool: .line)
        XCTAssertEqual(vm.activeSketch?.plane, .worldXY)
        vm.applyStandardView(.front)
        XCTAssertTrue(vm.mode.isSketching)
        vm.applyStandardView(.back)
        XCTAssertTrue(vm.mode.isSketching)
        vm.applyStandardView(.top)
        XCTAssertEqual(vm.mode, .idle)
    }

    // MARK: - Space: sketch on the hovered plane (QA-02)

    /// Shapr3D: Space with the pointer over a plane or face starts a sketch
    /// there. Nothing hovered, or a curved wall, does nothing.
    func testSpaceStartsSketchOnHoveredPlaneOrFace() throws {
        let vm = try makeViewModel()
        var document = vm.session.document
        let spec = PrimitiveSpec.cylinder(radius: 3, height: 5)
        let cylinder = Body(
            name: "Cylinder", transform: .identity, primitive: spec,
            euclidMesh: .primitive(spec), revision: document.nextRevision()
        )
        vm.session.perform(AddBodyCommand(body: cylinder))
        let box = try XCTUnwrap(MeasureKit.boundingBox(bodies: [cylinder]))

        // Nothing hovered: no-op.
        XCTAssertFalse(vm.sketchOnHoveredPlane())
        XCTAssertEqual(vm.mode, .idle)

        // Hover the flat cap: sketch on it.
        vm.hoverRay = Ray(origin: SIMD3(0.5, Float(box.max.y) + 10, 0.5), direction: SIMD3(0, -1, 0))
        XCTAssertTrue(vm.sketchOnHoveredPlane())
        XCTAssertTrue(vm.mode.isSketching)
        XCTAssertEqual(vm.mode.sketchTool, .line)
        XCTAssertEqual(vm.activeSketch?.plane.origin.y ?? -1, Double(box.max.y), accuracy: 1e-3)
        // Already sketching: Space does nothing more.
        XCTAssertFalse(vm.sketchOnHoveredPlane())
        vm.finishSketch()

        // Hover the bare grid: ground sketch.
        vm.hoverRay = Ray(origin: SIMD3(50, 10, 50), direction: SIMD3(0, -1, 0))
        XCTAssertTrue(vm.sketchOnHoveredPlane())
        XCTAssertEqual(vm.activeSketch?.plane, .ground)
        vm.finishSketch()

        // Hover the curved wall: refused, and no picker left behind.
        let midY = Float((box.min.y + box.max.y) / 2)
        vm.hoverRay = Ray(origin: SIMD3(10, midY, 0.5), direction: SIMD3(-1, 0, 0))
        XCTAssertFalse(vm.sketchOnHoveredPlane())
        XCTAssertEqual(vm.mode, .idle)
        XCTAssertTrue(vm.session.document.sketches.isEmpty)

        // The hovered plane beats one a named view defined earlier.
        vm.applyStandardView(.front)
        vm.hoverRay = Ray(origin: SIMD3(0.5, Float(box.max.y) + 10, 0.5), direction: SIMD3(0, -1, 0))
        XCTAssertTrue(vm.sketchOnHoveredPlane())
        XCTAssertEqual(vm.activeSketch?.plane.origin.y ?? -1, Double(box.max.y), accuracy: 1e-3)
        vm.finishSketch()

        // Tool first, then hover + Space: that tool, on the hovered plane.
        vm.resetViewAndGrid()
        vm.startSketch(tool: .circle)
        XCTAssertTrue(vm.isPickingSketchPlane)
        vm.hoverRay = Ray(origin: SIMD3(50, 10, 50), direction: SIMD3(0, -1, 0))
        XCTAssertTrue(vm.sketchOnHoveredPlane())
        XCTAssertEqual(vm.mode.sketchTool, .circle)
        XCTAssertEqual(vm.activeSketch?.plane, .ground)
        vm.finishSketch()
    }

    /// While the three rectangles are up, the grid follows the one under
    /// the pointer (spec §2.3); it goes back when the picker closes.
    func testGridFollowsTheHoveredRectangle() throws {
        let vm = try makeViewModel()
        vm.startSketch(tool: .line)
        XCTAssertTrue(vm.isPickingSketchPlane)
        // Straight at the XY rectangle (local 0.3…2.3 on X and Y).
        XCTAssertTrue(vm.updateHoveredSketchTile(ray: Ray(origin: SIMD3(1, 1, 10), direction: SIMD3(0, 0, -1))))
        XCTAssertEqual(vm.scene.gridPlane, .worldXY)
        XCTAssertFalse(vm.updateHoveredSketchTile(ray: Ray(origin: SIMD3(1.2, 1, 10), direction: SIMD3(0, 0, -1))),
                       "Still the same rectangle")
        // Off every rectangle: back to the plain grid.
        XCTAssertTrue(vm.updateHoveredSketchTile(ray: Ray(origin: SIMD3(40, 40, 10), direction: SIMD3(0, 0, -1))))
        XCTAssertNil(vm.scene.gridPlane)
        // Outside the picker the pointer moves nothing.
        _ = vm.updateHoveredSketchTile(ray: Ray(origin: SIMD3(1, 1, 10), direction: SIMD3(0, 0, -1)))
        vm.cancelPlanePicking()
        XCTAssertNil(vm.hoveredSketchTile)
        XCTAssertFalse(vm.updateHoveredSketchTile(ray: Ray(origin: SIMD3(1, 1, 10), direction: SIMD3(0, 0, -1))))
    }

    // MARK: - Sketch plane picker: face / curved face / miss (QA-01)

    /// With a sketch tool armed and no plane chosen: a planar cap is the
    /// sketch plane, a curved wall is refused and keeps the picker up
    /// (Shapr3D sketches on planar faces only), and a bare-grid miss falls
    /// back to the ground plane.
    func testPlanePickerAcceptsCapRefusesCurvedWallAndFallsBackToGround() throws {
        let vm = try makeViewModel()
        var document = vm.session.document
        let spec = PrimitiveSpec.cylinder(radius: 3, height: 5)
        let cylinder = Body(
            name: "Cylinder", transform: .identity, primitive: spec,
            euclidMesh: .primitive(spec), revision: document.nextRevision()
        )
        vm.session.perform(AddBodyCommand(body: cylinder))
        let box = try XCTUnwrap(MeasureKit.boundingBox(bodies: [cylinder]))
        let midY = Float((box.min.y + box.max.y) / 2)

        // Curved wall: refused, picker stays armed, nothing created.
        vm.startSketch(tool: .line)
        XCTAssertEqual(vm.mode, .pickingSketchPlane(tool: .line))
        vm.handle(.tap(ray: Ray(origin: SIMD3(10, midY, 0.5), direction: SIMD3(-1, 0, 0))))
        XCTAssertEqual(vm.mode, .pickingSketchPlane(tool: .line),
                       "A curved wall is not a sketch plane; the picker should stay up")
        XCTAssertTrue(vm.session.document.sketches.isEmpty)

        // Planar top cap: sketch on it.
        vm.handle(.tap(ray: Ray(origin: SIMD3(0.5, Float(box.max.y) + 10, 0.5), direction: SIMD3(0, -1, 0))))
        guard case .sketching = vm.mode else {
            return XCTFail("Tapping the planar cap should start a sketch, got \(vm.mode)")
        }
        let cap = try XCTUnwrap(vm.activeSketch?.plane)
        XCTAssertEqual(cap.origin.y, Double(box.max.y), accuracy: 1e-3)
        XCTAssertEqual(abs(cap.normal.y), 1, accuracy: 1e-4)
        vm.finishSketch()

        // Bare-grid miss: ground fallback.
        vm.startSketch(tool: .line)
        vm.handle(.tap(ray: Ray(origin: SIMD3(50, 10, 50), direction: SIMD3(0, -1, 0))))
        guard case .sketching = vm.mode else {
            return XCTFail("A bare-grid tap should sketch on the ground, got \(vm.mode)")
        }
        XCTAssertEqual(vm.activeSketch?.plane, .ground)
    }

    // MARK: - Measure: quick face distance, pins that follow

    /// A ray straight down onto the top face of the 2 mm box at `x`.
    private func downAt(_ x: Float) -> Ray {
        Ray(origin: SIMD3(x, 10, 0.3), direction: SIMD3(0, -1, 0))
    }

    /// Shift-click a second face while one is selected: the info bar reads
    /// the distance between them without Measure mode (spec §16.3).
    func testShiftClickingASecondFaceShowsTheDistanceBetweenThem() throws {
        let viewModel = try makeViewModel()
        _ = addBox(to: viewModel, name: "A", at: .zero)
        _ = addBox(to: viewModel, name: "B", at: SIMD3(10, 0, 0))

        viewModel.handle(.tap(ray: downAt(0)))
        guard case .faceSelected = viewModel.mode else { return XCTFail("a tap selects A's top face") }
        viewModel.tapShiftHeld = true
        viewModel.handle(.tap(ray: downAt(10)))
        viewModel.tapShiftHeld = false

        guard case .faceSelected = viewModel.mode else { return XCTFail("the first face stays selected") }
        let rows = Dictionary(viewModel.selectionMeasurements.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows["Parallel distance"], "0.00 mm", "the two tops are coplanar")
        XCTAssertEqual(rows["Minimum distance"], "8.00 mm")
        XCTAssertNotNil(rows["Area"], "the selected face's own rows stay")

        // A plain tap ends the quick measurement.
        viewModel.handle(.tap(ray: downAt(0)))
        XCTAssertNil(viewModel.selectionMeasurements.first { $0.label == "Minimum distance" })
    }

    /// A pinned Object Measurement measures its items again: moving a body
    /// changes the pinned gap, and undoing the move puts it back.
    func testAPinnedDistanceFollowsAMovedBody() throws {
        let viewModel = try makeViewModel()
        _ = addBox(to: viewModel, name: "A", at: .zero)
        let b = addBox(to: viewModel, name: "B", at: SIMD3(10, 0, 0))

        viewModel.toggleMeasure()
        XCTAssertEqual(viewModel.measureType, .object)
        viewModel.handle(.tap(ray: downAt(0)))
        viewModel.handle(.tap(ray: downAt(10)))
        let gap = try XCTUnwrap(viewModel.measureRows.first { $0.kind == .minDistance })
        XCTAssertEqual(gap.value, 8, accuracy: 1e-6)
        XCTAssertEqual(viewModel.measurePickSummary, "2 faces", "the panel says what is picked")
        viewModel.pinMeasurement(gap)
        let pin = try XCTUnwrap(viewModel.session.document.pinnedMeasurements.first)
        XCTAssertEqual(pin.sources?.count, 2, "the pin knows both faces")

        var moved = b.transform
        moved.translation.x += 5
        viewModel.session.perform(TransformBodiesCommand(before: [b.id: b.transform], after: [b.id: moved]))
        XCTAssertEqual(viewModel.livePin(pin).pin.value, 13, accuracy: 1e-6, "the gap grew with the move")
        XCTAssertEqual(viewModel.livePin(pin).items.count, 2)

        viewModel.session.undo()
        XCTAssertEqual(viewModel.livePin(pin).pin.value, 8, accuracy: 1e-6)
    }

    /// A Point-to-Point pin rides on the body its points were picked on.
    func testAPinnedPointDistanceRidesOnItsBody() throws {
        let viewModel = try makeViewModel()
        let a = addBox(to: viewModel, name: "A", at: .zero)

        viewModel.toggleMeasure()
        viewModel.measureType = .pointToPoint
        // Two top corners of A, straight down onto them.
        viewModel.handle(.tap(ray: Ray(origin: SIMD3(-1, 10, -1), direction: SIMD3(0, -1, 0))))
        viewModel.handle(.tap(ray: Ray(origin: SIMD3(1, 10, -1), direction: SIMD3(0, -1, 0))))
        let distance = try XCTUnwrap(viewModel.measureRows.first)
        XCTAssertEqual(distance.value, 2, accuracy: 1e-6)
        viewModel.pinMeasurement(distance)
        let pin = try XCTUnwrap(viewModel.session.document.pinnedMeasurements.first)

        var moved = a.transform
        moved.translation.y += 7
        viewModel.session.perform(TransformBodiesCommand(before: [a.id: a.transform], after: [a.id: moved]))
        let live = viewModel.livePin(pin).pin
        XCTAssertEqual(live.value, 2, accuracy: 1e-6, "a rigid move keeps the length")
        XCTAssertEqual(live.points.first?.y ?? 0, 9, accuracy: 1e-6, "and the span moves with the body")
    }
}
