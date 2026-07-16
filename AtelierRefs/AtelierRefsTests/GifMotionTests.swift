//
//  GifMotionTests.swift
//  AtelierRefsTests
//
//  011-B5 · 8A/15A — the pure motion decision, exhaustively (the hover dwell,
//  the single-slot coordinator, and the NSImageView animation are manual-pass):
//  a GIF animates only when hovered with Reduce Motion off, and only within the
//  byte budget.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("GIF motion policy")
struct GifMotionTests {

    @Test("only a hovered GIF with Reduce Motion off animates")
    func decisionMatrix() {
        // The one true case.
        #expect(shouldAnimateGif(mimeType: "image/gif", reduceMotion: false, isHovering: true))
        // Not hovering.
        #expect(!shouldAnimateGif(mimeType: "image/gif", reduceMotion: false, isHovering: false))
        // Reduce Motion on — short-circuits before any decode.
        #expect(!shouldAnimateGif(mimeType: "image/gif", reduceMotion: true, isHovering: true))
        // Not a GIF (poster stays static).
        #expect(!shouldAnimateGif(mimeType: "image/jpeg", reduceMotion: false, isHovering: true))
        #expect(!shouldAnimateGif(mimeType: "image/png", reduceMotion: false, isHovering: true))
        #expect(!shouldAnimateGif(mimeType: "video/mp4", reduceMotion: false, isHovering: true))
        // Media-less / unknown mime.
        #expect(!shouldAnimateGif(mimeType: nil, reduceMotion: false, isHovering: true))
    }

    @Test("a GIF within budget animates; an oversized one stays static")
    func budget() {
        #expect(gifWithinBudget(fileSize: 5 * 1024 * 1024))                 // 5 MB → ok
        #expect(gifWithinBudget(fileSize: GifMotion.maxAnimatedBytes))      // exactly the cap → ok
        #expect(!gifWithinBudget(fileSize: GifMotion.maxAnimatedBytes + 1)) // over → static
        // Unknown size is allowed (defensive path — byte GIFs carry a size).
        #expect(gifWithinBudget(fileSize: nil))
    }

    @Test("the single-animation coordinator grants one slot at a time")
    @MainActor
    func coordinatorCap() {
        let coordinator = GifAnimationCoordinator()
        let a = UUID(), b = UUID()
        #expect(coordinator.claim(a))          // a wins the slot
        #expect(!coordinator.claim(b))         // b is refused while a holds it
        #expect(coordinator.claim(a))          // a re-claiming is fine
        coordinator.release(b)                 // a stale release is a no-op
        #expect(!coordinator.claim(b))         // a still holds it
        coordinator.release(a)                 // a lets go
        #expect(coordinator.claim(b))          // now b can take it
    }
}
