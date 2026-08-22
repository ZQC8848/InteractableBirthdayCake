#!/bin/bash
# Checks the voxel pipeline's pure logic — grid construction, text protection,
# ray marching, blast carving — against the real cake data.
#
# VoxelGrid and VoxelSceneData depend only on Foundation and simd, so this runs on
# the Mac in a second or two without a device, a simulator, or an Xcode test target.
# Run it after touching anything under WillBirthCake/Voxel/.
#
#   ./Tools/VerifyVoxelLogic/run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/WillBirthCake/Voxel"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -O \
    "$SRC/VoxelSceneData.swift" \
    "$SRC/VoxelGrid.swift" \
    "$REPO_ROOT/Tools/VerifyVoxelLogic/main.swift" \
    -o "$BUILD_DIR/verify"

"$BUILD_DIR/verify" "$REPO_ROOT/WillBirthCake/Resources/cake_voxels.json"
