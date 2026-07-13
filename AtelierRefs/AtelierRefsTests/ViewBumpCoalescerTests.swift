//
//  ViewBumpCoalescerTests.swift
//  AtelierRefsTests
//
//  007 G4 — the pure view-bump coalescer: repeated opens of one asset collapse
//  to a single bump, distinct assets each get one, and drain empties the buffer.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("ViewBumpCoalescer (007 G4)")
struct ViewBumpCoalescerTests {

    @Test("recording the same asset N times drains to one bump")
    func collapsesRepeats() {
        var c = ViewBumpCoalescer()
        let a = UUID()
        c.record(a); c.record(a); c.record(a)
        #expect(c.drain() == [a])
    }

    @Test("distinct assets each drain once")
    func distinctAssets() {
        var c = ViewBumpCoalescer()
        let a = UUID(), b = UUID()
        c.record(a); c.record(b); c.record(a)
        #expect(Set(c.drain()) == [a, b])
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
        #expect(c.drain() == [a])
    }

    @Test("an untouched coalescer is empty and drains to nothing")
    func emptyByDefault() {
        var c = ViewBumpCoalescer()
        #expect(c.isEmpty)
        #expect(c.drain().isEmpty)
    }
}
