//
//  WillBirthCakeApp.swift
//  WillBirthCake
//
//  Replaces the template's hand-rolled `UIWindow` AppDelegate. That window was
//  created without a scene, so `window.windowScene` was always nil — and the Vision
//  orientation mapping, which reads the interface orientation through the scene,
//  would have silently fallen back to portrait on every device rotation.
//

import SwiftUI

@main
struct WillBirthCakeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
