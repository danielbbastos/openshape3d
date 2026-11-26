//
//  ExtrudeCutKit.swift
//  openshape3d
//
//  An Extrude subtract on one analytic body, for the commits feature replay
//  can't own (no history, or a replay that declined): the same OCCT prism and
//  boolean as the evaluator, so a solid never degrades to a mesh.
//

import Foundation
import simd
import Euclid

nonisolated enum ExtrudeCutKit {

    enum Outcome {
        case cut(Body)
        case failed(String)
        /// Mesh-only target, or no analytic prism: the mesh path owns it.
        case declined
    }

    static func cut(
        _ target: Body, outer: Profile, holes: [Profile],
        extras: [(profile: Profile, holes: [Profile])],
        plane: SketchPlane, distance: Double, symmetric: Bool
    ) -> Outcome {
        guard OCCTKernel.useOCCTAsSourceOfTruth, let brep = target.brep,
              let world = OCCTKernel.transformed(brep, by: target.transform)
        else { return .declined }
        let z = OCCTKernel.extrudeZRange(distance: distance, symmetric: symmetric)
        guard let tool = OCCTKernel.extrudeSolid(
            outer: outer, holes: holes, extras: extras,
            zMin: z.zMin, zMax: z.zMax,
            origin: plane.origin, xAxis: plane.xAxis, yAxis: plane.yAxis, normal: plane.normal)
        else { return .declined }

        switch OCCTKernel.booleanResult(world, tool, op: OCCTKernel.booleanOp(.subtract)) {
        case let .failure(error):
            return .failed("The cut in “\(target.name)” failed: \(error.message)")
        case let .success(outcome):
            // Keep the pivot; rotation and scale bake in, as on the mesh path.
            let pivot = target.transform.translation
            var toLocal = Transform3D.identity
            toLocal.translation = -pivot
            var placed = Transform3D.identity
            placed.translation = pivot
            var body = Body(
                id: target.id, name: target.name, transform: placed, primitive: nil,
                euclidMesh: Euclid.Mesh([]), revision: 0)
            guard let local = OCCTKernel.transformed(outcome.handle, by: toLocal),
                  body.adoptBRep(local)
            else { return .failed("The cut removed all of “\(target.name)”, so nothing was changed.") }
            return .cut(body)
        }
    }
}
