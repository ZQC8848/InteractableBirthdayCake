//
//  HandJointDebugOverlay.swift
//  WillBirthCake
//
//  ⚠️ DEBUG SCAFFOLDING — MEANT TO BE DELETED ⚠️
//
//  Draws a sphere at every hand landmark the detector reprojects into world space,
//  joined by bones so the hand reads as a hand.
//
//  Why bones and not just points: the failure this is built to catch is a wrong
//  Vision→camera-buffer orientation mapping, and a wrong mapping still produces a
//  plausible-looking cloud of points — just rotated or mirrored. A loose cloud hides
//  that; a skeleton makes it obvious, because a mirrored hand has the thumb on the
//  wrong side and a rotated one points the wrong way.
//
//  TO REMOVE, delete this file and the four call sites marked `DEBUG:` in
//  ARCakeCoordinator.swift, plus the debug section of ContentView.swift and the
//  `includeAllJoints` / `HandFrameResult.joints` / `HandFrameResult.wristDepth` /
//  `HandPoseStatus` members of HandGestureDetector.swift.
//

import RealityKit
import UIKit
import Vision
import simd

@MainActor
final class HandJointDebugOverlay {

    private enum Style {
        static let jointRadius: Float = 0.005
        static let wristRadius: Float = 0.009
        static let boneThickness: Float = 0.003
    }

    /// Finger chains, each starting at the wrist. Also the bone list.
    private static let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    /// One colour per finger so a mirrored mapping is visible immediately — a
    /// left/right flip puts the red thumb where the cyan little finger belongs.
    private static let fingerColours: [UIColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
    ]

    private let root = AnchorEntity(world: SIMD3<Float>.zero)
    private var joints: [VNHumanHandPoseObservation.JointName: ModelEntity] = [:]
    private var bones: [ModelEntity] = []

    init() {
        // Everything is allocated once and then shown/hidden. Rebuilding 21 spheres
        // and 20 bones at 10 Hz would churn meshes for no reason.
        for (chainIndex, chain) in Self.chains.enumerated() {
            let colour = Self.fingerColours[chainIndex]

            for name in chain where joints[name] == nil {
                let isWrist = name == .wrist
                let sphere = ModelEntity(
                    mesh: .generateSphere(
                        radius: isWrist ? Style.wristRadius : Style.jointRadius
                    ),
                    // Unlit so the markers stay legible regardless of scene lighting —
                    // this is an instrument, not part of the scene.
                    materials: [UnlitMaterial(color: isWrist ? .white : colour)]
                )
                sphere.isEnabled = false
                joints[name] = sphere
                root.addChild(sphere)
            }

            for _ in 1..<chain.count {
                let bone = ModelEntity(
                    mesh: .generateBox(size: 1),
                    materials: [UnlitMaterial(color: colour.withAlphaComponent(0.7))]
                )
                bone.isEnabled = false
                bones.append(bone)
                root.addChild(bone)
            }
        }
    }

    func attach(to scene: RealityKit.Scene) {
        scene.addAnchor(root)
    }

    func detach() {
        root.removeFromParent()
    }

    var isHidden: Bool = false {
        didSet { root.isEnabled = !isHidden }
    }

    /// Positions the markers. Landmarks missing from `positions` (no confidence, or
    /// no usable depth) have their sphere hidden rather than left at a stale spot —
    /// a marker frozen where the hand used to be reads as a tracking success.
    func update(positions: [VNHumanHandPoseObservation.JointName: SIMD3<Float>]) {
        for (name, entity) in joints {
            if let position = positions[name] {
                entity.position = position
                entity.isEnabled = true
            } else {
                entity.isEnabled = false
            }
        }

        var boneIndex = 0
        for chain in Self.chains {
            for link in 1..<chain.count {
                defer { boneIndex += 1 }
                guard boneIndex < bones.count else { break }
                let bone = bones[boneIndex]

                guard let start = positions[chain[link - 1]],
                      let end = positions[chain[link]] else {
                    bone.isEnabled = false
                    continue
                }

                let delta = end - start
                let length = simd_length(delta)
                guard length > 1e-5 else {
                    bone.isEnabled = false
                    continue
                }

                bone.position = (start + end) / 2
                bone.scale = [Style.boneThickness, length, Style.boneThickness]
                bone.orientation = Self.rotation(fromUpTo: delta / length)
                bone.isEnabled = true
            }
        }
    }

    func clear() {
        for entity in joints.values { entity.isEnabled = false }
        for bone in bones { bone.isEnabled = false }
    }

    /// Rotation taking the box's +Y axis onto `direction`.
    private static func rotation(fromUpTo direction: SIMD3<Float>) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, direction)
        // `simd_quatf(from:to:)` is undefined for exactly opposite vectors, which a
        // downward-pointing bone hits routinely.
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: [1, 0, 0])
        }
        if dot > 0.9999 {
            return simd_quatf()
        }
        return simd_quatf(from: up, to: direction)
    }
}

// MARK: - Readable status

extension HandPoseStatus {
    /// One line describing what the detector saw, for the on-screen readout.
    /// DEBUG SCAFFOLDING.
    var debugSummary: String {
        switch self {
        case .noHandVisible:
            return "No hand detected"
        case .landmarksBelowConfidence:
            return "Landmark confidence too low"
        case .noDepthAtLandmarks:
            return "No depth at landmarks"
        case .holding(let seconds, let landmarks):
            return String(format: "Holding %.1f/%.1fs · %d palm points",
                          seconds, HandGestureDetector.Tuning.requiredHoldDuration, landmarks)
        case .fired(let landmarks):
            return String(format: "Fired · %d palm points", landmarks)
        }
    }
}
