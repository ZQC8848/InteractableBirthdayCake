import Foundation
import simd

// Verification harness for the pure-logic parts of the voxel pipeline.
// VoxelGrid/VoxelSceneData only depend on Foundation + simd, so they run on macOS
// without ARKit or RealityKit.

// Path comes from run.sh so this file carries no machine-specific absolute path.
guard CommandLine.arguments.count > 1 else {
    print("usage: verify <path-to-cake_voxels.json>  (normally invoked via run.sh)")
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let scene = try JSONDecoder().decode(VoxelSceneData.self, from: data)

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  PASS  \(label) \(detail)")
    } else {
        print("  FAIL  \(label) \(detail)")
        failures += 1
    }
}

print("== decoding ==")
check("models", scene.models.count == 7, "got \(scene.models.count)")
check("materials array has duplicates", scene.materials.count == 17, "got \(scene.materials.count)")
let byID = scene.materialsByID
check("materialsByID collapses duplicates", byID.count == 14, "got \(byID.count)")
check("id 1 resolves to cake_pink (last wins)", byID[1]?.name == "cake_pink", "got \(byID[1]?.name ?? "nil")")
check("id 2 resolves to frosting_white", byID[2]?.name == "frosting_white", "got \(byID[2]?.name ?? "nil")")
check("id 3 resolves to frosting_pink", byID[3]?.name == "frosting_pink", "got \(byID[3]?.name ?? "nil")")

// Build the grid exactly the way CakeEntity does.
let voxelSize: Float = 0.0065
var allVoxels: [Voxel] = []
for model in scene.models where model.visible {
    let offset = model.originOffset
    let destructible = !model.isProtectedText
    for record in model.voxels {
        allVoxels.append(Voxel(
            coord: VoxelCoord(record.x, record.y, record.z) + offset,
            materialID: record.materialId,
            isDestructible: destructible
        ))
    }
}
let grid = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)

print("\n== grid ==")
// 6965 records collapse to 6805 distinct coordinates: 118 text voxels sit inside
// Bottom_Tier and 42 candle voxels sink into the tiers above.
check("total voxels", grid.voxels.count == 6805, "got \(grid.voxels.count)")
let textCount = grid.voxels.values.filter { !$0.isDestructible }.count
check("protected text voxels survive the overlap", textCount == 118, "got \(textCount)")

// Order-independence: feeding the layers in reverse must not let cake voxels
// overwrite the text.
let reversedGrid = VoxelGrid(voxels: allVoxels.reversed(), voxelSize: voxelSize)
let reversedTextCount = reversedGrid.voxels.values.filter { !$0.isDestructible }.count
check("protection is independent of layer order", reversedTextCount == 118, "got \(reversedTextCount)")
print("  info  bbox \(grid.minCoord) .. \(grid.maxCoord)")
let extent = SIMD3<Float>(
    Float(grid.maxCoord.x - grid.minCoord.x + 1),
    Float(grid.maxCoord.y - grid.minCoord.y + 1),
    Float(grid.maxCoord.z - grid.minCoord.z + 1)
) * voxelSize
print("  info  physical size \(String(format: "%.3f x %.3f x %.3f m", extent.x, extent.y, extent.z))")

// Face culling: how many faces actually survive versus the naive all-faces count.
var visibleFaces = 0
for voxel in grid.voxels.values {
    for neighbour in voxel.coord.neighbours where !grid.isOccupied(neighbour) {
        visibleFaces += 1
    }
}
print("\n== face culling ==")
print("  info  naive faces  \(grid.voxels.count * 6)")
print("  info  culled faces \(visibleFaces)  (\(visibleFaces * 2) triangles)")
check("culling removes >80% of faces", Float(visibleFaces) / Float(grid.voxels.count * 6) < 0.2)

// Ray marching. Fire from outside the cake, straight at the middle, and check we
// land on a real voxel near the surface rather than sailing through.
print("\n== ray marching ==")
let centreCoord = VoxelCoord(
    (grid.minCoord.x + grid.maxCoord.x) / 2,
    (grid.minCoord.y + grid.maxCoord.y) / 2,
    (grid.minCoord.z + grid.maxCoord.z) / 2
)
let centreLocal = grid.localCentre(of: centreCoord)
let cameraLocal = centreLocal + SIMD3<Float>(0, 0, 0.5)
if let hit = grid.firstSolidVoxel(rayOrigin: cameraLocal, direction: centreLocal - cameraLocal) {
    check("ray from +Z hits the cake", true, "at \(hit)")
    check("hit is a real voxel", grid.isOccupied(hit))
    check("hit is on the near side (z > centre)", hit.z > centreCoord.z, "hit.z=\(hit.z) centre.z=\(centreCoord.z)")
} else {
    check("ray from +Z hits the cake", false, "returned nil")
}

// From above, aimed down through the candles.
let above = grid.localCentre(of: VoxelCoord(centreCoord.x, grid.maxCoord.y + 20, centreCoord.z))
if let hit = grid.firstSolidVoxel(rayOrigin: above, direction: SIMD3<Float>(0, -1, 0)) {
    check("ray from above hits", true, "at \(hit)")
    check("hit is topmost occupied in that column", !grid.isOccupied(VoxelCoord(hit.x, hit.y + 1, hit.z)))
} else {
    check("ray from above hits", false, "returned nil")
}

// A ray pointing away from the model must miss.
let awayHit = grid.firstSolidVoxel(rayOrigin: cameraLocal, direction: SIMD3<Float>(0, 0, 1))
check("ray pointing away misses", awayHit == nil, "got \(String(describing: awayHit))")

// A ray parallel to the model but offset well clear of it must miss.
let besideOrigin = centreLocal + SIMD3<Float>(0.5, 0, 0.5)
let besideHit = grid.firstSolidVoxel(rayOrigin: besideOrigin, direction: SIMD3<Float>(0, 0, -1))
check("ray beside the cake misses", besideHit == nil, "got \(String(describing: besideHit))")

// Sphere removal.
print("\n== blast ==")
let before = grid.voxels.count
let surfaceHit = grid.firstSolidVoxel(rayOrigin: cameraLocal, direction: centreLocal - cameraLocal)!
let (removed, dirty) = grid.removeSphere(centre: surfaceHit, radius: 3.2, limit: 160)
check("removed something", !removed.isEmpty, "removed \(removed.count)")
check("all removed were destructible", removed.allSatisfy(\.isDestructible))
check("respects the cap", removed.count <= 160, "got \(removed.count)")
check("grid shrank by exactly that many", grid.voxels.count == before - removed.count)
check("removed voxels are gone", removed.allSatisfy { !grid.isOccupied($0.coord) })
print("  info  dirty chunks \(dirty.count)")
check("dirty set covers every removed voxel's chunk",
      removed.allSatisfy { dirty.contains(VoxelGrid.chunk(containing: $0.coord)) })

// Text must survive a blast aimed straight at it.
print("\n== text protection ==")
let textVoxel = grid.voxels.values.first { !$0.isDestructible }!
let textBefore = grid.voxels.values.filter { !$0.isDestructible }.count
let (removedNearText, _) = grid.removeSphere(centre: textVoxel.coord, radius: 4, limit: 500)
let textAfter = grid.voxels.values.filter { !$0.isDestructible }.count
check("blast centred on text destroys no text", textAfter == textBefore, "\(textBefore) -> \(textAfter)")
check("but it does clear the cake around it", !removedNearText.isEmpty, "removed \(removedNearText.count)")
check("text voxel itself survives", grid.isOccupied(textVoxel.coord))

// Newly exposed faces: after carving, the text should have cake-free neighbours,
// which is what makes it visible.
let exposedTextFaces = grid.voxels.values
    .filter { !$0.isDestructible }
    .reduce(0) { total, voxel in
        total + voxel.coord.neighbours.filter { !grid.isOccupied($0) }.count
    }
check("text now has exposed faces", exposedTextFaces > 0, "\(exposedTextFaces) faces")

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
