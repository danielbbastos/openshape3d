//
//  ViewportBackgroundTests.swift
//  openshape3dTests
//
//  Dark mode reaches the viewport: Shapr3D's #191919, not the light grey.
//

import XCTest
@testable import openshape3d

final class ViewportBackgroundTests: XCTestCase {
    func testDarkModeIsShapr3DDarkGrey() {
        let dark = Renderer.viewportBackground(dark: true)
        XCTAssertEqual(dark.bottom.x, 25.0 / 255, accuracy: 0.01)
        XCTAssertLessThan(dark.top.x, 0.15)
    }

    func testLightModeKeepsThePaleGrey() {
        let light = Renderer.viewportBackground(dark: false)
        XCTAssertGreaterThan(light.bottom.x, 0.8)
        XCTAssertGreaterThan(light.top.x, light.bottom.x)
    }
}
