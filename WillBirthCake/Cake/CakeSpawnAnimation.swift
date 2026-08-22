//
//  CakeSpawnAnimation.swift
//  WillBirthCake
//
//  The cake's entrance: scale up from nothing, overshoot slightly, settle at full
//  size.
//
//  Driven frame by frame off the scene update rather than through
//  `Entity.move(to:duration:)`. Two chained moves would need the second to start
//  exactly when the first ends — either by sleeping for the first one's duration,
//  which drifts, or by listening for a completion event — and neither gives control
//  over the shape of the curve between the two.
//

import Combine
import Foundation
import RealityKit
import simd

@MainActor
enum CakeSpawnAnimation {

    enum Tuning {
        static let duration: TimeInterval = 0.55
        /// Back-easing tension. The classic 1.70158 is not arbitrary: it puts the
        /// curve's peak at 1.0999 — the requested 10% overshoot — at t ≈ 0.58,
        /// leaving the rest of the duration to settle back to 1.
        static let tension: Float = 1.70158
    }

    /// Scales `entity` from zero to its full size with a single overshoot.
    ///
    /// Safe to call on an entity that may be removed mid-flight: the subscription
    /// cancels itself if the entity leaves the scene.
    static func play(on entity: Entity, in scene: RealityKit.Scene) {
        let finalScale = entity.scale
        entity.scale = .zero

        var elapsed: TimeInterval = 0
        // Captured by the handler, so the subscription keeps itself alive. The
        // reference cycle is deliberate and is broken by `cancel()` below.
        var token: (any Cancellable)?

        token = scene.subscribe(to: SceneEvents.Update.self) { event in
            // The cake was reset or removed before the animation finished.
            guard entity.parent != nil else {
                token?.cancel()
                token = nil
                return
            }

            elapsed += event.deltaTime
            let progress = min(Float(elapsed / Tuning.duration), 1)
            entity.scale = finalScale * easeOutBack(progress)

            if progress >= 1 {
                // Snapped rather than left on the curve's last sample, so the cake
                // ends at exactly its authored size.
                entity.scale = finalScale
                token?.cancel()
                token = nil
            }
        }
    }

    /// Starts at 0, overshoots past 1, settles back to 1.
    private static func easeOutBack(_ t: Float) -> Float {
        let c1 = Tuning.tension
        let c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }
}
