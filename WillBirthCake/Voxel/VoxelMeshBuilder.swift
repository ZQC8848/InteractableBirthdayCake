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
    ///   - materialIndex: maps a voxel's material id to its slot in the entity's
    ///     material array.
    /// - Returns: `nil` when nothing is visible, so the caller can drop the entity
    ///   entirely instead of adding an empty one.
    static func buildMesh(
        voxels: [Voxel],
        voxelSize: Float,
        originOffset: SIMD3<Float>,
        occluder: (VoxelCoord) -> Bool,
        materialIndex: (Int) -> UInt32
    ) throws -> MeshResource? {

        // Geometry is accumulated per material so each becomes its own mesh part.
        var positionsByMaterial: [UInt32: [SIMD3<Float>]] = [:]
        var normalsByMaterial: [UInt32: [SIMD3<Float>]] = [:]
        var indicesByMaterial: [UInt32: [UInt32]] = [:]

        for voxel in voxels {
            let slot = materialIndex(voxel.materialID)
            let minCorner = (SIMD3<Float>(
                Float(voxel.coord.x), Float(voxel.coord.y), Float(voxel.coord.z)
            ) - originOffset) * voxelSize

            for face in VoxelFace.allCases {
                guard !occluder(voxel.coord + face.neighbourOffset) else { continue }

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
