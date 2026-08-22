//
//  VoxelGrid.swift
//  WillBirthCake
//
//  The authoritative runtime state of the cake: which voxel sits where, which
//  ones may be destroyed, and which chunk each belongs to.
//
//  Hit testing deliberately does NOT go through RealityKit collision shapes.
//  Generating (and regenerating, after every explosion) collision meshes for
//  dozens of chunks is expensive; marching the ray through this grid is exact
//  and costs nothing. See `firstSolidVoxel(along:)`.
//

import Foundation
import simd

// MARK: - Coordinates

struct VoxelCoord: Hashable {
    var x: Int
    var y: Int
    var z: Int

    init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    static func + (lhs: VoxelCoord, rhs: VoxelCoord) -> VoxelCoord {
        VoxelCoord(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    /// The six axis-aligned neighbours, in the same order as `VoxelFace.allCases`.
    var neighbours: [VoxelCoord] {
        [
            VoxelCoord(x + 1, y, z), VoxelCoord(x - 1, y, z),
            VoxelCoord(x, y + 1, z), VoxelCoord(x, y - 1, z),
            VoxelCoord(x, y, z + 1), VoxelCoord(x, y, z - 1),
        ]
    }
}

/// Chunk-space coordinate. Same layout as `VoxelCoord`, kept distinct so the two
/// cannot be mixed up at a call site.
struct ChunkCoord: Hashable {
    var x: Int
    var y: Int
    var z: Int
}

struct Voxel {
    let coord: VoxelCoord
    let materialID: Int
    /// Text voxels are inert: the explosion skips them so they survive to be revealed.
    let isDestructible: Bool
}

// MARK: - Grid

final class VoxelGrid {
    /// Voxels per chunk edge. Chunks are the unit of mesh rebuilding, so this
    /// trades rebuild cost (smaller is cheaper) against draw calls (larger is fewer).
    static let chunkSize = 8

    private(set) var voxels: [VoxelCoord: Voxel]
    private(set) var minCoord: VoxelCoord
    private(set) var maxCoord: VoxelCoord

    let voxelSize: Float

    init(voxels: [Voxel], voxelSize: Float) {
        // Layers overlap: all 118 text voxels sit inside the solid bottom tier, and
        // the candle bases sink into the tiers above. Something has to win each
        // shared coordinate.
        //
        // Protected voxels always win. Resolving this by layer order instead would
        // work only as long as the text happens to be the last layer in the file —
        // reorder the layers and the whole message silently turns into destructible
        // cake and never appears, with nothing to point at the cause.
        var table: [VoxelCoord: Voxel] = [:]
        table.reserveCapacity(voxels.count)
        for voxel in voxels {
            if let existing = table[voxel.coord], !existing.isDestructible, voxel.isDestructible {
                continue
            }
            table[voxel.coord] = voxel
        }
        self.voxels = table
        self.voxelSize = voxelSize

        let xs = voxels.map(\.coord.x)
        let ys = voxels.map(\.coord.y)
        let zs = voxels.map(\.coord.z)
        self.minCoord = VoxelCoord(xs.min() ?? 0, ys.min() ?? 0, zs.min() ?? 0)
        self.maxCoord = VoxelCoord(xs.max() ?? 0, ys.max() ?? 0, zs.max() ?? 0)
    }

    // MARK: Queries

    func isOccupied(_ coord: VoxelCoord) -> Bool {
        voxels[coord] != nil
    }

    func voxel(at coord: VoxelCoord) -> Voxel? {
        voxels[coord]
    }

    static func chunk(containing coord: VoxelCoord) -> ChunkCoord {
        ChunkCoord(
            x: Int(floor(Double(coord.x) / Double(chunkSize))),
            y: Int(floor(Double(coord.y) / Double(chunkSize))),
            z: Int(floor(Double(coord.z) / Double(chunkSize)))
        )
    }

    /// Groups the current voxels by chunk. Used to build the initial meshes and
    /// to rebuild individual chunks after an explosion.
    func voxelsByChunk() -> [ChunkCoord: [Voxel]] {
        var buckets: [ChunkCoord: [Voxel]] = [:]
        for voxel in voxels.values {
            buckets[Self.chunk(containing: voxel.coord), default: []].append(voxel)
        }
        return buckets
    }

    func voxels(inChunk chunk: ChunkCoord) -> [Voxel] {
        let size = Self.chunkSize
        var result: [Voxel] = []
        for x in (chunk.x * size)..<((chunk.x + 1) * size) {
            for y in (chunk.y * size)..<((chunk.y + 1) * size) {
                for z in (chunk.z * size)..<((chunk.z + 1) * size) {
                    if let voxel = voxels[VoxelCoord(x, y, z)] {
                        result.append(voxel)
                    }
                }
            }
        }
        return result
    }

    // MARK: Mutation

    /// Removes every destructible voxel whose centre lies within `radius` voxels of
    /// `centre`, and reports which chunks now need their mesh rebuilt.
    ///
    /// The dirty set includes the chunks of the *neighbours* of every removed voxel,
    /// not just the chunks the voxels lived in: carving a hole at a chunk boundary
    /// exposes faces belonging to the adjacent chunk, and those would otherwise stay
    /// invisible, leaving a see-through gap in the cake.
    ///
    /// Deliberately uncapped. An earlier version limited the count here to bound how
    /// many rigid bodies a blast could spawn, which quietly coupled the *size of the
    /// hole* to a physics budget: raising the radius then changed nothing visible,
    /// because keeping the nearest N voxels of a bigger sphere carves exactly the
    /// same smaller sphere. The debris budget belongs in ExplosionController, where
    /// it can be spent without shrinking the hole.
    @discardableResult
    func removeSphere(
        centre: VoxelCoord,
        radius: Float
    ) -> (removed: [Voxel], dirtyChunks: Set<ChunkCoord>) {
        let r = Int(ceil(radius))
        let radiusSquared = radius * radius

        var removed: [Voxel] = []
        for dx in -r...r {
            for dy in -r...r {
                for dz in -r...r {
                    guard Float(dx * dx + dy * dy + dz * dz) <= radiusSquared else { continue }
                    let coord = VoxelCoord(centre.x + dx, centre.y + dy, centre.z + dz)
                    guard let voxel = voxels[coord], voxel.isDestructible else { continue }
                    removed.append(voxel)
                }
            }
        }

        var dirtyChunks: Set<ChunkCoord> = []
        for voxel in removed {
            voxels.removeValue(forKey: voxel.coord)
            dirtyChunks.insert(Self.chunk(containing: voxel.coord))
            for neighbour in voxel.coord.neighbours {
                dirtyChunks.insert(Self.chunk(containing: neighbour))
            }
        }

        return (removed, dirtyChunks)
    }

    // MARK: Ray marching

    /// Local-space centre of a voxel, with the grid centred on x/z and resting on y = 0.
    func localCentre(of coord: VoxelCoord) -> SIMD3<Float> {
        (SIMD3<Float>(Float(coord.x), Float(coord.y), Float(coord.z)) - localOriginOffset + 0.5)
            * voxelSize
    }

    /// Offset applied to every voxel so the model is centred horizontally and its
    /// lowest voxel sits on the anchor plane.
    private var localOriginOffset: SIMD3<Float> {
        SIMD3<Float>(
            Float(minCoord.x + maxCoord.x + 1) / 2,
            Float(minCoord.y),
            Float(minCoord.z + maxCoord.z + 1) / 2
        )
    }

    /// Walks the ray voxel by voxel (Amanatides & Woo) and returns the first solid
    /// voxel it enters. `origin`/`direction` are in the grid's local space.
    func firstSolidVoxel(
        rayOrigin origin: SIMD3<Float>,
        direction rawDirection: SIMD3<Float>,
        maxDistance: Float = 10
    ) -> VoxelCoord? {
        let direction = simd_normalize(rawDirection)
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return nil }

        // Grid space: continuous coordinates where voxel (i,j,k) occupies [i,i+1)³.
        let gridOrigin = origin / voxelSize + localOriginOffset

        var current = VoxelCoord(
            Int(floor(gridOrigin.x)),
            Int(floor(gridOrigin.y)),
            Int(floor(gridOrigin.z))
        )

        let step = VoxelCoord(
            direction.x > 0 ? 1 : -1,
            direction.y > 0 ? 1 : -1,
            direction.z > 0 ? 1 : -1
        )

        // Distance (in grid units) to advance one full voxel along each axis.
        // A zero direction component yields .infinity, which correctly means
        // "this axis never triggers a step".
        let tDelta = SIMD3<Float>(
            direction.x == 0 ? .infinity : abs(1 / direction.x),
            direction.y == 0 ? .infinity : abs(1 / direction.y),
            direction.z == 0 ? .infinity : abs(1 / direction.z)
        )

        func initialCrossing(_ position: Float, _ cell: Int, _ stepSign: Int, _ delta: Float) -> Float {
            guard delta.isFinite else { return .infinity }
            let boundary = stepSign > 0 ? Float(cell + 1) : Float(cell)
            return abs((boundary - position) * delta)
        }

        var tMax = SIMD3<Float>(
            initialCrossing(gridOrigin.x, current.x, step.x, tDelta.x),
            initialCrossing(gridOrigin.y, current.y, step.y, tDelta.y),
            initialCrossing(gridOrigin.z, current.z, step.z, tDelta.z)
        )

        let maxGridDistance = maxDistance / voxelSize
        // Bounded so a ray that misses the model entirely cannot spin forever.
        let stepBudget = Int(maxGridDistance) + 3

        for _ in 0..<stepBudget {
            if isOccupied(current) { return current }

            if tMax.x < tMax.y && tMax.x < tMax.z {
                if tMax.x > maxGridDistance { return nil }
                current.x += step.x
                tMax.x += tDelta.x
            } else if tMax.y < tMax.z {
                if tMax.y > maxGridDistance { return nil }
                current.y += step.y
                tMax.y += tDelta.y
            } else {
                if tMax.z > maxGridDistance { return nil }
                current.z += step.z
                tMax.z += tDelta.z
            }
        }
        return nil
    }
}
