//
//  Diagnostics.swift
//  AtelierRefs
//
//  010 · Phase 3 — a user-initiated diagnostics export. Gathers versions + store
//  stats (NEVER library content) into a plain-text report the user can attach to
//  a bug report. Local-first: no crash reporter, no network — MetricKit + this
//  manual export only (010 group 5, recommended path).
//
//  The report BUILDER is a pure function over ``DiagnosticsFacts`` so it's unit
//  tested; the model gathers the facts and writes/reveals the file.
//

import Foundation
import OSLog

/// The shared logging namespace (010 · Phase 3). New logging should route through
/// `AppLog.<area>` rather than ad-hoc `Logger` instances, so diagnostics + Console
/// filtering stay consistent.
enum AppLog {
    static let subsystem = "com.atelierrefs.app"
    static let model = Logger(subsystem: subsystem, category: "model")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}

/// The non-sensitive facts a diagnostics report is built from. No titles, URLs,
/// tags, image bytes, or any library CONTENT — only environment + counts/sizes.
struct DiagnosticsFacts {
    var appVersion: String
    var appBuild: String
    var osVersion: String
    var supportedExtensionRange: String
    var capturePort: Int
    var captureEndpointRunning: Bool
    var libraryPath: String?
    var databaseFileSizeBytes: Int64?
    var snapshotCount: Int
    var generatedAt: Date
}

enum DiagnosticsReport {
    /// Render the plain-text report. Pure + deterministic given `facts` (the
    /// timestamp is a field, not `Date()`), so it's unit-testable.
    static func text(from f: DiagnosticsFacts) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("AtelierRefs Diagnostics")
        lines.append("=======================")
        lines.append("Generated:   \(iso.string(from: f.generatedAt))")
        lines.append("")
        lines.append("App version: \(f.appVersion) (\(f.appBuild))")
        lines.append("macOS:       \(f.osVersion)")
        lines.append("Extension supported: \(f.supportedExtensionRange)")
        lines.append("")
        lines.append("Capture endpoint: 127.0.0.1:\(f.capturePort) "
            + "(\(f.captureEndpointRunning ? "running" : "not running"))")
        lines.append("")
        lines.append("Library path: \(f.libraryPath ?? "(unopened)")")
        lines.append("Database size: \(byteString(f.databaseFileSizeBytes))")
        lines.append("Snapshots on disk: \(f.snapshotCount)")
        lines.append("")
        lines.append("This report contains no library content — only versions, "
            + "sizes, and counts.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Human byte size, or "—" when unknown.
    static func byteString(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
