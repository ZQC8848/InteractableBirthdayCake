//
//  HandGestureDetector.swift
//  WillBirthCake
//
//  Locates the centre of a hand's palm in world space.
//
//  The only pose test is that the hand is open: five extended fingers. Which way the
//  palm faces is not checked.
//
//  iOS has no native hand-skeleton API — ARKit's hand tracking is visionOS only —
//  so this runs Vision's 2D hand pose request over the AR frame and lifts the
//  landmarks into 3D using the LiDAR depth map. See the constraints section of
//  CLAUDE.md.
//
//  One piece here is geometry that must be verified on a device rather than reasoned
//  about: the Vision→native-buffer orientation mapping in `nativeNormalizedPoint`.
//

import ARKit
import Foundation
import Vision
import simd

struct HandDetection {
    /// Palm centre in ARKit world space.
    let palmCentre: SIMD3<Float>
    /// How many palm landmarks the centre was averaged from, out of `palmJoints`.
    /// More is steadier; two is the minimum accepted.
    let landmarkCount: Int
}

/// Why a frame did or did not locate a palm.
///
/// DEBUG SCAFFOLDING — see Debug/HandJointDebugOverlay.swift for how to remove it.
/// This exists because "the cake appeared in the wrong place" is not a diagnosis:
/// a wrong orientation mapping and a bad depth sample look identical from the
/// outside. Naming the stage that rejected the frame separates them in one glance.
enum HandPoseStatus: Equatable {
    case noHandVisible
    case landmarksBelowConfidence
    case fingersNotExtended
    /// Vision found the landmarks but the depth map had nothing usable there.
    case noDepthAtLandmarks
    /// Palm located and the hold timer is running. Carries elapsed seconds.
    case holding(seconds: TimeInterval, landmarks: Int)
    case fired(landmarks: Int)
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
        /// Vision confidence floor for an individual joint.
        static let minJointConfidence: Float = 0.3
        /// A finger counts as extended when its tip is at least this many times
        /// further from the wrist than its middle joint. A curled finger folds the
        /// tip back toward the palm, so the ratio drops below 1.
        static let extensionRatio: Float = 1.05
        /// Fewest palm landmarks that must reproject before a centre is trusted.
        /// One point is a single depth sample and lands wherever that sample is
        /// wrong; two already average most of it out.
        static let minPalmLandmarks = 2
        /// How long a palm must stay visible before the cake is placed, in seconds.
        ///
        /// This is the last remaining guard and it is not a pose test — it is about
        /// stability. The cake is world-anchored, so one noisy frame would strand it
        /// somewhere wrong permanently and the only way back is the Place Again
        /// button. A third of a second costs nothing and removes that.
        static let requiredHoldDuration: TimeInterval = 0.3
        /// Process every Nth frame. Vision at 60 fps is wasteful and starves the
        /// render loop; ~20 Hz keeps the debug markers readable.
        static let frameStride = 3
    }

    /// Landmarks averaged to find the middle of the palm. The knuckles bound the
    /// palm and the wrist anchors its base, so their mean sits in the hollow of the
    /// hand rather than at its heel.
    private static let palmJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP,
    ]

    private let request = VNDetectHumanHandPoseRequest()
    private var frameCounter = 0
    private var poseHeldSince: Date?

    init() {
        request.maximumHandCount = 1
    }

    /// Runs detection for one frame.
    ///
    /// - Parameter includeAllJoints: reproject every landmark, not just the palm.
    ///   DEBUG SCAFFOLDING — costs 21 depth samples instead of 5.
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

        guard let depth = HandDepthSource(frame: frame) else {
            // Neither LiDAR nor estimated depth this frame. Rather than guessing a
            // distance, report nothing.
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
        // landed on the frames that get rejected — which are exactly the frames
        // worth looking at.
        var joints: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
        if includeAllJoints {
            for (name, point) in points where point.confidence >= Tuning.minJointConfidence {
                if let world = unproject(
                    point, frame: frame, depth: depth, orientation: orientation
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
            points: points,
            frame: frame,
            depth: depth,
            orientation: orientation
        )

        switch evaluation {
        case .rejected(let status):
            poseHeldSince = nil
            return HandFrameResult(
                joints: joints, wristDepth: wristDepth, status: status, detection: nil
            )

        case .accepted(let detection):
            // Debounce: the palm has to stay visible briefly before it counts.
            let now = Date()
            guard let start = poseHeldSince else {
                poseHeldSince = now
                return HandFrameResult(
                    joints: joints,
                    wristDepth: wristDepth,
                    status: .holding(seconds: 0, landmarks: detection.landmarkCount),
                    detection: nil
                )
            }

            let held = now.timeIntervalSince(start)
            guard held >= Tuning.requiredHoldDuration else {
                return HandFrameResult(
                    joints: joints,
                    wristDepth: wristDepth,
                    status: .holding(seconds: held, landmarks: detection.landmarkCount),
                    detection: nil
                )
            }

            poseHeldSince = nil
            return HandFrameResult(
                joints: joints,
                wristDepth: wristDepth,
                status: .fired(landmarks: detection.landmarkCount),
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
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
        frame: ARFrame,
        depth: HandDepthSource,
        orientation: CGImagePropertyOrientation
    ) -> PoseEvaluation {

        // Whatever subset of the palm landmarks Vision is confident about and depth
        // can resolve gets averaged, rather than insisting on a fixed three — a
        // finger crossing the wrist or a stray depth hole should not cost a
        // detection.
        let confident = Self.palmJoints.compactMap { name -> VNRecognizedPoint? in
            guard let point = points[name],
                  point.confidence >= Tuning.minJointConfidence else { return nil }
            return point
        }
        guard confident.count >= Tuning.minPalmLandmarks else {
            return .rejected(.landmarksBelowConfidence)
        }

        // Checked before reprojection: it is pure 2D arithmetic, while reprojection
        // costs a depth sample per landmark.
        switch fingersExtended(points: points) {
        case .some(false): return .rejected(.fingersNotExtended)
        case .none: return .rejected(.landmarksBelowConfidence)
        case .some(true): break
        }

        let positions = confident.compactMap {
            unproject($0, frame: frame, depth: depth, orientation: orientation)
        }
        guard positions.count >= Tuning.minPalmLandmarks else {
            return .rejected(.noDepthAtLandmarks)
        }

        let centre = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        return .accepted(
            HandDetection(palmCentre: centre, landmarkCount: positions.count)
        )
    }

    /// Whether all five fingers read as straight, measured by distance from the
    /// wrist: on an extended finger the tip is clearly further out than the middle
    /// joint, while a curled one folds the tip back toward the palm.
    ///
    /// - Returns: `nil` when a joint is missing or below confidence, i.e. "cannot
    ///   tell" — kept distinct from `false` so the debug readout does not report a
    ///   partly occluded hand as a closed one.
    private func fingersExtended(
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> Bool? {
        guard let wrist = points[.wrist], wrist.confidence >= Tuning.minJointConfidence else {
            return nil
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
                  let middle = points[finger.middle],
                  middle.confidence >= Tuning.minJointConfidence
            else { return nil }

            let tipDistance = hypot(tip.location.x - wrist.location.x,
                                    tip.location.y - wrist.location.y)
            let middleDistance = hypot(middle.location.x - wrist.location.x,
                                       middle.location.y - wrist.location.y)
            guard middleDistance > 1e-5 else { return nil }
            if Float(tipDistance / middleDistance) < Tuning.extensionRatio { return false }
        }
        return true
    }

    // MARK: - 2D → 3D

    /// Lifts a Vision landmark into ARKit world space using the depth map.
    private func unproject(
        _ point: VNRecognizedPoint,
        frame: ARFrame,
        depth: HandDepthSource,
        orientation: CGImagePropertyOrientation
    ) -> SIMD3<Float>? {

        let normalized = nativeNormalizedPoint(from: point.location, orientation: orientation)
        guard normalized.x >= 0, normalized.x < 1, normalized.y >= 0, normalized.y < 1 else {
            return nil
        }

        guard let distance = sampleDepth(depth, atNormalized: normalized),
              distance > 0.05, distance < 3
        else { return nil }

        // Unproject with the camera intrinsics, which are expressed in the captured
        // image's pixel coordinates.
        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let px = Float(normalized.x) * Float(resolution.width)
        let py = Float(normalized.y) * Float(resolution.height)

        let x = (px - intrinsics[2][0]) * distance / intrinsics[0][0]
        let y = (py - intrinsics[2][1]) * distance / intrinsics[1][1]

        // Image space is y-down and looks along +z; ARKit's camera is y-up looking
        // along -z, hence the two sign flips.
        let inCamera = SIMD4<Float>(x, -y, -distance, 1)
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

    private func sampleDepth(_ source: HandDepthSource, atNormalized point: CGPoint) -> Float? {
        let buffer = source.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)

        // A hand is a small, noisy target in a 256×192 depth map, so take the median
        // of a window instead of a single reading. One stray sample off the
        // silhouette would otherwise place the cake metres away. Inferred depth is
        // noticeably noisier than LiDAR's measurement, so it gets a wider window.
        let reach = source.isEstimated ? 2 : 1

        // Outside the person stencil the network's output is not meaningful, so those
        // samples are dropped rather than averaged in. Without this a landmark near
        // the silhouette edge would blend the hand with whatever is behind it.
        let personMask = source.personStencil.map { stencil -> (UnsafeRawPointer, Int, Int, Int)? in
            CVPixelBufferLockBaseAddress(stencil, .readOnly)
            guard let stencilBase = CVPixelBufferGetBaseAddress(stencil) else { return nil }
            return (
                UnsafeRawPointer(stencilBase),
                CVPixelBufferGetWidth(stencil),
                CVPixelBufferGetHeight(stencil),
                CVPixelBufferGetBytesPerRow(stencil)
            )
        } ?? nil
        defer {
            if personMask != nil, let stencil = source.personStencil {
                CVPixelBufferUnlockBaseAddress(stencil, .readOnly)
            }
        }

        func isPerson(normalizedX: Double, normalizedY: Double) -> Bool {
            guard let (base, w, h, stride) = personMask else { return true }
            let sx = min(max(Int(normalizedX * Double(w)), 0), w - 1)
            let sy = min(max(Int(normalizedY * Double(h)), 0), h - 1)
            return base.advanced(by: sy * stride + sx).load(as: UInt8.self) != 0
        }

        var samples: [Float] = []
        for dy in -reach...reach {
            for dx in -reach...reach {
                let sx = min(max(x + dx, 0), width - 1)
                let sy = min(max(y + dy, 0), height - 1)
                // Stencil and depth buffers need not share dimensions, so the lookup
                // goes back through normalized coordinates.
                guard isPerson(
                    normalizedX: (Double(sx) + 0.5) / Double(width),
                    normalizedY: (Double(sy) + 0.5) / Double(height)
                ) else { continue }

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
