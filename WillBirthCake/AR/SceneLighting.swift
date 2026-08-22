//
//  SceneLighting.swift
//  WillBirthCake
//
//  Explicit lights for the cake.
//
//  `environmentTexturing = .automatic` alone leaves the cake looking flat: it
//  derives image-based lighting from the camera feed, which is soft and roughly
//  uniform, so every voxel face receives nearly the same amount of light. A cube
//  lit equally on all six sides reads as a silhouette — the whole point of voxel
//  geometry is that the faces are distinguishable.
//
//  A directional key light restores that separation, and a dimmer fill from the
//  opposite side keeps the shadowed faces from going black.
//

import RealityKit
import UIKit
import simd

@MainActor
enum SceneLighting {

    private enum Tuning {
        /// Lux. AR scenes are composited over a bright camera feed, so a light that
        /// would be strong indoors still reads as subtle here.
        static let keyIntensity: Float = 12_000
        /// Deliberately well below the key: a fill that approaches it flattens the
        /// shading again, which is the problem this rig exists to solve.
        static let fillIntensity: Float = 3_000
        /// Key direction, from above and off to one side. Straight-down light leaves
        /// all four vertical sides of the cake equally dim.
        static let keyDirection = SIMD3<Float>(-0.55, -1, -0.4)
        static let fillDirection = SIMD3<Float>(0.6, -0.35, 0.55)
        static let shadowDepthBias: Float = 2
    }

    /// Builds the light rig as a single entity the caller can anchor and later
    /// remove in one piece.
    static func makeRig() -> Entity {
        let rig = Entity()
        rig.addChild(makeKeyLight())
        rig.addChild(makeFillLight())
        return rig
    }

    private static func makeKeyLight() -> Entity {
        let key = DirectionalLight()
        key.light.intensity = Tuning.keyIntensity
        key.light.color = .white
        key.light.isRealWorldProxy = false

        // Shadows are what sell the cake as sitting *in* the palm rather than
        // floating over it.
        key.shadow = DirectionalLightComponent.Shadow(
            maximumDistance: 1.5,
            depthBias: Tuning.shadowDepthBias
        )

        key.orientation = rotation(towards: Tuning.keyDirection)
        return key
    }

    private static func makeFillLight() -> Entity {
        let fill = DirectionalLight()
        fill.light.intensity = Tuning.fillIntensity
        fill.light.color = .white
        fill.light.isRealWorldProxy = false
        // No shadow on the fill — two shadow casters produce crossing shadows that
        // read as a rendering fault.
        fill.shadow = nil
        fill.orientation = rotation(towards: Tuning.fillDirection)
        return fill
    }

    /// A `DirectionalLight` shines along its own -Z axis, so aiming it means
    /// rotating that axis onto the desired direction.
    private static func rotation(towards direction: SIMD3<Float>) -> simd_quatf {
        let target = simd_normalize(direction)
        let forward = SIMD3<Float>(0, 0, -1)
        let dot = simd_dot(forward, target)
        // `simd_quatf(from:to:)` is undefined for exactly opposite vectors.
        if dot < -0.9999 { return simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        if dot > 0.9999 { return simd_quatf() }
        return simd_quatf(from: forward, to: target)
    }
}
