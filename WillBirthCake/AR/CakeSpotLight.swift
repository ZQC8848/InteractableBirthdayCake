//
//  CakeSpotLight.swift
//  WillBirthCake
//
//  A single spot light aimed at the cake.
//
//  It is parented to the cake's anchor rather than placed in world space, so it
//  frames the cake wherever the palm happened to be — a fixed world light would
//  miss it entirely.
//
//  On exposure: RealityKit measures spot intensity in lumens, but the scaling is
//  not something to derive on paper. Apple's own guidance is 10,000 lumens at an
//  attenuation radius of 6 for a room-scale scene, while a photometric estimate for
//  a light 45 cm from a 16 cm cake lands near 120 — two orders of magnitude apart.
//  The previous lighting attempt overexposed precisely because a value was reasoned
//  out rather than looked at, so the intensity here is a starting point with a live
//  debug slider attached (see ContentView), not a considered constant.
//

import RealityKit
import UIKit
import simd

@MainActor
final class CakeSpotLight {

    enum Tuning {
        /// Starting intensity in lumens. Deliberately conservative — erring dim is
        /// recoverable by eye, overexposure is what this rig exists to avoid.
        static let defaultIntensity: Float = 5_500
        static let maximumIntensity: Float = 10_000

        /// Position relative to the cake anchor, in metres. Above and off to one
        /// side: a light straight overhead leaves all four vertical faces equally
        /// dim, which is the flatness the baked face shading already has to fight.
        static let offset = SIMD3<Float>(0.28, 0.46, 0.22)
        /// Aim point, roughly the middle of the cake's height.
        static let target = SIMD3<Float>(0, 0.07, 0)

        /// Wide enough to cover the cake plus the debris that flies off it.
        static let attenuationRadius: Float = 1.6
        /// The gap between the two angles is the soft edge of the cone. A narrow
        /// gap gives a hard-edged circle of light on the cake.
        static let innerAngleDegrees: Float = 25
        static let outerAngleDegrees: Float = 55
    }

    private let light = SpotLight()

    init() {
        light.light.color = .white
        light.light.intensity = Tuning.defaultIntensity
        light.light.innerAngleInDegrees = Tuning.innerAngleDegrees
        light.light.outerAngleInDegrees = Tuning.outerAngleDegrees
        light.light.attenuationRadius = Tuning.attenuationRadius

        // No shadow. A spot's shadow is as hard-edged as the directional one that
        // was removed for exactly that reason, and ARView's grounding shadow already
        // supplies the contact cue that makes the cake sit in the palm.
        light.shadow = nil
    }

    /// Aims the light at the cake and parents it to the same anchor, so it follows
    /// the cake for the rest of the session.
    func attach(to anchor: Entity) {
        anchor.addChild(light)
        light.look(
            at: Tuning.target,
            from: Tuning.offset,
            upVector: SIMD3<Float>(0, 1, 0),
            relativeTo: anchor
        )
    }

    var intensity: Float {
        get { light.light.intensity }
        set { light.light.intensity = newValue }
    }
}
