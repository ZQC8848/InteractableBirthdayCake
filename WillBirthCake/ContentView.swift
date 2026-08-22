//
//  ContentView.swift
//  WillBirthCake
//
//  Created by Qinchuan Zhang on 8/22/26.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var coordinator = ARCakeCoordinator()

    /// DEBUG SCAFFOLDING — see Debug/HandJointDebugOverlay.swift.
    @State private var showDebugPanel = false

    var body: some View {
        ZStack {
            ARViewContainer(coordinator: coordinator)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    debugCorner // DEBUG: remove with HandJointDebugOverlay.swift
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                statusBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Debug panel

    /// DEBUG SCAFFOLDING. Collapsed to a single button so the instrumentation stays
    /// available without sitting on top of the experience it exists to check.
    private var debugCorner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showDebugPanel.toggle()
                coordinator.setDebugPanelOpen(showDebugPanel)
            } label: {
                Image(systemName: showDebugPanel ? "xmark" : "ladybug.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.55), in: .circle)
            }

            if showDebugPanel {
                handDebugPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.2), value: showDebugPanel)
    }

    /// DEBUG SCAFFOLDING. Shows what the hand detector actually saw this frame.
    /// The markers alone cannot tell you *why* a pose was rejected — this line can,
    /// and the wrist distance separates "landmarks in the right place but at the
    /// wrong depth" from "landmarks in the wrong place".
    private var handDebugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Hand joint markers", isOn: Binding(
                get: { coordinator.showHandJoints },
                set: { coordinator.setHandJointsVisible($0) }
            ))
            .font(.caption.weight(.semibold))
            .fixedSize()

            Text(coordinator.handStatus)
            Text(coordinator.handWristDepth.map {
                String(format: "Wrist %.2f m from camera", $0)
            } ?? "Wrist — from camera")
            Text("Depth source: \(coordinator.depthSourceName)")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    // MARK: - Status

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
            hint("Open your hand, fingers spread, and hold still")

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
