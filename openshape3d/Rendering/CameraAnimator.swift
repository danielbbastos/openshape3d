//
//  CameraAnimator.swift
//  openshape3d
//
//  Eases the turntable camera to a target pose. Drives the paused MTKView
//  with a CADisplayLink for the duration of the flight.
//

import Foundation
import UIKit
import MetalKit

@MainActor
final class CameraAnimator {
    private weak var renderer: Renderer?
    private weak var view: MTKView?

    private var displayLink: CADisplayLink?
    private var start: TurntableCamera?
    private var target: TurntableCamera?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.35

    /// Fired on every animation step (the camera moved).
    var cameraChanged: (() -> Void)?

    init(renderer: Renderer, view: MTKView) {
        self.renderer = renderer
        self.view = view
    }

    func animate(to camera: TurntableCamera, duration: CFTimeInterval = 0.35) {
        guard let renderer else { return }
        displayLink?.invalidate()
        start = renderer.camera
        target = camera
        startTime = CACurrentMediaTime()
        self.duration = duration

        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link

        // A display link only fires while the window is drawing frames. With
        // the app in the background, or its Mac window hidden behind another
        // one, a view command (View ▸ Top, the agent's `view.top`, Look at
        // Sketch…) used to report success and leave the camera where it was.
        // If the flight hasn't landed shortly after it should have, land it.
        flight &+= 1
        let current = flight
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [weak self] in
            guard let self, self.flight == current, self.displayLink != nil else { return }
            self.land()
        }
    }

    /// Ends a flight where it is — the user took the camera (SpaceMouse).
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Counts flights so a late fallback never lands a superseded one.
    private var flight = 0

    /// Jump straight to the flight's end pose.
    private func land() {
        displayLink?.invalidate()
        displayLink = nil
        guard let renderer, var camera = target else { return }
        // The end pose of everything `step` eases; the projection stays.
        camera.projection = renderer.camera.projection
        renderer.camera = camera
        view?.setNeedsDisplay()
        cameraChanged?()
    }

    @objc private func step() {
        guard let renderer, let start, let target else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        let raw = min(elapsed / duration, 1)
        // easeInOut
        let t = Float(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)

        var camera = renderer.camera
        camera.target = simd_mix(start.target, target.target, SIMD3(repeating: t))
        camera.distance = start.distance + (target.distance - start.distance) * t
        camera.azimuth = start.azimuth + shortestAngle(from: start.azimuth, to: target.azimuth) * t
        camera.elevation = start.elevation + (target.elevation - start.elevation) * t
        renderer.camera = camera
        view?.setNeedsDisplay()
        cameraChanged?()

        if raw >= 1 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func shortestAngle(from a: Float, to b: Float) -> Float {
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
