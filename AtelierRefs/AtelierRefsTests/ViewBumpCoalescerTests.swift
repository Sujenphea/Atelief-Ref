//
//  ViewBumpCoalescerTests.swift
//  AtelierRefsTests
//
//  007 G4 / 036 §3 B4 — the pure view-bump coalescer. `drain()` returns PER-ID
//  counts (`[UUID: Int]`) as of B4: repeated opens of one asset now accumulate a
//  count (were collapsed to a set), distinct assets each get their own count, and
//  drain empties the buffer.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("ViewBumpCoalescer (007 G4 / 036 B4)")
struct ViewBumpCoalescerTests {

    @Test("recording the same asset N times drains to that count")
    func countsRepeats() {
        var c = ViewBumpCoalescer()
        let a = UUID()
        c.record(a); c.record(a); c.record(a)
        #expect(c.drain() == [a: 3])
    }

    @Test("distinct assets each drain with their own count")
    func distinctAssets() {
        var c = ViewBumpCoalescer()
        let a = UUID(), b = UUID()
        c.record(a); c.record(b); c.record(a)
        #expect(c.drain() == [a: 2, b: 1])
    }

    @Test("drain empties the buffer; a fresh window starts clean")
    func drainEmpties() {
        var c = ViewBumpCoalescer()
        let a = UUID()
        c.record(a)
        #expect(!c.isEmpty)
        _ = c.drain()
        #expect(c.isEmpty)
        #expect(c.drain().isEmpty)         // second drain yields nothing

        // A new open after a drain is a new, countable view.
        c.record(a)
        #expect(c.drain() == [a: 1])
    }

    @Test("an untouched coalescer is empty and drains to nothing")
    func emptyByDefault() {
        var c = ViewBumpCoalescer()
        #expect(c.isEmpty)
        #expect(c.drain().isEmpty)
    }
}
