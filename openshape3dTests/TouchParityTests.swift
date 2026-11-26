//
//  TouchParityTests.swift
//  openshape3dTests
//
//  Shapr3D finger / Pencil parity: the cube's finger-vs-Pencil picks, the
//  chamfered cube, the tripod, the grid's normal axis, Field of View as a
//  dolly-zoom, and the Finger Taps Select setting.
//

import XCTest
import simd
@testable import openshape3d

final class TouchParityTests: XCTestCase {
    private let viewport = CGSize(width: 1024, height: 768)

    private func frontCamera() -> TurntableCamera {
        var camera = TurntableCamera()
        camera.azimuth = 0
        camera.elevation = 0
        return camera
    }

    /// From the front, a point on the +Z face near its top edge.
    private func nearTopEdge() -> CGPoint {
        let rect = OrientationCube.rect(in: viewport)
        // u = 0, v ≈ 0.8 of the half extent (cube local), inside the bevel.
        let v = 0.82 / CGFloat(OrientationCube.orthoHalfExtent)
        return CGPoint(x: rect.midX, y: rect.midY - v * rect.height / 2)
    }

    func testPencilOnAnEdgeLooksFortyFiveDegrees() throws {
        let pose = try XCTUnwrap(OrientationCube.hitPose(
            at: nearTopEdge(), camera: frontCamera(), viewSize: viewport))
        XCTAssertEqual(pose.elevation, .pi / 4, accuracy: 1e-3)
        XCTAssertEqual(pose.azimuth, 0, accuracy: 1e-3)
    }

    func testFingerOnAnEdgeTakesTheNearestFace() throws {
        let pose = try XCTUnwrap(OrientationCube.hitPose(
            at: nearTopEdge(), camera: frontCamera(), viewSize: viewport, facesOnly: true))
        XCTAssertEqual(pose.elevation, 0, accuracy: 1e-3)
        XCTAssertEqual(pose.azimuth, 0, accuracy: 1e-3)
    }

    func testChamferedCubeHasTwentySixFacets() {
        let facets = OrientationCubeRenderer.facetPolygons()
        XCTAssertEqual(facets.count, 26)
        // Every facet is planar and faces outward.
        for facet in facets {
            for point in facet.polygon {
                XCTAssertGreaterThan(simd_dot(point, facet.normal), 0)
            }
        }
    }

    func testTripodLabelsAreXYZ() {
        let labels = OrientationCube.axisLabels(camera: TurntableCamera(), viewSize: viewport)
        XCTAssertEqual(labels.map(\.name), ["X", "Y", "Z"])
    }

    func testGroundGridStandsYUp() throws {
        let plane = SketchPlane.ground
        let axis = try XCTUnwrap(Renderer.gridNormalAxis(
            origin: SIMD3<Float>(plane.origin), xAxis: SIMD3<Float>(plane.xAxis),
            yAxis: SIMD3<Float>(plane.yAxis), length: 10))
        XCTAssertEqual(axis.to.y, 10, accuracy: 1e-4)
        XCTAssertEqual(axis.color, OrientationCubeRenderer.axisColors[1])
    }

    func testAGridOffTheOriginHasNoNormalAxis() {
        XCTAssertNil(Renderer.gridNormalAxis(
            origin: SIMD3(0, 5, 0), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1), length: 10))
    }

    func testFieldOfViewKeepsTheFraming() {
        var camera = TurntableCamera()
        let height = camera.distance * tan(camera.fovY / 2)
        camera.setFieldOfView(degrees: 80)
        XCTAssertEqual(camera.distance * tan(camera.fovY / 2), height, accuracy: 1e-3)
        camera.setFieldOfView(degrees: 15)
        XCTAssertEqual(camera.distance * tan(camera.fovY / 2), height, accuracy: 1e-3)
        camera.setFieldOfView(degrees: 0)
        XCTAssertEqual(camera.projection, .orthographic)
        XCTAssertEqual(camera.distance * tan(camera.fovY / 2), height, accuracy: 1e-3)
    }

    func testFingerTapSelection() {
        XCTAssertTrue(FingerTapSelection.automatic.selects(pencilSeen: false))
        XCTAssertFalse(FingerTapSelection.automatic.selects(pencilSeen: true))
        XCTAssertTrue(FingerTapSelection.on.selects(pencilSeen: true))
        XCTAssertFalse(FingerTapSelection.off.selects(pencilSeen: false))
    }

    func testTapKinds() {
        let finger = TapSequencer.Tap(point: .zero, time: 0, byFinger: true, shift: false)
        let pencil = TapSequencer.Tap(point: .zero, time: 0, byFinger: false, shift: false, byPencil: true)
        let mouse = TapSequencer.Tap(point: .zero, time: 0, byFinger: false, shift: false)
        XCTAssertEqual(TapInputKind(finger), .finger)
        XCTAssertEqual(TapInputKind(pencil), .pencil)
        XCTAssertEqual(TapInputKind(mouse), .pointer)
    }
}
