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

            statusBar
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch coordinator.phase {
        case .startingSession:
            hint("正在启动 AR…")

        case .unsupportedDevice:
            hint("这台设备不支持所需的 AR 深度功能。\n本项目需要带 LiDAR 的机型。")

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
