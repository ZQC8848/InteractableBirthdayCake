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
            Toggle("显示手部关节标记", isOn: Binding(
                get: { coordinator.showHandJoints },
                set: { coordinator.setHandJointsVisible($0) }
            ))
            .font(.caption.weight(.semibold))

            if coordinator.showHandJoints {
                Text(coordinator.handStatus)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(coordinator.handWristDepth.map {
                    String(format: "手腕距相机 %.2f m", $0)
                } ?? "手腕距相机 —")
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("深度来源：\(coordinator.depthSourceName)")
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
            hint("正在启动 AR…")

        case .unsupportedDevice:
            hint("这台设备不支持所需的 AR 深度功能。\n需要 A12 及以上芯片（iPhone XS 起）。")

        case .loadFailed(let message):
            hint("蛋糕数据加载失败：\n\(message)")

        case .searchingForPalm:
            hint("张开手掌、掌心朝上，稳住不动")

        case .cakePlaced:
            VStack(spacing: 12) {
                hint("点击蛋糕把它炸开，看看里面藏了什么")
                Button("重新放置") { coordinator.reset() }
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
