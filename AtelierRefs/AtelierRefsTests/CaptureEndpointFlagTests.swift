//
//  CaptureEndpointFlagTests.swift
//  AtelierRefsTests
//
//  099 · 22A — the launch argument that keeps the capture endpoint out of the UI
//  stage.
//
//  **What these tests can and cannot say.** The predicate is a pure function of an
//  argument vector, so its rule is testable here and is tested here. Whether the app
//  then actually skips `startCaptureEndpoint` is a statement about a running process,
//  and the thing that asserts it is the UI stage itself: `SmokeUITests` passes with
//  the flag and hung for 30 s on all three flows without it. A unit test cannot make
//  that claim — `IngestionModel.bootstrap()` runs off `init()` against a real library
//  — and one that pretended to would be asserting its own mock.
//
//  The suite is inside `#if DEBUG` because the type is (8A). That is not a hole: a
//  Release build has no `CaptureEndpointFlag` and no guard reading it, which is the
//  property, and `verify.sh`'s `App target (Release)` stage is what checks that the
//  other side of the `#if` still compiles.
//

#if DEBUG

import Testing

@testable import AtelierRefs

@Suite("CaptureEndpointFlag (099 · 22A)")
struct CaptureEndpointFlagTests {

    @Test("the flag's spelling is the one SmokeUITests passes")
    func spelling() {
        // The two sides are separate modules — the UI bundle runs against the built
        // app and cannot import this — so the string is written down twice on
        // purpose and this is the assertion that keeps the copies honest. Change it
        // here and `SmokeUITests.launch()` has to change with it, or the endpoint
        // starts again and the flows go back to timing out on a keychain prompt.
        #expect(CaptureEndpointFlag.argument == "-skip-capture-endpoint")
        // A leading dash and no value: it is a BARE flag, which is why it goes last
        // in the launch-argument array (`UserDefaults` would otherwise read it as a
        // `-key value` pair's key). See `SmokeUITests.launch()`.
        #expect(CaptureEndpointFlag.argument.hasPrefix("-"))
    }

    @Test("with the flag present, the endpoint is skipped")
    func present() {
        #expect(CaptureEndpointFlag.isRequested(in: [CaptureEndpointFlag.argument]))
        // Where the UI test actually puts it: last, after a pair and another flag.
        #expect(CaptureEndpointFlag.isRequested(in: [
            "/path/to/AtelierRefs",
            "-AtelierDidCompleteOnboarding", "YES",
            "-seed-fixture-library",
            CaptureEndpointFlag.argument,
        ]))
    }

    @Test("without the flag, nothing is skipped")
    func absent() {
        // The default arm, and the one that matters most: every ordinary launch of
        // the app takes it, so a bug here would silently unpair every user's
        // extension rather than only affecting a test.
        #expect(!CaptureEndpointFlag.isRequested(in: []))
        #expect(!CaptureEndpointFlag.isRequested(in: [
            "/path/to/AtelierRefs",
            "-AtelierDidCompleteOnboarding", "YES",
            "-seed-fixture-library",
        ]))
        // A near-miss is not a match. `contains` is exact, and this says so rather
        // than leaving a future `hasPrefix` refactor free to make it not be.
        #expect(!CaptureEndpointFlag.isRequested(in: ["-skip-capture-endpoints"]))
        #expect(!CaptureEndpointFlag.isRequested(in: ["skip-capture-endpoint"]))
    }
}

#endif
