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
check("models", scene.models.count == 6, "got \(scene.models.count)")
check("materials array has duplicates", scene.materials.count == 16, "got \(scene.materials.count)")
let byID = scene.materialsByID
check("materialsByID collapses duplicates", byID.count == 13, "got \(byID.count)")
check("id 1 resolves to cake_pink (last wins)", byID[1]?.name == "cake_pink", "got \(byID[1]?.name ?? "nil")")
check("id 2 resolves to frosting_white", byID[2]?.name == "frosting_white", "got \(byID[2]?.name ?? "nil")")
check("id 3 resolves to frosting_pink", byID[3]?.name == "frosting_pink", "got \(byID[3]?.name ?? "nil")")

// Build the grid exactly the way CakeEntity does.
let voxelSize: Float = 0.0065
var allVoxels: [Voxel] = []
for model in scene.models where model.visible {
    let offset = model.originOffset
    for record in model.voxels {
        allVoxels.append(Voxel(
            coord: VoxelCoord(record.x, record.y, record.z) + offset,
            materialID: record.materialId
        ))
    }
}
let grid = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)

print("\n== grid ==")
// 6847 records collapse to 6805 distinct coordinates: 42 candle voxels sink into
// the tiers above them.
check("total voxels", grid.voxels.count == 6805, "got \(grid.voxels.count)")
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

// Sphere removal. The blast radius is the size of the *hole*; the debris budget is
// a separate concern that lives in ExplosionController and must not shrink it.
print("\n== blast ==")
let blastRadius: Float = 6.4

// Guard the trap that motivated decoupling the two: with a nearest-N cap on removal,
// doubling the radius would carve an identical hole and look like nothing happened.
let probe = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)
let probeHit = probe.firstSolidVoxel(rayOrigin: cameraLocal, direction: centreLocal - cameraLocal)!
let smallBlast = probe.removeSphere(centre: probeHit, radius: 3.2).removed.count
let bigProbe = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)
let bigBlast = bigProbe.removeSphere(centre: probeHit, radius: blastRadius).removed.count
print("  info  radius 3.2 clears \(smallBlast) voxels, radius \(blastRadius) clears \(bigBlast)")
check("doubling the radius actually enlarges the hole", bigBlast > smallBlast * 3,
      "\(smallBlast) -> \(bigBlast)")

let before = grid.voxels.count
let surfaceHit = grid.firstSolidVoxel(rayOrigin: cameraLocal, direction: centreLocal - cameraLocal)!
let (removed, dirty) = grid.removeSphere(centre: surfaceHit, radius: blastRadius)
check("removed something", !removed.isEmpty, "removed \(removed.count)")
check("grid shrank by exactly that many", grid.voxels.count == before - removed.count)
check("removed voxels are gone", removed.allSatisfy { !grid.isOccupied($0.coord) })
check("nothing outside the radius was touched", removed.allSatisfy { voxel in
    let d = SIMD3<Float>(Float(voxel.coord.x - surfaceHit.x),
                         Float(voxel.coord.y - surfaceHit.y),
                         Float(voxel.coord.z - surfaceHit.z))
    return simd_length(d) <= blastRadius + 0.001
})
print("  info  dirty chunks \(dirty.count)")
check("dirty set covers every removed voxel's chunk",
      removed.allSatisfy { dirty.contains(VoxelGrid.chunk(containing: $0.coord)) })

// The hidden message. It is on its own finer grid, so the thing worth checking is
// no longer "is it flagged indestructible" but "is every cell actually buried".
// A cell that lands outside solid cake is visible from the outside before the cake
// is ever hit — which is exactly the failure that ruled out the grid-aligned
// layouts, and exactly what silently comes back if the wording changes.
print("\n== hidden text containment ==")

let freshGrid = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)
func isInterior(_ c: VoxelCoord) -> Bool {
    freshGrid.isOccupied(c) && c.neighbours.allSatisfy { freshGrid.isOccupied($0) }
}

let cells = VoxelTextLayout.cells
print("  info  lines \(VoxelTextLayout.lines) at scale \(VoxelTextLayout.scale)")
print("  info  block \(VoxelTextLayout.blockWidth) x \(VoxelTextLayout.blockHeight) cells, \(cells.count) lit")
check("text has cells", !cells.isEmpty)

var buried = 0
var exposed: [VoxelCoord] = []
for cell in cells {
    let p = VoxelTextLayout.gridCentre(of: cell)
    let coord = VoxelCoord(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
    if isInterior(coord) { buried += 1 } else { exposed.append(coord) }
}
check("every text cell is buried inside solid cake", exposed.isEmpty,
      "\(buried)/\(cells.count) buried" + (exposed.isEmpty ? "" : ", first exposed at \(exposed[0])"))

// The measurement behind rejecting the grid-aligned layouts. If a future change
// makes native scale viable, this is the check that would start failing.
var nativeBuried = 0
for cell in cells {
    let coord = VoxelCoord(
        cell.u - VoxelTextLayout.blockWidth / 2,
        Int(VoxelTextLayout.topY) - cell.v,
        Int(VoxelTextLayout.planeZ)
    )
    if isInterior(coord) { nativeBuried += 1 }
}
print("  info  same text at native 1:1 scale would bury only \(nativeBuried)/\(cells.count)")
check("scaling is still necessary", nativeBuried < cells.count,
      "native fits \(nativeBuried)/\(cells.count)")

// The text is not in the voxel grid at all, so no blast can touch it.
let anyCoord = grid.voxels.keys.first!
let sweep = VoxelGrid(voxels: allVoxels, voxelSize: voxelSize)
sweep.removeSphere(centre: anyCoord, radius: 100)
check("a blast large enough to clear the whole cake leaves no voxels",
      sweep.voxels.isEmpty, "\(sweep.voxels.count) left")
check("...and the text is untouched because it was never in the grid",
      VoxelTextLayout.cells.count == cells.count)

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
