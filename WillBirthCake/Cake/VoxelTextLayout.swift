//
//  VoxelTextLayout.swift
//  WillBirthCake
//
//  The message hidden inside the cake, as a grid of lit cells.
//
//  Pure Foundation on purpose: Tools/VerifyVoxelLogic compiles this alongside
//  VoxelGrid to check that every cell still ends up buried inside solid cake. Change
//  `lines` or `scale` and that check tells you whether the text still fits, instead
//  of letters silently poking out through the frosting.
//
//  ## Why the text is not on the cake's voxel grid
//
//  "BIRTHDAY" is eight letters; at three-voxel glyphs with a one-voxel gap that is
//  31 columns. The cake's widest fully-enclosed interior is 23. Measured against the
//  real model, a grid-aligned vertical layout leaves 50 of 152 cells exposed and a
//  flat one leaves 22 — the word is simply wider than the cake, in any orientation.
//  Squeezing the glyphs to two voxels makes BIRTHDAY exactly 23 wide, but 23-wide
//  rows only exist at y = 7 and 8, and a line of text needs five.
//
//  So the text lives on its own finer grid, `scale` cake-voxels per cell. Losing
//  grid alignment turns out to *simplify* things: the text is no longer a set of
//  voxels flagged indestructible, it is a separate mesh the explosion has no way to
//  reach at all.
//

import Foundation

/// `nonisolated` so the verification tool can use it outside the main actor, and
/// because none of it touches shared state.
nonisolated enum VoxelTextLayout {

    // MARK: - Content and placement

    static let lines = ["HAPPY", "BIRTHDAY", "WILL"]

    /// Cake voxels per text cell. 0.65 is the largest that still fits; 0.6 keeps a
    /// margin so a small nudge to the placement does not push letters through the
    /// surface.
    static let scale: Float = 0.6

    /// Grid Y of the top edge of the block. Chosen so the widest line lands at the
    /// cake's widest height: BIRTHDAY ends up spanning y 5–8, where 23 columns are
    /// available and it needs 19, while the short top line sits in the narrower
    /// tier above.
    static let topY: Float = 12.0

    /// Grid Z of the slab. Centred, so the yaw applied when the cake is placed can
    /// turn this face toward the viewer.
    static let planeZ: Float = 0

    /// Warm white rather than gold. The text is emissive and seen against pink cake
    /// from inside a dark cavity, where a near-white glow separates far harder than a
    /// saturated colour does — a gold that is already close to the frosting's warmth
    /// reads as "lit cake" instead of "lit letters".
    static let colour = (r: Float(1.0), g: Float(0.94), b: Float(0.82))

    /// Where the glow light sits, in the cake's continuous grid coordinates: the
    /// middle of the block, on its plane.
    static var glowCentre: (x: Float, y: Float, z: Float) {
        (x: 0, y: topY - Float(blockHeight) * scale / 2, z: planeZ + 0.5)
    }

    // MARK: - Font

    private static let glyphWidth = 3
    private static let glyphHeight = 5
    /// Glyph width plus a one-column gap.
    private static let advance = 4
    private static let lineGap = 1

    /// 3×5 pixel glyphs. Only the letters used by `lines` are defined — an unknown
    /// character is a programming error, not something to render as a blank.
    private static let font: [Character: [String]] = [
        "H": ["#.#", "#.#", "###", "#.#", "#.#"],
        "A": [".#.", "#.#", "###", "#.#", "#.#"],
        "P": ["##.", "#.#", "##.", "#..", "#.."],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."],
        "B": ["##.", "#.#", "##.", "#.#", "##."],
        "I": ["###", ".#.", ".#.", ".#.", "###"],
        "R": ["##.", "#.#", "##.", "#.#", "#.#"],
        "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "D": ["##.", "#.#", "#.#", "#.#", "##."],
        "W": ["#.#", "#.#", "#.#", "###", "#.#"],
        "L": ["#..", "#..", "#..", "#..", "###"],
    ]

    // MARK: - Layout

    /// One lit pixel. `u` runs right, `v` runs *down* from the top of the block.
    struct Cell: Equatable {
        let u: Int
        let v: Int
    }

    static func lineWidth(_ line: String) -> Int {
        max(line.count * advance - 1, 0)
    }

    static var blockWidth: Int {
        lines.map(lineWidth).max() ?? 0
    }

    static var blockHeight: Int {
        lines.count * glyphHeight + (lines.count - 1) * lineGap
    }

    /// Every lit cell in the block, with each line centred against the widest one.
    static var cells: [Cell] {
        var result: [Cell] = []
        let width = blockWidth
        for (lineIndex, line) in lines.enumerated() {
            let rowTop = lineIndex * (glyphHeight + lineGap)
            let leftPad = (width - lineWidth(line)) / 2
            for (charIndex, character) in line.enumerated() {
                guard let glyph = font[character] else {
                    assertionFailure("No glyph for '\(character)' — add it to `font`.")
                    continue
                }
                for row in 0..<glyphHeight {
                    let pixels = Array(glyph[row])
                    for column in 0..<glyphWidth where pixels[column] == "#" {
                        result.append(
                            Cell(u: leftPad + charIndex * advance + column, v: rowTop + row)
                        )
                    }
                }
            }
        }
        return result
    }

    // MARK: - Placement in the cake's grid

    /// Left edge of the block, in the cake's (continuous) grid units, centred on x = 0.
    static var originX: Float {
        -Float(blockWidth) * scale / 2
    }

    /// Fraction of the message that can be seen from outside the cake, 0...1.
    ///
    /// Lives here rather than on the grid because the grid has no idea the text
    /// exists — the text is not made of its voxels. Keeping it in this file also
    /// keeps it inside what Tools/VerifyVoxelLogic can compile and check.
    static func exposedFraction(in grid: VoxelGrid) -> Float {
        let all = cells
        guard !all.isEmpty else { return 0 }
        let exposed = all.count { cell in
            let centre = gridCentre(of: cell)
            return grid.isExposedAlongZ(VoxelCoord(
                Int(floor(centre.x)), Int(floor(centre.y)), Int(floor(centre.z))
            ))
        }
        return Float(exposed) / Float(all.count)
    }

    /// Centre of a cell, in the cake's continuous grid coordinates. This is the
    /// bridge between text space and cake space, and the one thing the containment
    /// check in Tools/VerifyVoxelLogic exercises.
    static func gridCentre(of cell: Cell) -> (x: Float, y: Float, z: Float) {
        (
            x: originX + (Float(cell.u) + 0.5) * scale,
            y: topY - (Float(cell.v) + 0.5) * scale,
            z: planeZ + 0.5
        )
    }
}
