//
//  VoxelMeshBuilder.swift
//  WillBirthCake
//
//  Turns a set of voxels into a merged RealityKit mesh.
//
//  The cake is solid — roughly 7000 voxels — so emitting all six faces of every
//  voxel would produce ~84k triangles, almost all of them buried inside the model
//  and invisible. Faces are therefore emitted only where the neighbouring voxel is
//  absent. That is also why an explosion has to rebuild chunks rather than just
//  delete geometry: carving a hole *exposes* interior faces that were never built.
//

import Foundation
import RealityKit
import simd

/// How much a face is darkened, purely by which way it points.
///
/// This is the voxel-rendering idiom (Minecraft does the same thing), and it is
/// here instead of a lighting rig for a reason. Image-based lighting from the
/// camera feed is soft and close to uniform, so every face of a cube receives
/// almost the same light and the model collapses into a silhouette. Adding
/// directional lights to fix that overexposes the scene — their contribution
/// stacks on top of the ambient — and buys a hard, unsoftenable shadow with it.
///
/// Baking the separation into the geometry keeps it *relative*: however bright or
/// dim the room is, the faces stay distinguishable, and there is no shadow-casting
/// light to blow out. Contact shadow is left to ARView's grounding shadow, which is
/// already tuned for AR.
///
/// The trade-off is that the shading is fixed to world axes, so it would not follow
/// a rotating model. The cake is world-anchored and never turns.
enum FaceShadingTier: CaseIterable {
    case top, sideX, sideZ, bottom

    init(face: VoxelFace) {
        switch face {
        case .positiveY: self = .top
        case .negativeY: self = .bottom
        case .positiveX, .negativeX: self = .sideX
        case .positiveZ, .negativeZ: self = .sideZ
        }
    }

    /// X and Z sides differ so two perpendicular walls meeting at a corner stay
    /// readable as two surfaces. A single shared "sides" value loses that edge.
    var brightness: Float {
        switch self {
        case .top: return 1.0
        case .sideX: return 0.80
        case .sideZ: return 0.66
        case .bottom: return 0.50
        }
    }

    var index: Int {
        switch self {
        case .top: return 0
        case .sideX: return 1
        case .sideZ: return 2
        case .bottom: return 3
        }
    }
}

enum VoxelFace: CaseIterable {
    case positiveX, negativeX, positiveY, negativeY, positiveZ, negativeZ

    var normal: SIMD3<Float> {
        switch self {
        case .positiveX: return [1, 0, 0]
        case .negativeX: return [-1, 0, 0]
        case .positiveY: return [0, 1, 0]
        case .negativeY: return [0, -1, 0]
        case .positiveZ: return [0, 0, 1]
        case .negativeZ: return [0, 0, -1]
        }
    }

    var neighbourOffset: VoxelCoord {
        switch self {
        case .positiveX: return VoxelCoord(1, 0, 0)
        case .negativeX: return VoxelCoord(-1, 0, 0)
        case .positiveY: return VoxelCoord(0, 1, 0)
        case .negativeY: return VoxelCoord(0, -1, 0)
        case .positiveZ: return VoxelCoord(0, 0, 1)
        case .negativeZ: return VoxelCoord(0, 0, -1)
        }
    }

    /// The four corners of this face, as multiples of the voxel size, offset from
    /// the voxel's minimum corner. Wound counter-clockwise seen from outside so
    /// RealityKit's default back-face culling keeps the face visible.
    var cornerOffsets: [SIMD3<Float>] {
        switch self {
        case .positiveX: return [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]]
        case .negativeX: return [[0, 0, 0], [0, 0, 1], [0, 1, 1], [0, 1, 0]]
        case .positiveY: return [[0, 1, 0], [0, 1, 1], [1, 1, 1], [1, 1, 0]]
        case .negativeY: return [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]]
        case .positiveZ: return [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
        case .negativeZ: return [[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]]
        }
    }
}

enum VoxelMeshBuilder {

    /// Builds one mesh for `voxels`, split into a part per material.
    ///
    /// - Parameters:
    ///   - voxels: the voxels to emit geometry for (typically one chunk).
    ///   - occluder: returns `true` when a neighbouring coordinate hides a face.
    ///     Callers pass different predicates for cake and text so the text keeps a
    ///     complete outer surface while it is still buried.
    ///   - materialIndex: maps a voxel's material id *and the face's shading tier*
    ///     to a slot in the entity's material array. Face brightness is baked in by
    ///     routing each face to a differently tinted material — see
    ///     `FaceShadingTier`.
    /// - Returns: `nil` when nothing is visible, so the caller can drop the entity
    ///   entirely instead of adding an empty one.
    static func buildMesh(
        voxels: [Voxel],
        voxelSize: Float,
        originOffset: SIMD3<Float>,
        occluder: (VoxelCoord) -> Bool,
        materialIndex: (Int, FaceShadingTier) -> UInt32
    ) throws -> MeshResource? {

        // Geometry is accumulated per material slot so each becomes its own mesh
        // part. A slot is (material × face tier), which is what bakes the shading.
        var positionsByMaterial: [UInt32: [SIMD3<Float>]] = [:]
        var normalsByMaterial: [UInt32: [SIMD3<Float>]] = [:]
        var indicesByMaterial: [UInt32: [UInt32]] = [:]

        for voxel in voxels {
            let minCorner = (SIMD3<Float>(
                Float(voxel.coord.x), Float(voxel.coord.y), Float(voxel.coord.z)
            ) - originOffset) * voxelSize

            for face in VoxelFace.allCases {
                guard !occluder(voxel.coord + face.neighbourOffset) else { continue }

                let slot = materialIndex(voxel.materialID, FaceShadingTier(face: face))
                var positions = positionsByMaterial[slot] ?? []
                var normals = normalsByMaterial[slot] ?? []
                var indices = indicesByMaterial[slot] ?? []

                let base = UInt32(positions.count)
                for corner in face.cornerOffsets {
                    positions.append(minCorner + corner * voxelSize)
                    normals.append(face.normal)
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])

                positionsByMaterial[slot] = positions
                normalsByMaterial[slot] = normals
                indicesByMaterial[slot] = indices
            }
        }

        guard !positionsByMaterial.isEmpty else { return nil }

        // Sorted so part order is deterministic across rebuilds — otherwise the
        // same chunk could shuffle its parts between explosions.
        let descriptors: [MeshDescriptor] = positionsByMaterial.keys.sorted().compactMap { slot in
            guard let positions = positionsByMaterial[slot],
                  let normals = normalsByMaterial[slot],
                  let indices = indicesByMaterial[slot],
                  !positions.isEmpty else { return nil }

            var descriptor = MeshDescriptor(name: "voxels_material_\(slot)")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.primitives = .triangles(indices)
            descriptor.materials = .allFaces(slot)
            return descriptor
        }

        guard !descriptors.isEmpty else { return nil }
        return try MeshResource.generate(from: descriptors)
    }
}
