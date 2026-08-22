//
//  ExplosionController.swift
//  WillBirthCake
//
//  Spawns the debris for a blast: every destroyed voxel becomes its own rigid body
//  that is thrown outward from the impact point.
//
//  Real physics (rather than scripted arcs) is a deliberate choice — see
//  .ai/decisions/explosion-physics-real.md. The cost is that the number of
//  simultaneous bodies has to be bounded, which is what `Tuning.maxVoxelsPerBlast`
//  and the debris lifetime are for.
//

import Foundation
import RealityKit
import simd

@MainActor
final class ExplosionController {

    enum Tuning {
        /// Blast radius, in voxels. The hole is always carved at this full size.
        static let blastRadius: Float = 6.4
        /// Cap on *debris*, not on the hole. A radius of 6.4 inside solid cake
        /// clears on the order of 800 voxels; turning every one into a rigid body
        /// would swamp the physics solver, so a random sample of them is thrown and
        /// the rest simply vanish with the geometry.
        ///
        /// Sampled at random rather than nearest-first: taking the closest N would
        /// leave the whole outer shell of the blast disappearing with no debris at
        /// all, which reads as a rendering glitch rather than an explosion.
        static let maxDebrisPerBlast = 200
        /// Outward speed at the blast centre, m/s.
        static let baseSpeed: Float = 2.4
        /// Fraction of `baseSpeed` still applied at the very edge of the blast.
        static let edgeSpeedFalloff: Float = 0.35
        /// Random sideways scatter so the debris does not fly out in a clean shell.
        static let scatter: Float = 0.5
        /// Seconds a fragment survives before it is removed. Without this the scene
        /// accumulates rigid bodies falling forever.
        static let debrisLifetime: TimeInterval = 4.0
        static let fragmentMass: Float = 0.004
    }

    private unowned let cake: CakeEntity
    private let debrisRoot: Entity
    private let voxelSize: Float

    init(cake: CakeEntity, debrisRoot: Entity, voxelSize: Float = CakeEntity.defaultVoxelSize) {
        self.cake = cake
        self.debrisRoot = debrisRoot
        self.voxelSize = voxelSize
    }

    /// Carves the cake along `ray` and launches the resulting fragments.
    /// - Returns: how many voxels were destroyed; `0` when the ray missed.
    @discardableResult
    func fireRay(origin worldOrigin: SIMD3<Float>, direction worldDirection: SIMD3<Float>) -> Int {
        // The grid works in the cake's local space, so the ray has to come along.
        // Direction is converted as a difference of two points rather than as a
        // position, so translation drops out and only rotation/scale apply.
        let localOrigin = cake.convert(position: worldOrigin, from: nil)
        let localTip = cake.convert(position: worldOrigin + worldDirection, from: nil)
        let localDirection = localTip - localOrigin

        guard let result = cake.blast(
            rayOrigin: localOrigin,
            rayDirection: localDirection,
            radius: Tuning.blastRadius
        ) else { return 0 }

        spawnDebris(for: result)
        return result.removed.count
    }

    private func spawnDebris(for result: CakeEntity.BlastResult) {
        // The hole is already fully carved; this only decides what gets thrown.
        let thrown = result.removed.count <= Tuning.maxDebrisPerBlast
            ? result.removed
            : Array(result.removed.shuffled().prefix(Tuning.maxDebrisPerBlast))

        let fragmentMesh = MeshResource.generateBox(size: voxelSize)
        let shape = ShapeResource.generateBox(size: SIMD3<Float>(repeating: voxelSize))

        var physics = PhysicsBodyComponent(
            shapes: [shape],
            mass: Tuning.fragmentMass,
            material: .generate(friction: 0.5, restitution: 0.2),
            mode: .dynamic
        )
        physics.isAffectedByGravity = true

        // Constant for the whole blast: the cake does not move while it is being cut.
        let blastCentre = debrisRoot.convert(position: result.localCentre, from: cake)
        let cakeRotation = cake.convert(transform: .identity, to: debrisRoot).rotation

        var spawned: [ModelEntity] = []
        spawned.reserveCapacity(thrown.count)

        for voxel in thrown {
            let localPosition = cake.localCentre(of: voxel.coord)

            let fragment = ModelEntity(
                mesh: fragmentMesh,
                materials: [cake.material(for: voxel.materialID)]
            )
            fragment.position = debrisRoot.convert(position: localPosition, from: cake)
            fragment.orientation = cakeRotation
            fragment.components.set(CollisionComponent(shapes: [shape]))
            fragment.components.set(physics)

            debrisRoot.addChild(fragment)
            spawned.append(fragment)

            fragment.applyLinearImpulse(
                impulse(from: blastCentre, to: fragment.position) * Tuning.fragmentMass,
                relativeTo: nil
            )
            fragment.applyAngularImpulse(randomSpin(), relativeTo: nil)
        }

        scheduleRemoval(of: spawned)
    }

    /// Radial launch velocity, strongest at the blast centre and tapering toward the
    /// edge, plus a little scatter so the fragments do not form a clean shell.
    private func impulse(from centre: SIMD3<Float>, to position: SIMD3<Float>) -> SIMD3<Float> {
        let offset = position - centre
        let distance = simd_length(offset)

        // A voxel sitting exactly on the centre has no outward direction of its own,
        // so give it a random one rather than dividing by zero.
        let direction = distance > 1e-5
            ? offset / distance
            : simd_normalize(SIMD3<Float>.random(in: -1...1) + [0, 0.01, 0])

        let blastExtent = Tuning.blastRadius * voxelSize
        let falloff = simd_mix(
            1.0,
            Tuning.edgeSpeedFalloff,
            min(distance / max(blastExtent, 1e-5), 1.0)
        )

        let scatter = SIMD3<Float>.random(in: -Tuning.scatter...Tuning.scatter)
        // Slight upward bias so the blast reads as bursting open rather than sideways.
        return (direction + scatter + [0, 0.35, 0]) * Tuning.baseSpeed * falloff
    }

    private func randomSpin() -> SIMD3<Float> {
        SIMD3<Float>.random(in: -0.0005...0.0005)
    }

    private func scheduleRemoval(of fragments: [ModelEntity]) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Tuning.debrisLifetime))
            for fragment in fragments {
                fragment.removeFromParent()
            }
        }
    }
}
