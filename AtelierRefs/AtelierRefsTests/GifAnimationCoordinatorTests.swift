//
//  GifAnimationCoordinatorTests.swift
//  AtelierRefsTests
//
//  011-B5 — the single-slot GIF animation coordinator (`GifMotion.swift`), which
//  the AppKit `MasonryGridItem` claims/releases on hover dwell so a grid of GIFs
//  never animates more than one at a time. Split out of the retired
//  `GridWindowingTests` (189 — SwiftUI bake-off/windowing retirement): the
//  windowing math it lived beside is deleted, but this coordinator is live.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("GifAnimationCoordinator: single-slot + idempotent release")
@MainActor
struct GifCoordinatorTests {

    @Test("release is idempotent — a double release leaves the slot free, never underflows")
    func idempotentRelease() {
        let coordinator = GifAnimationCoordinator()
        let a = UUID(), b = UUID()
        #expect(coordinator.claim(a) == true)
        coordinator.release(a)
        coordinator.release(a)              // second release — no-op, not a crash
        #expect(coordinator.claim(b) == true)   // slot is genuinely free again
    }

    @Test("a stale release from a non-holder never frees the holder's slot")
    func staleReleaseNoOp() {
        let coordinator = GifAnimationCoordinator()
        let a = UUID(), b = UUID()
        #expect(coordinator.claim(a) == true)
        coordinator.release(b)              // b never held it → no-op
        #expect(coordinator.claim(b) == false)   // a still holds the slot
    }
}
