//
//  HandDepthSource.swift
//  WillBirthCake
//
//  Where the depth behind a hand landmark comes from.
//
//  There are two, and which one a device offers is not a detail the rest of the
//  code should care about:
//
//  * **LiDAR** (`sceneDepth` / `smoothedSceneDepth`) — a real measurement of the
//    whole scene, Pro iPhones and iPad Pro only.
//  * **Person segmentation** (`personSegmentationWithDepth` → `estimatedDepthData`)
//    — depth inferred by a neural network, and *only* for pixels the segmentation
//    stencil marks as a person. Needs A12 or later, no LiDAR. A hand counts as a
//    person for this purpose, which is exactly what this project needs.
//
//  The second path is why the project is no longer LiDAR-only — see
//  .ai/decisions/device-scope-lidar-only.md.
//

import ARKit
import CoreVideo
import Foundation

/// `nonisolated` for the same reason as `HandGestureDetector`: the target defaults
/// to main-actor isolation, but this is built and read on the AR session's
/// background queue.
nonisolated struct HandDepthSource {
    let buffer: CVPixelBuffer

    /// Non-nil only for estimated depth. Values outside this stencil are not
    /// meaningful — the network emits *something* everywhere, and reading it off the
    /// person would silently place landmarks at whatever the background happens to
    /// infer to.
    let personStencil: CVPixelBuffer?

    /// True when the depth is inferred rather than measured. Callers widen their
    /// sampling window for it, since it is markedly noisier than LiDAR.
    let isEstimated: Bool

    /// Picks the best source this frame offers, preferring the real measurement.
    init?(frame: ARFrame) {
        if let sceneDepth = frame.sceneDepth ?? frame.smoothedSceneDepth {
            self.buffer = sceneDepth.depthMap
            self.personStencil = nil
            self.isEstimated = false
        } else if let estimated = frame.estimatedDepthData {
            self.buffer = estimated
            self.personStencil = frame.segmentationBuffer
            self.isEstimated = true
        } else {
            return nil
        }
    }

    /// DEBUG: shown in the on-screen readout so it is obvious on a device which path
    /// is actually running.
    var debugName: String {
        isEstimated ? "Estimated (person segmentation)" : "LiDAR"
    }
}
