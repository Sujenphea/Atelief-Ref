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

/// The shared logging namespace (010 · Phase 3). New logging routes through
/// `AppLog.<area>` rather than ad-hoc `Logger` instances, so diagnostics + Console
/// filtering stay consistent.
///
/// That instruction had drifted: four subsystems were in use across one app —
/// `com.atelierrefs.app` here, `so.atelier.refs` in three hand-rolled `Logger`s, and
/// `so.atelier.capture` in the server — so no single Console filter showed the app's
/// output. There is now one, and it is the BUNDLE ID, which is what Console offers
/// to filter by and the only one of the four that matched anything real.
nonisolated enum AppLog {
    static let subsystem = "sujenphea.AtelierRefs"
    static let model = Logger(subsystem: subsystem, category: "model")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
    /// Library search (044/045).
    static let search = Logger(subsystem: subsystem, category: "search")
    /// The background analysis coordinator.
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    /// Per-batch ingest timing (059).
    static let ingestTiming = Logger(subsystem: subsystem, category: "ingest-timing")
    /// The item detail page's media path — `VideoPosterGate` in particular, whose
    /// three exits are otherwise invisible from outside the view (489).
    static let detail = Logger(subsystem: subsystem, category: "detail")
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
