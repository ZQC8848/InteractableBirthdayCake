//
//  ContentView.swift
//  WillBirthCake
//
//  Created by Qinchuan Zhang on 8/22/26.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var coordinator = ARCakeCoordinator()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(coordinator: coordinator)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 10) {
                statusBar
                handDebugPanel // DEBUG: remove with HandJointDebugOverlay.swift
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    /// DEBUG SCAFFOLDING. Shows what the hand detector actually saw this frame.
    /// The markers alone cannot tell you *why* a pose was rejected — this line can,
    /// and the wrist distance separates "landmarks in the wrong place" from
    /// "landmarks in the right place at the wrong depth".
    @ViewBuilder
    private var handDebugPanel: some View {
        VStack(spacing: 6) {
            Toggle("Show hand joint markers", isOn: Binding(
                get: { coordinator.showHandJoints },
                set: { coordinator.setHandJointsVisible($0) }
            ))
            .font(.caption.weight(.semibold))

            if coordinator.showHandJoints {
                Text(coordinator.handStatus)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(coordinator.handWristDepth.map {
                    String(format: "Wrist %.2f m from camera", $0)
                } ?? "Wrist — from camera")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Depth source: \(coordinator.depthSourceName)")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusBar: some View {
        switch coordinator.phase {
        case .startingSession:
            hint("Starting AR…")

        case .unsupportedDevice:
            hint("This device lacks the AR depth support this needs.\nRequires an A12 chip or later (iPhone XS and up).")

        case .loadFailed(let message):
            hint("Could not load the cake data:\n\(message)")

        case .searchingForPalm:
            hint("Open your hand, palm up, and hold still")

        case .cakePlaced:
            VStack(spacing: 12) {
                hint("Tap the cake to blow it open and see what's inside")
                Button("Place Again") { coordinator.reset() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.9))
                    .foregroundStyle(.black)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}
