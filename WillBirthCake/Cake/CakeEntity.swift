//
//  CakeEntity.swift
//  WillBirthCake
//
//  Assembles the voxel grid into renderable geometry and keeps it in sync as the
//  cake is blown apart.
//
//  Two separate sets of geometry live here:
//
//  * the **cake**, split into chunks so an explosion only rebuilds the few chunks
//    it touched rather than all ~7000 voxels, and
//  * the **text**, built once and never rebuilt. It is buried inside the cake at
//    the start and simply becomes visible as the chunks around it are carved away.
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
final class CakeEntity: Entity {

    /// Edge length of one voxel in metres. 25 voxels across × 0.0065 m ≈ 16 cm wide,
    /// which reads as a cake sitting in an open palm.
    ///
    /// `nonisolated` so it can be used as a default argument, which Swift evaluates
    /// outside the main actor.
    nonisolated static let defaultVoxelSize: Float = 0.0065

    private(set) var grid: VoxelGrid
    private let materials: [RealityKit.Material]
    private let materialSlots: [Int: UInt32]

    private var chunkEntities: [ChunkCoord: ModelEntity] = [:]
    private let cakeRoot = Entity()
    private let textRoot = Entity()

    /// Offset that centres the model on x/z and rests its lowest voxel on y = 0,
    /// so the anchor position lands under the middle of the cake's base.
    private let originOffset: SIMD3<Float>
    private let voxelSize: Float

    // MARK: - Construction

    init(scene data: VoxelSceneData, voxelSize: Float = CakeEntity.defaultVoxelSize) throws {
        self.voxelSize = voxelSize

        // Flatten every visible layer into one voxel list, applying each layer's
        // origin offset. Text layers are marked indestructible here — that flag is
        // the only thing protecting the message from the explosion.
        var allVoxels: [Voxel] = []
        for model in data.models where model.visible {
            let offset = model.originOffset
            let destructible = !model.isProtectedText
            for record in model.voxels {
                let coord = VoxelCoord(record.x, record.y, record.z) + offset
                allVoxels.append(
                    Voxel(coord: coord, materialID: record.materialId, isDestructible: destructible)
                )
            }
        }

        self.grid = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)

        // Build the material palette once. `materialsByID` applies the last-wins rule
        // for the file's duplicated ids — see VoxelSceneData.
        //
        // Each source material expands into one variant per face-shading tier, so a
        // face's brightness is chosen by which material it is routed to. See
        // `FaceShadingTier` for why the shading is baked here rather than lit.
        let table = data.materialsByID
        let sortedIDs = table.keys.sorted()
        let tierCount = FaceShadingTier.allCases.count
        self.materialSlots = Dictionary(
            uniqueKeysWithValues: sortedIDs.enumerated().map { ($1, UInt32($0 * tierCount)) }
        )
        self.materials = sortedIDs.flatMap { id in
            FaceShadingTier.allCases
                .sorted { $0.index < $1.index }
                .map { Self.makeMaterial(from: table[id]!, brightness: $0.brightness) }
        }

        self.originOffset = SIMD3<Float>(
            Float(grid.minCoord.x + grid.maxCoord.x + 1) / 2,
            Float(grid.minCoord.y),
            Float(grid.minCoord.z + grid.maxCoord.z + 1) / 2
        )

        super.init()

        addChild(cakeRoot)
        addChild(textRoot)
        try buildAllChunks()
        try buildText()
    }

    @MainActor required init() {
        fatalError("Use init(scene:voxelSize:)")
    }

    private static func makeMaterial(
        from record: VoxelMaterialRecord,
        brightness: Float
    ) -> RealityKit.Material {
        // Scaled in sRGB rather than linear. Physically that overstates the
        // darkening, which is the point: it yields the crisp, slightly graphic
        // face separation the voxel look wants.
        let color = UIColor(
            red: CGFloat(record.r * brightness),
            green: CGFloat(record.g * brightness),
            blue: CGFloat(record.b * brightness),
            alpha: 1
        )
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: record.roughness)
        material.metallic = .init(floatLiteral: record.metallic)
        if record.emissive > 0 {
            // Emissive is left at full strength: a candle flame is its own light
            // source, so the face it happens to point along should not dim it.
            let emissiveColour = UIColor(
                red: CGFloat(record.r), green: CGFloat(record.g), blue: CGFloat(record.b), alpha: 1
            )
            material.emissiveColor = .init(color: emissiveColour)
            material.emissiveIntensity = record.emissive * record.emissiveIntensity
        }
        return material
    }

    private func slot(for materialID: Int, tier: FaceShadingTier) -> UInt32 {
        (materialSlots[materialID] ?? 0) + UInt32(tier.index)
    }

    // MARK: - Geometry

    private func buildAllChunks() throws {
        for (chunk, _) in grid.voxelsByChunk() {
            try rebuildChunk(chunk)
        }
    }

    /// Rebuilds one chunk's cake geometry from the current grid state.
    ///
    /// A cake face is hidden when *any* voxel sits next to it, text included: the
    /// text never disappears, so it is always a valid occluder.
    private func rebuildChunk(_ chunk: ChunkCoord) throws {
        let voxels = grid.voxels(inChunk: chunk).filter(\.isDestructible)

        let mesh = try VoxelMeshBuilder.buildMesh(
            voxels: voxels,
            voxelSize: voxelSize,
            originOffset: originOffset,
            occluder: { [grid] coord in grid.isOccupied(coord) },
            materialIndex: { [weak self] id, tier in self?.slot(for: id, tier: tier) ?? 0 }
        )

        guard let mesh else {
            // Fully carved away — drop the entity instead of leaving an empty one.
            chunkEntities.removeValue(forKey: chunk)?.removeFromParent()
            return
        }

        if let existing = chunkEntities[chunk] {
            existing.model = ModelComponent(mesh: mesh, materials: materials)
        } else {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            chunkEntities[chunk] = entity
            cakeRoot.addChild(entity)
        }
    }

    /// The text is built once. Its faces are hidden only by *other text voxels*, so
    /// it carries a complete outer surface from the start and is simply revealed as
    /// the surrounding cake is destroyed.
    private func buildText() throws {
        let textVoxels = grid.voxels.values.filter { !$0.isDestructible }
        guard !textVoxels.isEmpty else { return }

        let textCoords = Set(textVoxels.map(\.coord))
        let mesh = try VoxelMeshBuilder.buildMesh(
            voxels: textVoxels,
            voxelSize: voxelSize,
            originOffset: originOffset,
            occluder: { textCoords.contains($0) },
            materialIndex: { [weak self] id, tier in self?.slot(for: id, tier: tier) ?? 0 }
        )
        guard let mesh else { return }
        textRoot.addChild(ModelEntity(mesh: mesh, materials: materials))
    }

    // MARK: - Interaction

    struct BlastResult {
        let removed: [Voxel]
        /// Blast centre in the cake's local space, used to aim the debris outward.
        let localCentre: SIMD3<Float>
    }

    /// Finds the first solid voxel along a ray and carves a sphere around it.
    ///
    /// - Parameters:
    ///   - rayOrigin, rayDirection: in **this entity's local space**.
    ///   - radius: blast radius, in voxels.
    /// - Returns: `nil` when the ray misses the cake, or hits protected text with
    ///   no destructible voxels nearby.
    func blast(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        radius: Float
    ) -> BlastResult? {
        guard let hit = grid.firstSolidVoxel(rayOrigin: rayOrigin, direction: rayDirection) else {
            return nil
        }

        let (removed, dirtyChunks) = grid.removeSphere(centre: hit, radius: radius)
        guard !removed.isEmpty else { return nil }

        for chunk in dirtyChunks {
            do {
                try rebuildChunk(chunk)
            } catch {
                assertionFailure("Chunk rebuild failed: \(error)")
            }
        }

        return BlastResult(removed: removed, localCentre: grid.localCentre(of: hit))
    }

    func localCentre(of coord: VoxelCoord) -> SIMD3<Float> {
        grid.localCentre(of: coord)
    }

    /// A debris cube is one solid colour on all six sides, so it cannot use the
    /// per-face tiers. It takes the mid tier, which reads as neither a lit top nor a
    /// shadowed underside as it tumbles.
    func material(for materialID: Int) -> RealityKit.Material {
        materials[Int(slot(for: materialID, tier: .sideX))]
    }

    var destructibleVoxelCount: Int {
        grid.voxels.values.count(where: \.isDestructible)
    }
}
