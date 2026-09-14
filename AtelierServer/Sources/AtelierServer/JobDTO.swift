// AtelierServer — bulk-import job wire contract + ledger seam (015 · decision 3A).
//
// The thin `POST /jobs` open/close handshake that wraps the UNCHANGED per-item
// ingest hot path. The extension opens a job, tags each item POST with `jobId` +
// `sourceId` (see `CaptureRequest`), asks `known-sources` to skip re-downloading
// what already landed (P14), and closes the job when the cursor terminates.
//
// `JobLedger` is the seam the routes depend on (not `AppServices` directly —
// mirrors `CaptureRoutes`' closure seams so the pure route tests use a fake), and
// `AppServices` conforms to it verbatim (the method signatures already match — DRY).
//
// One `JobResponse` union DTO with optional fields + factory methods mirrors
// `CaptureResponse` (CQ2 style), so the transport encodes every job route the
// same way.

import Foundation
import AtelierCore

// MARK: - The ledger seam

/// The app-side job ledger the routes drive. `AppServices` conforms verbatim
/// (its method signatures already match), so the routes stay decoupled from the
/// concrete store and the pure route tests inject a fake (T11).
public protocol JobLedger: Sendable {
    func createJob(platform: Platform, scope: String?, totalEstimate: Int?) async throws -> Job
    @discardableResult
    func recordJobItem(
        jobID: UUID, sourceID: String, sourceURL: String?,
        status: JobItemStatus, blobHash: String?
    ) async throws -> JobItem
    func knownSourceIDs(forJob jobID: UUID) async throws -> Set<String>
    func setJobStatus(jobID: UUID, to status: JobStatus) async throws
    /// A running sweep's heartbeat: raise its skipped tally, and keep an `open` job
    /// off the 90s staleness reconciler. Returns the job's current status; it never
    /// changes it. `.notFound` if the job is absent.
    @discardableResult
    func recordJobProgress(jobID: UUID, skipped: Int, now: Date) async throws -> JobStatus
    /// A job's current lifecycle status — the relay feedback the ingest route
    /// stamps on each tagged item's response so a running sweep honours an app-side
    /// pause/cancel (7A). `.notFound` if the job is absent.
    func jobStatus(forJob jobID: UUID) async throws -> JobStatus
}

extension AppServices: JobLedger {}

// MARK: - Request DTOs

/// `POST /jobs` body — open a sweep. `platform` is validated against ``Platform``
/// during decode; `scope`/`totalEstimate` are optional hints. `resumeJobId` (task 8)
/// asks the server to REOPEN that job — so a resumed sweep continues one ledger row
/// instead of minting a fresh job each run — when it's still resumable.
public struct CreateJobRequest: Codable, Equatable, Sendable {
    public var platform: String
    public var scope: String?
    public var totalEstimate: Int?
    public var resumeJobId: UUID?

    public init(
        platform: String, scope: String? = nil, totalEstimate: Int? = nil,
        resumeJobId: UUID? = nil
    ) {
        self.platform = platform
        self.scope = scope
        self.totalEstimate = totalEstimate
        self.resumeJobId = resumeJobId
    }
}

/// `POST /jobs/{id}/complete` body — close/transition a sweep. `status` is
/// optional and defaults to `"complete"`; `"paused"` / `"halted"` cover the 7A
/// pause-on-wall / halt transitions through the same route.
public struct CompleteJobRequest: Codable, Equatable, Sendable {
    public var status: String?

    public init(status: String? = nil) {
        self.status = status
    }
}

/// `POST /jobs/{id}/progress` body — one heartbeat from a running sweep. `skipped`
/// is the live count of already-known items the sweep has passed over, which the app
/// cannot derive (a dedup skip is never relayed, so it leaves no `job_item`). Optional
/// and defaulting to 0: a sweep in a relay-free stretch with nothing new to report is
/// still saying it is alive, which is the point of the route.
public struct JobProgressRequest: Codable, Equatable, Sendable {
    public var skipped: Int?

    public init(skipped: Int? = nil) {
        self.skipped = skipped
    }
}

// MARK: - Response DTOs

/// The server's own resource caps, surfaced to the extension at job-open (8A) so
/// it reads them instead of hardcoding (kills the `MAX_VIDEO_BYTES` hand-sync).
public struct CapsDTO: Codable, Equatable, Sendable {
    public var maxBodyBytes: Int
    public var maxVideoBodyBytes: Int

    public init(maxBodyBytes: Int, maxVideoBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
        self.maxVideoBodyBytes = maxVideoBodyBytes
    }
}

/// The union response for every job route (mirrors ``CaptureResponse``): `status`
/// names the shape, the rest are optional per-route payloads.
public struct JobResponse: Codable, Equatable, Sendable {
    public var status: String
    public var jobId: UUID?
    public var caps: CapsDTO?
    public var sourceIds: [String]?
    /// The job's lifecycle status after a `/progress` ping, so the sweep learns it has
    /// been paused or cancelled without waiting for its next relay. Same field name as
    /// ``CaptureResponse/jobStatus`` — one spelling for one fact across both routes.
    public var jobStatus: String?
    public var error: String?

    public init(
        status: String, jobId: UUID? = nil, caps: CapsDTO? = nil,
        sourceIds: [String]? = nil, jobStatus: String? = nil, error: String? = nil
    ) {
        self.status = status
        self.jobId = jobId
        self.caps = caps
        self.sourceIds = sourceIds
        self.jobStatus = jobStatus
        self.error = error
    }

    public static func created(jobId: UUID, caps: CapsDTO) -> JobResponse {
        JobResponse(status: "created", jobId: jobId, caps: caps)
    }
    public static func knownSources(_ sourceIds: [String]) -> JobResponse {
        JobResponse(status: "known_sources", sourceIds: sourceIds)
    }
    public static func ok() -> JobResponse {
        JobResponse(status: "ok")
    }
    /// A heartbeat was recorded. Carries the job's CURRENT status (the ping never
    /// changes it) so the extension can see a pause/cancel it has not relayed into yet.
    public static func progress(jobStatus: JobStatus) -> JobResponse {
        JobResponse(status: "progress", jobStatus: jobStatus.rawValue)
    }
    public static func error(_ message: String) -> JobResponse {
        JobResponse(status: "error", error: message)
    }
    /// The user hasn't accepted the bulk-import consent yet — the app gates the
    /// first sweep on it (7A / legal framing). Distinct from `error` so the
    /// extension can tell the user to accept consent in the app, not retry.
    public static func consentRequired() -> JobResponse {
        JobResponse(
            status: "consent_required",
            error: "Bulk import is off. Open ref-atelier and accept the bulk-import notice to enable it.")
    }
}

// MARK: - Pure decode helpers

/// Why a job request body was unusable. Each maps to a 400 (see ``JobRoutes``).
public enum JobDecodeError: Error, Equatable {
    case malformedJSON
    case unknownPlatform(String)
    case invalidStatus(String)
    case invalidCount(Int)

    public var message: String {
        switch self {
        case .malformedJSON: return "Request body is not valid job JSON."
        case .unknownPlatform(let value): return "Unknown platform '\(value)'."
        case .invalidStatus(let value):
            return "Invalid job status '\(value)' (expected complete, paused, or halted)."
        case .invalidCount(let value):
            return "Invalid skipped count \(value) (must not be negative)."
        }
    }
}

public enum JobDecoder {
    /// Validate a `POST /jobs` body into a platform + hints (+ an optional
    /// `resumeJobId` for task-8 same-job resume).
    public static func decodeCreate(
        body: Data
    ) throws -> (platform: Platform, scope: String?, totalEstimate: Int?, resumeJobId: UUID?) {
        let request: CreateJobRequest
        do {
            request = try JSONDecoder().decode(CreateJobRequest.self, from: body)
        } catch {
            throw JobDecodeError.malformedJSON
        }
        guard let platform = Platform(rawValue: request.platform) else {
            throw JobDecodeError.unknownPlatform(request.platform)
        }
        return (platform, request.scope, request.totalEstimate, request.resumeJobId)
    }

    /// Validate a `POST /jobs/{id}/complete` body into a target status. An empty
    /// body or absent `status` defaults to `.complete`; only the three terminal/
    /// pause transitions are accepted (never back to `.open`).
    public static func decodeComplete(body: Data) throws -> JobStatus {
        // An empty body is a valid "complete" (the common close call).
        guard !body.isEmpty else { return .complete }
        let request: CompleteJobRequest
        do {
            request = try JSONDecoder().decode(CompleteJobRequest.self, from: body)
        } catch {
            throw JobDecodeError.malformedJSON
        }
        guard let raw = request.status else { return .complete }
        switch raw {
        case "complete": return .complete
        case "paused": return .paused
        case "halted": return .halted
        default: throw JobDecodeError.invalidStatus(raw)
        }
    }

    /// Validate a `POST /jobs/{id}/progress` body into a skipped count. An empty body
    /// or an absent `skipped` is 0 (a bare "still here"). A NEGATIVE count is rejected
    /// rather than tolerated: `MAX` would silently absorb it, leaving a client bug that
    /// under-reports progress with nothing anywhere to show for it.
    public static func decodeProgress(body: Data) throws -> Int {
        guard !body.isEmpty else { return 0 }
        let request: JobProgressRequest
        do {
            request = try JSONDecoder().decode(JobProgressRequest.self, from: body)
        } catch {
            throw JobDecodeError.malformedJSON
        }
        let skipped = request.skipped ?? 0
        guard skipped >= 0 else { throw JobDecodeError.invalidCount(skipped) }
        return skipped
    }
}
