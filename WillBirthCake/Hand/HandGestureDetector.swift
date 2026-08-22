//
//  HandGestureDetector.swift
//  WillBirthCake
//
//  Detects an open palm held face-up and reports where its centre is in world space.
//
//  iOS has no native hand-skeleton API — ARKit's hand tracking is visionOS only —
//  so this runs Vision's 2D hand pose request over the AR frame and lifts the
//  landmarks into 3D using the LiDAR depth map. See the constraints section of
//  CLAUDE.md.
//
//  Two things here are geometry that must be verified on a device rather than
//  reasoned about: the Vision→native-buffer orientation mapping in
//  `nativeNormalizedPoint(from:)`, and the palm-normal sign per chirality.
//

import ARKit
import Foundation
import Vision
import simd

struct HandDetection {
    /// Palm centre in ARKit world space.
    let palmCentre: SIMD3<Float>
    /// Palm normal in world space, pointing out of the back of the hand's palm side.
    let palmNormal: SIMD3<Float>
    /// Angle between the palm normal and world up, in degrees.
    let tiltFromUp: Float
}

/// Why a frame did or did not produce a gesture.
///
/// DEBUG SCAFFOLDING — see Debug/HandJointDebugOverlay.swift for how to remove it.
/// This exists because "the cake appeared in the wrong place" is not a diagnosis:
/// a wrong orientation mapping, a flipped palm normal, a bad depth sample and a
/// too-strict threshold all look identical from the outside. Naming the specific
/// stage that rejected the frame separates them in one glance.
enum HandPoseStatus: Equatable {
    case noHandVisible
    case fingersNotExtended
    case landmarksBelowConfidence
    /// Vision found the landmarks but the depth map had nothing usable there.
    case noDepthAtLandmarks
    /// Palm found, but pointing too far from up. Carries the measured angle.
    case tooTilted(degrees: Float)
    /// Pose is good and the hold timer is running. Carries elapsed seconds.
    case holding(seconds: TimeInterval, degrees: Float)
    case fired(degrees: Float)
}

/// One processed frame's worth of output.
struct HandFrameResult {
    /// Every landmark Vision found, reprojected to ARKit world space.
    /// Populated only when `includeAllJoints` is set — DEBUG SCAFFOLDING.
    let joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>]
    /// Distance from the camera to the wrist, in metres. DEBUG SCAFFOLDING:
    /// separates "landmarks are in the right place but at the wrong depth" from
    /// "landmarks are in the wrong place".
    let wristDepth: Float?
    let status: HandPoseStatus
    /// Non-nil only on the frame the gesture actually fires.
    let detection: HandDetection?
}

/// Explicitly `nonisolated`: the target defaults to main-actor isolation, but this
/// runs on the AR session's background queue so Vision never blocks rendering.
/// ARKit serialises those callbacks, so the mutable state below has a single writer.
nonisolated final class HandGestureDetector {

    enum Tuning {
        /// How far from straight-up the palm may point and still count as "face up".
        static let maxTiltFromUpDegrees: Float = 40
        /// Vision confidence floor for an individual joint.
        static let minJointConfidence: Float = 0.5
        /// How long the pose must hold before it fires, in seconds. Stops a hand
        /// passing through the pose from spawning a cake.
        static let requiredHoldDuration: TimeInterval = 0.6
        /// Process every Nth frame. Vision at 60 fps is wasteful and starves the
        /// render loop; ~10 Hz is plenty for a deliberate pose.
        static let frameStride = 6
        /// A finger counts as extended when the tip is at least this many times
        /// further from the wrist than its middle joint.
        static let extensionRatio: Float = 1.15
    }

    private let request = VNDetectHumanHandPoseRequest()
    private var frameCounter = 0
    private var poseHeldSince: Date?

    init() {
        request.maximumHandCount = 1
    }

    /// Runs detection for one frame.
    ///
    /// - Parameter includeAllJoints: reproject every landmark, not just the three the
    ///   gesture needs. DEBUG SCAFFOLDING — costs 21 depth samples instead of 3.
    /// - Returns: `nil` when the frame was skipped by `frameStride`, meaning "no new
    ///   information" as distinct from "no hand", so a display can hold its last state.
    ///
    /// Call this off the main thread — Vision is not cheap.
    func process(
        frame: ARFrame,
        orientation: CGImagePropertyOrientation,
        includeAllJoints: Bool = false
    ) -> HandFrameResult? {
        frameCounter += 1
        guard frameCounter % Tuning.frameStride == 0 else { return nil }

        guard let depthMap = frame.sceneDepth?.depthMap else {
            // No LiDAR depth: the project is scoped to depth-capable devices, so
            // rather than guessing a distance we simply do not detect.
            return nil
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: frame.capturedImage,
            orientation: orientation
        )
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              let points = try? observation.recognizedPoints(.all) else {
            poseHeldSince = nil
            return HandFrameResult(
                joints: [:], wristDepth: nil, status: .noHandVisible, detection: nil
            )
        }

        // Reprojected first, so the debug overlay still shows where the landmarks
        // landed on the frames where the gesture is rejected — which are exactly the
        // frames worth looking at.
        var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
        if includeAllJoints {
            for (name, point) in points where point.confidence >= Tuning.minJointConfidence {
                if let world = unproject(
                    point, frame: frame, depthMap: depthMap, orientation: orientation
                ) {
                    joints[name] = world
                }
            }
        }

        let cameraPosition = frame.camera.transform.columns.3
        let wristDepth = joints[.wrist].map {
            simd_distance($0, SIMD3<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z))
        }

        let evaluation = evaluate(
            observation: observation,
            points: points,
            frame: frame,
            depthMap: depthMap,
            orientation: orientation
        )

        switch evaluation {
        case .rejected(let status):
            poseHeldSince = nil
            return HandFrameResult(
                joints: joints, wristDepth: wristDepth, status: status, detection: nil
            )

        case .accepted(let detection):
            // Debounce: the pose has to survive a short hold before it counts.
            let now = Date()
            guard let start = poseHeldSince else {
                poseHeldSince = now
                return HandFrameResult(
                    joints: joints,
                    wristDepth: wristDepth,
                    status: .holding(seconds: 0, degrees: detection.tiltFromUp),
                    detection: nil
                )
            }

            let held = now.timeIntervalSince(start)
            guard held >= Tuning.requiredHoldDuration else {
                return HandFrameResult(
                    joints: joints,
                    wristDepth: wristDepth,
                    status: .holding(seconds: held, degrees: detection.tiltFromUp),
                    detection: nil
                )
            }

            poseHeldSince = nil
            return HandFrameResult(
                joints: joints,
                wristDepth: wristDepth,
                status: .fired(degrees: detection.tiltFromUp),
                detection: detection
            )
        }
    }

    func reset() {
        poseHeldSince = nil
    }

    // MARK: - Pose evaluation

    private enum PoseEvaluation {
        case rejected(HandPoseStatus)
        case accepted(HandDetection)
    }

    private func evaluate(
        observation: VNHumanHandPoseObservation,
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
        frame: ARFrame,
        depthMap: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> PoseEvaluation {

        func point(_ joint: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let p = points[joint], p.confidence >= Tuning.minJointConfidence else {
                return nil
            }
            return p
        }

        // The palm plane is spanned by wrist → index knuckle and wrist → little knuckle.
        guard let wrist = point(.wrist),
              let indexKnuckle = point(.indexMCP),
              let littleKnuckle = point(.littleMCP) else {
            return .rejected(.landmarksBelowConfidence)
        }

        guard allFingersExtended(points: points) else {
            return .rejected(.fingersNotExtended)
        }

        guard let wrist3D = unproject(wrist, frame: frame, depthMap: depthMap, orientation: orientation),
              let index3D = unproject(indexKnuckle, frame: frame, depthMap: depthMap, orientation: orientation),
              let little3D = unproject(littleKnuckle, frame: frame, depthMap: depthMap, orientation: orientation)
        else {
            return .rejected(.noDepthAtLandmarks)
        }

        let spanA = index3D - wrist3D
        let spanB = little3D - wrist3D
        let rawNormal = simd_cross(spanA, spanB)
        guard simd_length(rawNormal) > 1e-6 else {
            return .rejected(.noDepthAtLandmarks)
        }

        // The cross product's sign follows the order of the two knuckles, which
        // mirrors between hands — so one chirality has to be flipped for the normal
        // to mean "out of the palm" for both.
        let sign: Float = observation.chirality == .right ? 1 : -1
        let normal = simd_normalize(rawNormal) * sign

        let up = SIMD3<Float>(0, 1, 0)
        let tilt = acos(max(-1, min(1, simd_dot(normal, up)))) * 180 / .pi
        guard tilt <= Tuning.maxTiltFromUpDegrees else {
            return .rejected(.tooTilted(degrees: tilt))
        }

        // Centre of the palm rather than the wrist, so the cake sits in the hollow
        // of the hand instead of at its heel.
        let centre = (wrist3D + index3D + little3D) / 3

        return .accepted(
            HandDetection(palmCentre: centre, palmNormal: normal, tiltFromUp: tilt)
        )
    }

    /// Checks all five fingers read as straight, using distance from the wrist:
    /// on an extended finger the tip is clearly further out than the middle joint,
    /// while on a curled one it folds back toward the palm.
    private func allFingersExtended(
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> Bool {
        guard let wrist = points[.wrist], wrist.confidence >= Tuning.minJointConfidence else {
            return false
        }

        let fingers: [(tip: VNHumanHandPoseObservation.JointName,
                       middle: VNHumanHandPoseObservation.JointName)] = [
            (.thumbTip, .thumbMP),
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP),
        ]

        for finger in fingers {
            guard let tip = points[finger.tip], tip.confidence >= Tuning.minJointConfidence,
                  let middle = points[finger.middle], middle.confidence >= Tuning.minJointConfidence
            else { return false }

            let tipDistance = hypot(tip.location.x - wrist.location.x,
                                    tip.location.y - wrist.location.y)
            let middleDistance = hypot(middle.location.x - wrist.location.x,
                                       middle.location.y - wrist.location.y)
            guard middleDistance > 1e-5,
                  Float(tipDistance / middleDistance) >= Tuning.extensionRatio
            else { return false }
        }
        return true
    }

    // MARK: - 2D → 3D

    /// Lifts a Vision landmark into ARKit world space using the depth map.
    private func unproject(
        _ point: VNRecognizedPoint,
        frame: ARFrame,
        depthMap: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> SIMD3<Float>? {

        let normalized = nativeNormalizedPoint(from: point.location, orientation: orientation)
        guard normalized.x >= 0, normalized.x < 1, normalized.y >= 0, normalized.y < 1 else {
            return nil
        }

        guard let depth = sampleDepth(depthMap, atNormalized: normalized), depth > 0.05, depth < 3
        else { return nil }

        // Unproject with the camera intrinsics, which are expressed in the captured
        // image's pixel coordinates.
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let px = Float(normalized.x) * Float(resolution.width)
        let py = Float(normalized.y) * Float(resolution.height)

        let x = (px - intrinsics[2][0]) * depth / intrinsics[0][0]
        let y = (py - intrinsics[2][1]) * depth / intrinsics[1][1]

        // Image space is y-down and looks along +z; ARKit's camera is y-up looking
        // along -z, hence the two sign flips.
        let inCamera = SIMD4<Float>(x, -y, -depth, 1)
        let inWorld = frame.camera.transform * inCamera
        return SIMD3<Float>(inWorld.x, inWorld.y, inWorld.z)
    }

    /// Converts a Vision point into normalized coordinates of the *native* pixel
    /// buffer (top-left origin), which is the space both the depth map and the
    /// camera intrinsics use.
    ///
    /// Vision reports points in the **oriented** image with a bottom-left origin.
    /// For a portrait device the frame is handed to Vision as `.right`, i.e. the
    /// native landscape buffer rotated 90° clockwise for display. Undoing that
    /// rotation gives `nativeX = 1 - orientedY`, `nativeY = 1 - orientedX`, and
    /// flipping Vision's y-up convention folds into the same expression.
    ///
    /// **Verify this on a device** before trusting it: a wrong mapping here still
    /// produces plausible-looking 3D points, just in the wrong place.
    private func nativeNormalizedPoint(
        from visionPoint: CGPoint,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        switch orientation {
        case .right:
            return CGPoint(x: visionPoint.y, y: visionPoint.x)
        case .left:
            return CGPoint(x: 1 - visionPoint.y, y: 1 - visionPoint.x)
        case .down:
            return CGPoint(x: 1 - visionPoint.x, y: visionPoint.y)
        default: // .up
            return CGPoint(x: visionPoint.x, y: 1 - visionPoint.y)
        }
    }

    private func sampleDepth(_ depthMap: CVPixelBuffer, atNormalized point: CGPoint) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)

        // A hand is a small, noisy target in a 256×192 depth map, so take the median
        // of a small window instead of a single reading. One stray sample off the
        // silhouette would otherwise place the cake metres away.
        var samples: [Float] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let sx = min(max(x + dx, 0), width - 1)
                let sy = min(max(y + dy, 0), height - 1)
                let row = base.advanced(by: sy * bytesPerRow)
                let value = row.assumingMemoryBound(to: Float32.self)[sx]
                if value.isFinite, value > 0 { samples.append(value) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
