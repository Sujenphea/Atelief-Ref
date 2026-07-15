//
//  FanRotationsTests.swift
//  AtelierRefsTests
//
//  009 · N4 — the stack-card fan tilt must be PROCESS-STABLE: the same collection
//  UUID always yields the same angles, so the pile never re-jitters on a refresh
//  or a relaunch. Guards determinism, bounds, count, and the empty case.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("Stack-card fan rotations")
struct FanRotationsTests {

    private let seed = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    private let other = UUID(uuidString: "FEDCBA09-8765-4321-FEDC-BA0987654321")!

    @Test("same seed + count → identical angles (stable across calls)")
    func deterministic() {
        #expect(fanRotations(seed: seed, count: 3) == fanRotations(seed: seed, count: 3))
    }

    @Test("all angles stay within ±maxDegrees")
    func withinBounds() {
        for angle in fanRotations(seed: seed, count: 3, maxDegrees: 8) {
            #expect(angle >= -8 && angle <= 8)
        }
        for angle in fanRotations(seed: other, count: 3, maxDegrees: 5) {
            #expect(angle >= -5 && angle <= 5)
        }
    }

    @Test("returns exactly `count` angles")
    func countMatches() {
        #expect(fanRotations(seed: seed, count: 1).count == 1)
        #expect(fanRotations(seed: seed, count: 3).count == 3)
        #expect(fanRotations(seed: seed, count: 5).count == 5)
    }

    @Test("count 0 yields no angles")
    func emptyCount() {
        #expect(fanRotations(seed: seed, count: 0).isEmpty)
    }

    @Test("different seeds generally produce different fans (not all identical)")
    func seedsDiffer() {
        // Not a strict guarantee, but a regression tripwire: two very different
        // UUIDs should not collapse to the same angle sequence.
        #expect(fanRotations(seed: seed, count: 3) != fanRotations(seed: other, count: 3))
    }
}
