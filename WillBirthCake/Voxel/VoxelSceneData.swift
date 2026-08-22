//
//  VoxelSceneData.swift
//  WillBirthCake
//
//  Decodes the voxel cake JSON produced by the modelling tool.
//  See .ai/decisions/voxel-data-format-json.md for why this format was chosen
//  and for the duplicate-materialId rule enforced in `materialsByID`.
//

import Foundation

/// One voxel as it appears in the JSON: grid coordinates plus a material reference.
struct VoxelRecord: Decodable {
    let x: Int
    let y: Int
    let z: Int
    let materialId: Int
}

/// One layer of the model. `origin` offsets every voxel in the layer.
struct VoxelModelRecord: Decodable {
    let id: String
    let name: String
    let visible: Bool
    let origin: [Int]
    let voxels: [VoxelRecord]

    /// Layers whose name marks them as the protected "HAPPY BIRTHDAY" text.
    /// The text is what the explosion is meant to reveal, so it never takes damage.
    var isProtectedText: Bool {
        name.lowercased().contains("text")
    }

    var originOffset: VoxelCoord {
        // Defensive: the schema always writes three components, but a short array
        // would otherwise crash on subscript.
        guard origin.count == 3 else { return VoxelCoord(0, 0, 0) }
        return VoxelCoord(origin[0], origin[1], origin[2])
    }
}

struct VoxelMaterialRecord: Decodable {
    let id: Int
    let name: String
    let r: Float
    let g: Float
    let b: Float
    let roughness: Float
    let metallic: Float
    let emissive: Float
    let emissiveIntensity: Float
}

struct VoxelSceneData: Decodable {
    let version: Int
    let projectName: String
    let models: [VoxelModelRecord]
    let materials: [VoxelMaterialRecord]

    /// Material lookup with the **last definition winning**.
    ///
    /// The source file carries leftover placeholder materials (`Red`/`Green`/`Blue`)
    /// that reuse ids 1/2/3, which the real cake colours (`cake_pink`,
    /// `frosting_white`, `frosting_pink`) later redefine. Those three ids cover ~98%
    /// of the cake's voxels, so taking the *first* match would render the whole cake
    /// in primary colours. Iterating in array order and overwriting gives the
    /// intended palette. Do not "optimise" this into a first-match lookup.
    var materialsByID: [Int: VoxelMaterialRecord] {
        var table: [Int: VoxelMaterialRecord] = [:]
        for material in materials {
            table[material.id] = material
        }
        return table
    }

    static func load(resourceNamed name: String = "cake_voxels") throws -> VoxelSceneData {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw VoxelSceneError.resourceMissing(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VoxelSceneData.self, from: data)
    }
}

enum VoxelSceneError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Could not find \(name).json in the app bundle."
        }
    }
}
