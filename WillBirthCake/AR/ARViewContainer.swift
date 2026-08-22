//
//  ARViewContainer.swift
//  WillBirthCake
//
//  Bridges `ARView` into SwiftUI.
//
//  This uses `ARView` rather than SwiftUI's `RealityView` because the experience
//  needs the pieces `RealityView` does not expose on iOS: a custom session
//  configuration with depth frame semantics, an `ARSessionDelegate` to feed Vision,
//  and `ray(through:)` for tap-to-blast.
//

import ARKit
import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {

    @ObservedObject var coordinator: ARCakeCoordinator

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(TapForwarder.handleTap(_:))
        )
        arView.addGestureRecognizer(tap)
        context.coordinator.arView = arView

        coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // The Vision→camera-buffer mapping depends on how the device is held, so the
        // cached orientation has to follow rotations.
        coordinator.updateCaptureOrientation()
    }

    func makeCoordinator() -> TapForwarder {
        TapForwarder(coordinator: coordinator)
    }

    /// UIKit gesture targets must be `@objc`, which SwiftUI structs cannot be.
    @MainActor
    final class TapForwarder: NSObject {
        private let coordinator: ARCakeCoordinator
        weak var arView: ARView?

        init(coordinator: ARCakeCoordinator) {
            self.coordinator = coordinator
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView else { return }
            coordinator.handleTap(at: recognizer.location(in: arView))
        }
    }
}
