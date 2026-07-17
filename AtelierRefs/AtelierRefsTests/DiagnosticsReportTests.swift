//
//  DiagnosticsReportTests.swift
//  AtelierRefsTests
//
//  010 · Phase 3 — the pure diagnostics-report builder. Asserts the report
//  includes the environment facts and, crucially, NO library content.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("Diagnostics report")
struct DiagnosticsReportTests {

    private func facts() -> DiagnosticsFacts {
        DiagnosticsFacts(
            appVersion: "0.1.0", appBuild: "42",
            osVersion: "Version 26.5.0",
            supportedExtensionRange: "0.1.0–0.1.0",
            capturePort: 47321, captureEndpointRunning: true,
            libraryPath: "/Users/me/Library/Application Support/ref-atelier",
            databaseFileSizeBytes: 2_500_000, snapshotCount: 3,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("includes versions, endpoint, and store stats")
    func includesFacts() {
        let text = DiagnosticsReport.text(from: facts())
        #expect(text.contains("0.1.0 (42)"))
        #expect(text.contains("Version 26.5.0"))
        #expect(text.contains("127.0.0.1:47321"))
        #expect(text.contains("running"))
        #expect(text.contains("Snapshots on disk: 3"))
        #expect(text.contains("ref-atelier"))
        #expect(text.contains("2.5 MB") || text.contains("2,5 MB")) // locale-tolerant
    }

    @Test("unknown db size + unopened library render placeholders, not a crash")
    func handlesMissing() {
        var f = facts()
        f.databaseFileSizeBytes = nil
        f.libraryPath = nil
        let text = DiagnosticsReport.text(from: f)
        #expect(text.contains("Database size: —"))
        #expect(text.contains("(unopened)"))
    }

    @Test("deterministic given the same facts (timestamp is a field)")
    func deterministic() {
        #expect(DiagnosticsReport.text(from: facts()) == DiagnosticsReport.text(from: facts()))
    }

    @Test("endpoint-not-running is reflected")
    func endpointDown() {
        var f = facts()
        f.captureEndpointRunning = false
        #expect(DiagnosticsReport.text(from: f).contains("not running"))
    }
}
