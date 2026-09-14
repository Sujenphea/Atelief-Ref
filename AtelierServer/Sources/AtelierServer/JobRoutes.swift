// AtelierServer — bulk-import job route logic (015 · decision 3A / A4).
//
// The PURE (socket-free) heart of the `/jobs` handshake: decode → drive the
// ``JobLedger`` → map to a `JobResponse` + HTTP status. Mirrors `CaptureRoutes`
// (values in, values out), so the whole matrix is unit-tested against a fake
// ledger with no socket, and the transport just wraps the result with CORS.
//
// Security: these routes carry NO new auth — the transport gates every request
// (including `/jobs`) through the same `CaptureAuth` token + Origin barrier (A4).

import Foundation
import AtelierCore

/// A job route's HTTP status + JSON body, before the FlyingFox layer serializes
/// it. Parallels ``HandlerResult`` but over ``JobResponse``.
public struct JobHandlerResult: Equatable, Sendable {
    public let statusCode: Int
    public let response: JobResponse

    public init(statusCode: Int, response: JobResponse) {
        self.statusCode = statusCode
        self.response = response
    }
}

/// The `/jobs` handshake logic, independent of the HTTP transport.
public struct JobRoutes: Sendable {
    private let ledger: JobLedger
    /// The server's resource caps, surfaced at job-open (8A).
    private let caps: CapsDTO
    /// Whether the user has accepted the bulk-import consent (7A / legal framing).
    /// A closure so the app can flip it live (it reads the persisted flag), and the
    /// routes never reach into app state directly. Defaults to granted for a build
    /// without the consent gate (tests / headless).
    private let consentGranted: @Sendable () -> Bool

    public init(
        ledger: JobLedger, caps: CapsDTO,
        consentGranted: @escaping @Sendable () -> Bool = { true }
    ) {
        self.ledger = ledger
        self.caps = caps
        self.consentGranted = consentGranted
    }

    /// `POST /jobs` — open a sweep. 201 + `{ jobId, caps }` on success, 403 +
    /// `consent_required` before consent, 400 on a bad body/platform. Never throws.
    public func handleCreateJob(body: Data) async -> JobHandlerResult {
        // Gate the first sweep on consent (7A) — checked before anything else so an
        // un-consented open always says so, regardless of body validity.
        guard consentGranted() else {
            return JobHandlerResult(statusCode: 403, response: .consentRequired())
        }
        let decoded: (platform: Platform, scope: String?, totalEstimate: Int?, resumeJobId: UUID?)
        do {
            decoded = try JobDecoder.decodeCreate(body: body)
        } catch let error as JobDecodeError {
            return JobHandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return JobHandlerResult(statusCode: 400, response: .error("Bad request."))
        }
        do {
            let jobId = try await openOrReopen(decoded)
            return JobHandlerResult(statusCode: 201, response: .created(jobId: jobId, caps: caps))
        } catch {
            return Self.mapLedgerError(error)
        }
    }

    /// Reopen `resumeJobId` when it names a still-RESUMABLE job (task 8) — a sweep
    /// paused (by a user Pause or a wall) or left open — so a resumed run continues
    /// ONE ledger row instead of minting a fresh job every time. Anything else (no
    /// id, a terminal `complete`/`halted`, or an absent job) falls through to a new
    /// job, so a stale checkpoint can never revive a finished or cancelled sweep.
    private func openOrReopen(
        _ decoded: (platform: Platform, scope: String?, totalEstimate: Int?, resumeJobId: UUID?)
    ) async throws -> UUID {
        if let resumeID = decoded.resumeJobId,
           let status = try? await ledger.jobStatus(forJob: resumeID),
           status == .open || status == .paused {
            try await ledger.setJobStatus(jobID: resumeID, to: .open)
            return resumeID
        }
        let job = try await ledger.createJob(
            platform: decoded.platform, scope: decoded.scope,
            totalEstimate: decoded.totalEstimate)
        return job.id
    }

    /// `GET /jobs/{id}/known-sources` — the already-landed source ids for this
    /// job's platform, so the extension skips re-DOWNLOADING them (P14). 200 +
    /// `{ sourceIds }` (sorted for a stable wire), 404 if the job is absent.
    public func handleKnownSources(jobID: UUID) async -> JobHandlerResult {
        do {
            let known = try await ledger.knownSourceIDs(forJob: jobID)
            return JobHandlerResult(
                statusCode: 200, response: .knownSources(known.sorted()))
        } catch {
            return Self.mapLedgerError(error)
        }
    }

    /// `POST /jobs/{id}/complete` — close/transition a sweep (7A). Body optionally
    /// carries `{ status }` (default `complete`). 200 on success, 400 on a bad
    /// status, 404 if the job is absent.
    public func handleComplete(jobID: UUID, body: Data) async -> JobHandlerResult {
        let status: JobStatus
        do {
            status = try JobDecoder.decodeComplete(body: body)
        } catch let error as JobDecodeError {
            return JobHandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return JobHandlerResult(statusCode: 400, response: .error("Bad request."))
        }
        do {
            try await ledger.setJobStatus(jobID: jobID, to: status)
            return JobHandlerResult(statusCode: 200, response: .ok())
        } catch {
            return Self.mapLedgerError(error)
        }
    }

    /// `POST /jobs/{id}/progress` — a running sweep's heartbeat. Body optionally
    /// carries `{ skipped }` (default 0). 200 + the job's current status, 400 on a
    /// malformed body or a negative count, 404 if the job is absent.
    ///
    /// The sweep's ONLY other sign of life is a relayed item, and a sweep can go
    /// minutes without relaying one — a dedup skip never reaches this server at all —
    /// so without this the 90s staleness reconciler paused live sweeps out from under
    /// themselves. The reply carries the job's status but the extension deliberately
    /// does NOT halt on it yet: the pause/cancel handshake stays on the relay path
    /// (7A), and giving a heartbeat a second way to stop a sweep is its own change.
    public func handleProgress(jobID: UUID, body: Data) async -> JobHandlerResult {
        let skipped: Int
        do {
            skipped = try JobDecoder.decodeProgress(body: body)
        } catch let error as JobDecodeError {
            return JobHandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return JobHandlerResult(statusCode: 400, response: .error("Bad request."))
        }
        do {
            let status = try await ledger.recordJobProgress(
                jobID: jobID, skipped: skipped, now: Date())
            return JobHandlerResult(statusCode: 200, response: .progress(jobStatus: status))
        } catch {
            return Self.mapLedgerError(error)
        }
    }

    /// Map a thrown ledger error to a `JobHandlerResult`: an absent job is a 404
    /// (`AtelierError.notFound`), anything else a 500.
    private static func mapLedgerError(_ error: Error) -> JobHandlerResult {
        if case AtelierError.notFound = error {
            return JobHandlerResult(statusCode: 404, response: .error("Job not found."))
        }
        return JobHandlerResult(statusCode: 500, response: .error("Ledger failure."))
    }
}
