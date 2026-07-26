//
//  CanvasFontTests.swift
//  CanvasRendererTests
//
//  054 §2.1 (2A · R10) — the single, memoized font source. Assert the RESOLVED
//  font's family / weight / pointSize (never pixels): a nil family → the system
//  font at the mapped weight; a known family resolves to that family; an unknown
//  family falls back to system (never nil, never blank). The typeface only changes
//  on a style edit, so it is memoized by `(family, weight)`.
//

import AppKit
import CoreText
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("CanvasFont resolution")
struct CanvasFontTests {

    private func family(of font: CTFont) -> String { CTFontCopyFamilyName(font) as String }
    private func pointSize(of font: CTFont) -> CGFloat { CTFontGetSize(font) }
    /// The normalized weight trait (-1…1); heavier faces score higher.
    private func weightTrait(of font: CTFont) -> CGFloat {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait as String] as? CGFloat) ?? 0
    }

    @Test("a nil family resolves to the system font at the mapped weight + reference size")
    func nilFamilyIsSystem() {
        let resolved = CanvasFont.resolve(family: nil, weight: .regular)
        let system = NSFont.systemFont(ofSize: CanvasFont.referenceSize, weight: .regular)
        #expect(family(of: resolved) == system.familyName)
        #expect(pointSize(of: resolved) == CanvasFont.referenceSize)
    }

    @Test("an empty family string is treated as the system sentinel")
    func emptyFamilyIsSystem() {
        let resolved = CanvasFont.resolve(family: "", weight: .regular)
        let system = NSFont.systemFont(ofSize: CanvasFont.referenceSize, weight: .regular)
        #expect(family(of: resolved) == system.familyName)
    }

    @Test("a known family resolves to that family at the reference size")
    func knownFamilyResolves() {
        let resolved = CanvasFont.resolve(family: "Helvetica", weight: .regular)
        #expect(family(of: resolved) == "Helvetica")
        #expect(pointSize(of: resolved) == CanvasFont.referenceSize)
    }

    @Test("an unknown family falls back to the system font (never blank)")
    func unknownFamilyFallsBack() {
        let resolved = CanvasFont.resolve(family: "NoSuchFontZZZ_12345", weight: .regular)
        let system = NSFont.systemFont(ofSize: CanvasFont.referenceSize, weight: .regular)
        #expect(family(of: resolved) == system.familyName)
    }

    @Test("weight is honoured: bold is heavier than regular (system path)")
    func weightIsHonouredSystem() {
        let regular = CanvasFont.resolve(family: nil, weight: .regular)
        let bold = CanvasFont.resolve(family: nil, weight: .bold)
        #expect(weightTrait(of: bold) > weightTrait(of: regular))
    }

    @Test("all four weights resolve non-nil at the reference size, weakly monotonic")
    func allWeightsResolve() {
        let weights: [FontWeight] = [.regular, .medium, .semibold, .bold]
        let traits = weights.map { weightTrait(of: CanvasFont.resolve(family: nil, weight: $0)) }
        for w in weights { #expect(pointSize(of: CanvasFont.resolve(family: nil, weight: w)) == CanvasFont.referenceSize) }
        // Non-decreasing across the ordered set (system faces get heavier).
        #expect(zip(traits, traits.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("resolution is memoized: the same (family, weight) yields the same font")
    func memoized() {
        let a = CanvasFont.resolve(family: "Helvetica", weight: .semibold)
        let b = CanvasFont.resolve(family: "Helvetica", weight: .semibold)
        #expect(CFEqual(a, b))
    }
}
