// AtelierServer — the capture REPLY (build-order #6, decision CQ2).
//
// Split out of `CaptureDTO.swift` when the request half moved to AtelierCapture
// (092 · S0). The line between them is "does a producer of captures need this?":
// the request shape and its decode funnel have two producers now (the browser
// extension over HTTP, the iOS share extension into the inbox), while a reply is
// something only a SERVER has — a capture written to a directory has nobody to
// answer. So the contract travels and the response stays here, beside the routes
// that send it.
//
// `JobResponse` (JobDTO.swift) deliberately mirrors this shape, so every route
// this server exposes encodes the same way.

import Foundation

/// The capture response: `status` is `"ingested"` or `"error"`. On success the
/// new asset's id + whether the bytes deduplicated against an existing blob; on
/// failure a human-readable reason.
public struct CaptureResponse: Codable, Equatable, Sendable {
    public var status: String
    public var assetId: UUID?
    public var deduplicated: Bool?
    public var error: String?
    /// The owning job's current lifecycle status, stamped ONLY on a bulk-tagged
    /// capture's reply (7A relay feedback): when the user pauses/cancels in the app,
    /// the next item's response carries `paused`/`halted` and the extension halts the
    /// sweep. Absent (nil, unencoded) on ordinary single-item captures — the wire is
    /// unchanged for the existing path.
    public var jobStatus: String?
    /// The running app's version — stamped ONLY on the `/health` reply (010 · Phase
    /// 3 handshake). Absent (nil, unencoded) on captures, so the ingest wire is
    /// unchanged.
    public var appVersion: String?
    /// The oldest / newest extension version this app supports, on `/health` only.
    /// The extension compares its own version against this range and warns on a
    /// mismatch instead of drifting silently.
    public var minExtensionVersion: String?
    public var maxExtensionVersion: String?

    public init(
        status: String, assetId: UUID? = nil,
        deduplicated: Bool? = nil, error: String? = nil, jobStatus: String? = nil,
        appVersion: String? = nil,
        minExtensionVersion: String? = nil, maxExtensionVersion: String? = nil
    ) {
        self.status = status
        self.assetId = assetId
        self.deduplicated = deduplicated
        self.error = error
        self.jobStatus = jobStatus
        self.appVersion = appVersion
        self.minExtensionVersion = minExtensionVersion
        self.maxExtensionVersion = maxExtensionVersion
    }

    /// The `/health` reply (010 · Phase 3): liveness + the version handshake.
    public static func health(
        appVersion: String, minExtensionVersion: String, maxExtensionVersion: String
    ) -> CaptureResponse {
        CaptureResponse(
            status: "ok", appVersion: appVersion,
            minExtensionVersion: minExtensionVersion,
            maxExtensionVersion: maxExtensionVersion)
    }

    public static func ingested(
        assetId: UUID, deduplicated: Bool, jobStatus: String? = nil
    ) -> CaptureResponse {
        CaptureResponse(
            status: "ingested", assetId: assetId, deduplicated: deduplicated,
            jobStatus: jobStatus)
    }

    public static func error(_ message: String) -> CaptureResponse {
        CaptureResponse(status: "error", error: message)
    }
}
