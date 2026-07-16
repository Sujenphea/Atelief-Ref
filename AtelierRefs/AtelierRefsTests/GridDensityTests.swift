//
//  GridDensityTests.swift
//  AtelierRefsTests
//
//  011-B2 · 5A′/16A/12A — the density notch math and its persistence, exhaustively
//  (the toolbar / ⌘+/⌘− wiring is manual): the 512px width floor, the notch clamp,
//  stepping at the ends, and the UserDefaults round-trip + corrupt-value fallback.
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("GridDensity: notch + width clamp")
struct GridDensityTests {

    @Test("minColumns is ceil(width / 512), at least 1")
    func minColumns() {
        #expect(GridDensity.minColumns(forWidth: 512) == 1)
        #expect(GridDensity.minColumns(forWidth: 513) == 2)
        #expect(GridDensity.minColumns(forWidth: 1024) == 2)
        #expect(GridDensity.minColumns(forWidth: 1025) == 3)
        #expect(GridDensity.minColumns(forWidth: 100) == 1)
        // Degenerate widths never go below one column.
        #expect(GridDensity.minColumns(forWidth: 0) == 1)
        #expect(GridDensity.minColumns(forWidth: -10) == 1)
    }

    @Test("columns(forWidth:) floors to the 512 cap and caps at maxColumns")
    func columnsClampByWidth() {
        // A narrow window honours a low notch (cells stay under 512).
        #expect(GridDensity(columns: 3).columns(forWidth: 500) == 3)
        // A wide window RAISES the count so cells don't exceed 512 (16A).
        #expect(GridDensity(columns: 3).columns(forWidth: 2000) == 4)   // ceil(2000/512)=4
        // The absolute cap holds even if the stored notch is absurd.
        #expect(GridDensity(columns: 99).columns(forWidth: 500) == GridDensity.maxColumns)
        // Always at least one column.
        #expect(GridDensity(columns: 0).columns(forWidth: 300) == 1)
    }

    @Test("zoom in removes a column, stopping at the width floor")
    func zoomIn() {
        // width 500 → floor 1. Stepping down from 4 reaches 1 then stops.
        var d = GridDensity(columns: 4)
        d = d.zoomedIn(forWidth: 500); #expect(d.columns == 3)
        d = d.zoomedIn(forWidth: 500); #expect(d.columns == 2)
        d = d.zoomedIn(forWidth: 500); #expect(d.columns == 1)
        d = d.zoomedIn(forWidth: 500); #expect(d.columns == 1)   // floored
    }

    @Test("zoom in stops at the width-derived floor on a wide window")
    func zoomInWideFloor() {
        // width 2000 → floor ceil(2000/512)=4; can't zoom cells past 512.
        var d = GridDensity(columns: 6)
        d = d.zoomedIn(forWidth: 2000); #expect(d.columns == 5)
        d = d.zoomedIn(forWidth: 2000); #expect(d.columns == 4)
        d = d.zoomedIn(forWidth: 2000); #expect(d.columns == 4)   // floored, not 3
    }

    @Test("zoom out adds a column, stopping at maxColumns")
    func zoomOut() {
        var d = GridDensity(columns: GridDensity.maxColumns - 1)
        d = d.zoomedOut(forWidth: 500); #expect(d.columns == GridDensity.maxColumns)
        d = d.zoomedOut(forWidth: 500); #expect(d.columns == GridDensity.maxColumns)  // capped
    }
}

@MainActor
@Suite("GridViewPreferences: persistence")
struct GridViewPreferencesTests {

    /// A throwaway `UserDefaults` domain per test so nothing touches the real one.
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a set density round-trips through a fresh instance")
    func roundTrip() {
        let defaults = freshDefaults("test.griddensity.roundtrip")
        let prefs = GridViewPreferences(defaults: defaults)
        prefs.density = GridDensity(columns: 7)
        // A brand-new owner over the same store reads the persisted notch.
        let reloaded = GridViewPreferences(defaults: defaults)
        #expect(reloaded.density.columns == 7)
    }

    @Test("an absent key loads the default notch")
    func absentDefaults() {
        let prefs = GridViewPreferences(defaults: freshDefaults("test.griddensity.absent"))
        #expect(prefs.density == GridDensity.default)
    }

    @Test("a corrupt / out-of-range stored value falls back to the default")
    func corruptClamp() {
        let name = "test.griddensity.corrupt"
        let defaults = freshDefaults(name)
        for bad in [-3, 0, GridDensity.maxColumns + 1, 9999] {
            defaults.set(bad, forKey: "AtelierGridDensityColumns")
            let prefs = GridViewPreferences(defaults: defaults)
            #expect(prefs.density == GridDensity.default)
        }
    }

    @Test("zoomIn / zoomOut persist the stepped notch")
    func zoomPersists() {
        let defaults = freshDefaults("test.griddensity.zoom")
        let prefs = GridViewPreferences(defaults: defaults)
        prefs.density = GridDensity(columns: 4)
        prefs.zoomOut(forWidth: 500)   // → 5
        #expect(GridViewPreferences(defaults: defaults).density.columns == 5)
        prefs.zoomIn(forWidth: 500)    // → 4
        #expect(GridViewPreferences(defaults: defaults).density.columns == 4)
    }
}
