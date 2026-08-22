//
//  ARCakeCoordinator.swift
//  WillBirthCake
//
//  Owns the AR session and wires the two interactions together:
//  open palm → spawn the cake, tap → blast a hole in it.
//
//  Concurrency note: this target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION =
//  MainActor`, so everything here is main-actor isolated unless marked otherwise.
//  ARKit delivers frames on `visionQueue` (a background serial queue) to keep Vision
//  off the render loop, which is why the frame callback is `nonisolated` and hops
//  back to the main actor before touching the scene.
//

import ARKit
import Combine
import Foundation
import RealityKit
import UIKit
import os

@MainActor
final class ARCakeCoordinator: NSObject, ObservableObject {

    enum Phase: Equatable {
        case startingSession
        case unsupportedDevice
        case loadFailed(String)
        case searchingForPalm
        case cakePlaced
    }

    @Published private(set) var phase: Phase = .startingSession
    @Published private(set) var remainingVoxels: Int = 0

    /// DEBUG: hand-landmark markers and the live readout beside them.
    @Published var showHandJoints: Bool = true
    @Published private(set) var handStatus: String = "—"
    @Published private(set) var handWristDepth: Float?
    /// DEBUG: which depth path this device ended up on. Worth surfacing — the two
    /// differ enough in accuracy that "which one am I testing?" is the first
    /// question when the markers look off.
    @Published private(set) var depthSourceName: String = "—"
    /// DEBUG: spot intensity, exposed so it can be dialled in on a device. The right
    /// value is not derivable — see CakeSpotLight.
    @Published var spotIntensity: Float = CakeSpotLight.Tuning.defaultIntensity {
        didSet { spotLight?.intensity = spotIntensity }
    }

    private weak var arView: ARView?
    private var cake: CakeEntity?
    private var explosions: ExplosionController?
    private var cakeAnchor: AnchorEntity?

    /// DEBUG SCAFFOLDING — see Debug/HandJointDebugOverlay.swift.
    private let debugOverlay = HandJointDebugOverlay()

    private var spotLight: CakeSpotLight?

    /// Serial queue for ARKit delegate callbacks. Vision runs here so a ~30 ms
    /// inference never stalls rendering.
    private let visionQueue = DispatchQueue(label: "com.willbirthcake.vision")

    /// Only ever touched from `visionQueue`, which ARKit serializes for us.
    nonisolated(unsafe) private let detector = HandGestureDetector()

    /// Shared between the main actor (writer) and the vision queue (reader), so they
    /// need real synchronisation rather than unguarded flags.
    ///
    /// `gestureArmed` and `debugArmed` are separate on purpose: once the cake is
    /// placed the gesture must stop firing, but the markers should keep tracking so
    /// the hand can still be checked against a cake that is already in the scene.
    private let gestureArmed = OSAllocatedUnfairLock(initialState: false)
    private let debugArmed = OSAllocatedUnfairLock(initialState: true)
    private let captureOrientation = OSAllocatedUnfairLock<CGImagePropertyOrientation>(
        initialState: .right
    )

    // MARK: - Setup

    func attach(to arView: ARView) {
        self.arView = arView

        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .unsupportedDevice
            return
        }

        do {
            let data = try VoxelSceneData.load()
            // Built eagerly, while the user is still finding a surface: meshing
            // ~7000 voxels takes long enough to be a visible hitch if it happens at
            // the moment the palm is recognised.
            let cake = try CakeEntity(scene: data)
            self.cake = cake
            self.remainingVoxels = cake.remainingVoxelCount
        } catch {
            phase = .loadFailed(error.localizedDescription)
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic

        // Depth is what lifts Vision's 2D landmarks into world space, and there are
        // two ways to get it. LiDAR measures the whole scene and is preferred, but it
        // only exists on Pro iPhones and iPad Pro. Everything from A12 up can instead
        // infer depth for *people* — which includes a bare hand — via person
        // segmentation. See .ai/decisions/device-scope-lidar-only.md.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            configuration.frameSemantics.insert(.personSegmentationWithDepth)
        } else {
            phase = .unsupportedDevice
            return
        }
        depthSourceName = configuration.frameSemantics
            .contains(.personSegmentationWithDepth)
            ? "Estimated (person segmentation)" : "LiDAR" // DEBUG:

        arView.session.delegateQueue = visionQueue
        arView.session.delegate = self
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        updateCaptureOrientation()

        // The spot light is created with the cake, not here — it is parented to the
        // cake's anchor so it frames the cake wherever the palm turned out to be.
        debugOverlay.attach(to: arView.scene) // DEBUG:
        gestureArmed.withLock { $0 = true }
        phase = .searchingForPalm
    }

    func updateCaptureOrientation() {
        let interfaceOrientation = arView?.window?.windowScene?
            .effectiveGeometry.interfaceOrientation ?? .portrait
        let mapped = interfaceOrientation.visionImageOrientation
        captureOrientation.withLock { $0 = mapped }
    }

    // MARK: - Interactions

    /// Places the cake at a world position and stops looking for hands.
    ///
    /// The cake is parented to a plain world anchor, not to anything hand-derived:
    /// once placed it stays put even as the hand moves away, which is the whole
    /// point of anchoring it rather than attaching it.
    private func placeCake(at position: SIMD3<Float>) {
        guard let arView, let cake, cakeAnchor == nil else { return }

        gestureArmed.withLock { $0 = false }

        // Yaw the cake so its +Z — the plane the hidden message lies in — points at
        // the viewer. Without this the anchor keeps world-axis orientation and the
        // text can end up facing sideways or straight away, which is invisible until
        // someone walks around the cake.
        let camera = arView.cameraTransform.translation
        let toCamera = SIMD3<Float>(camera.x - position.x, 0, camera.z - position.z)
        let yaw = simd_length(toCamera) > 1e-4 ? atan2(toCamera.x, toCamera.z) : 0

        let anchor = AnchorEntity(world: Transform(
            scale: .one,
            rotation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)),
            translation: position
        ).matrix)
        anchor.addChild(cake)
        arView.scene.addAnchor(anchor)
        cakeAnchor = anchor

        // Parented to the anchor so it frames the cake wherever the palm was.
        let light = CakeSpotLight()
        light.intensity = spotIntensity
        light.attach(to: anchor)
        spotLight = light

        // Animates the cake, not the anchor: debris is parented to the anchor, and
        // scaling that would drag any fragments along with it.
        CakeSpawnAnimation.play(on: cake, in: arView.scene)

        explosions = ExplosionController(cake: cake, debrisRoot: anchor)
        phase = .cakePlaced
    }

    /// Fires a ray from the tap into the scene and blasts whatever voxel it hits.
    func handleTap(at screenPoint: CGPoint) {
        guard let arView, let explosions, phase == .cakePlaced else { return }
        guard let ray = arView.ray(through: screenPoint) else { return }

        let destroyed = explosions.fireRay(origin: ray.origin, direction: ray.direction)
        if destroyed > 0 {
            remainingVoxels = cake?.remainingVoxelCount ?? 0
        }
    }

    /// Clears the cake so the palm gesture can place a fresh one.
    func reset() {
        guard let arView, let data = try? VoxelSceneData.load() else { return }

        cakeAnchor.map { arView.scene.removeAnchor($0) }
        cakeAnchor = nil
        explosions = nil
        // Went away with the anchor it was parented to.
        spotLight = nil

        // Rebuilt from scratch: the grid is mutated in place by explosions, so the
        // old entity cannot be reused.
        guard let fresh = try? CakeEntity(scene: data) else { return }
        cake = fresh
        remainingVoxels = fresh.remainingVoxelCount

        detector.reset()
        gestureArmed.withLock { $0 = true }
        phase = .searchingForPalm
    }

    /// DEBUG: mirrors the SwiftUI toggle into the vision queue and the scene.
    func setHandJointsVisible(_ visible: Bool) {
        showHandJoints = visible
        debugArmed.withLock { $0 = visible }
        debugOverlay.isHidden = !visible
        if !visible {
            debugOverlay.clear()
            handStatus = "—"
            handWristDepth = nil
        }
    }
}

// MARK: - ARSessionDelegate

extension ARCakeCoordinator: ARSessionDelegate {

    /// Called on `visionQueue`, never the main actor.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let wantsGesture = gestureArmed.withLock { $0 }
        let wantsMarkers = debugArmed.withLock { $0 } // DEBUG:

        // Keep running while *either* consumer wants frames: after the cake is placed
        // the gesture is disarmed but the markers should still track. DEBUG:
        guard wantsGesture || wantsMarkers else { return }
        let orientation = captureOrientation.withLock { $0 }

        // A nil result means the frame was skipped by `frameStride`, not that the
        // hand is gone — leave the display alone rather than flickering the markers.
        guard let result = detector.process(
            frame: frame,
            orientation: orientation,
            includeAllJoints: wantsMarkers // DEBUG:
        ) else { return }

        Task { @MainActor in
            if wantsMarkers { // DEBUG:
                self.debugOverlay.update(positions: result.joints)
                self.handStatus = result.status.debugSummary
                self.handWristDepth = result.wristDepth
            }

            guard wantsGesture, let detection = result.detection else { return }
            // The gesture may have already fired while this hop was in flight.
            guard self.cakeAnchor == nil else { return }
            self.placeCake(at: detection.palmCentre)
        }
    }
}

private extension UIInterfaceOrientation {
    /// Orientation to hand Vision for a frame from ARKit's rear camera, whose native
    /// buffer is landscape.
    var visionImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }
}
