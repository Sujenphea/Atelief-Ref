// AtelierServer — the capture route logic (build-order #6, decisions CQ1/CQ2/P3).
//
// The PURE (socket-free) heart of the endpoint: decode a JSON body → build an
// `IngestInput` via the shared `DirectInputReader.remoteInput` seam → run it
// through the SAME bounded `IngestCoordinator` the app already uses (P2: no new
// queue), and map the outcome to a `CaptureResponse` + HTTP status (P3: respond
// after ingest so the reply is truthful). After each capture it fires
// `onCapture` so the app can refresh live (CQ1) — the server never imports the
// view model; it only hands back `(collectionID, outcomes)`.
//
// Because this takes raw `Data` and returns a value, it is exhaustively unit-
// tested against a real temp library (T1 pure layer + T3 mapping) with no socket.

import Foundation
import AtelierCore
import AtelierIngestion

/// A route's HTTP status + JSON body, before it is serialized by the FlyingFox
/// layer.
public struct HandlerResult: Equatable, Sendable {
    public let statusCode: Int
    public let response: CaptureResponse

    public init(statusCode: Int, response: CaptureResponse) {
        self.statusCode = statusCode
        self.response = response
    }
}

/// The capture endpoint's business logic, independent of the HTTP transport.
public struct CaptureRoutes: Sendable {
    private let coordinator: IngestCoordinator
    /// Resolves the target collection when the request omits `collectionId`
    /// (the app's default import folder). A closure so the routes never reach
    /// into `AppServices` state directly.
    private let defaultCollectionID: @Sendable () -> UUID
    /// Fired after every capture with the effective collection + outcomes, so the
    /// app can refresh the live UI (CQ1). Never called on the main actor by this
    /// type — the app hops as needed.
    private let onCapture: (@Sendable (UUID, [IngestOutcome]) -> Void)?
    /// The bulk-import ledger (015 · 3A). When a capture is tagged with a `jobId`
    /// + `sourceId`, its outcome is recorded as a `job_item`. `nil` for a build
    /// without bulk import; recording is best-effort (a failed ledger write never
    /// fails an already-completed ingest — the item is just re-downloadable later).
    private let jobLedger: JobLedger?

    public init(
        coordinator: IngestCoordinator,
        defaultCollectionID: @escaping @Sendable () -> UUID,
        onCapture: (@Sendable (UUID, [IngestOutcome]) -> Void)? = nil,
        jobLedger: JobLedger? = nil
    ) {
        self.coordinator = coordinator
        self.defaultCollectionID = defaultCollectionID
        self.onCapture = onCapture
        self.jobLedger = jobLedger
    }

    /// Ingest one capture from a raw JSON body — a byte-backed image or a
    /// media-less content item (003 · C3). `now` is the server-owned capture
    /// time. Never throws — every failure becomes a `HandlerResult`. Both kinds
    /// run through the SAME coordinator via ``ingest(_:into:jobID:sourceID:sourceURL:)``,
    /// so ledger recording + live-refresh + the 7A relay are shared.
    public func handleIngest(body: Data, now: Date) async -> HandlerResult {
        let decoded: DecodedInput
        do {
            decoded = try CaptureDecoder.decodeInput(body: body, now: now)
        } catch let error as CaptureDecodeError {
            return HandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return HandlerResult(statusCode: 400, response: .error("Bad request."))
        }

        switch decoded {
        case .image(let decoded):
            let collectionID = decoded.collectionID ?? defaultCollectionID()
            let input = DirectInputReader.remoteInput(
                imageData: decoded.imageData,
                provenance: decoded.provenance,
                into: collectionID)
            return await ingest(
                input, into: collectionID,
                jobID: decoded.jobID, sourceID: decoded.sourceID,
                sourceURL: decoded.provenance.originalURL)
        case .content(let decoded):
            let collectionID = decoded.collectionID ?? defaultCollectionID()
            let input = DirectInputReader.remoteContent(
                draft: decoded.draft,
                provenance: decoded.provenance,
                into: collectionID)
            return await ingest(
                input, into: collectionID,
                jobID: decoded.jobID, sourceID: decoded.sourceID,
                sourceURL: decoded.provenance.originalURL)
        }
    }

    /// Ingest one captured **video** from a temp file the transport already
    /// streamed to disk (its bytes never sit in memory as base64/JSON). Provenance
    /// arrives in the ``CaptureDecoder/provenanceHeaderName`` header rather than
    /// the body. `now` is the server-owned capture time. Never throws.
    public func handleIngestVideo(
        fileURL: URL, provenanceHeader: String?, now: Date
    ) async -> HandlerResult {
        let decoded: DecodedVideoCapture
        do {
            decoded = try CaptureDecoder.decodeVideoHeader(provenanceHeader, now: now)
        } catch let error as CaptureDecodeError {
            return HandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return HandlerResult(statusCode: 400, response: .error("Bad request."))
        }

        let collectionID = decoded.collectionID ?? defaultCollectionID()
        let input = DirectInputReader.remoteVideo(
            fileURL: fileURL, provenance: decoded.provenance, into: collectionID)
        return await ingest(
            input, into: collectionID,
            jobID: decoded.jobID, sourceID: decoded.sourceID,
            sourceURL: decoded.provenance.originalURL)
    }

    /// Run one input through the shared coordinator, fire `onCapture`, record the
    /// bulk ledger row (when tagged), and map the single outcome to a
    /// `HandlerResult` (image + video paths share this — DRY).
    private func ingest(
        _ input: IngestInput, into collectionID: UUID,
        jobID: UUID?, sourceID: String?, sourceURL: String?
    ) async -> HandlerResult {
        let outcomes = await coordinator.ingest([input])
        onCapture?(collectionID, outcomes)

        guard let outcome = outcomes.first else {
            // The coordinator returns one outcome per input; an empty result would
            // mean the single item was cancelled — surface it rather than lie.
            return HandlerResult(
                statusCode: 500, response: .error("Ingest produced no outcome."))
        }

        await recordJobItem(outcome, jobID: jobID, sourceID: sourceID, sourceURL: sourceURL)

        switch outcome {
        case .ingested(let asset, let deduplicated):
            // Stamp the owning job's current status so the extension halts the sweep
            // when the user paused/cancelled in the app (7A relay feedback). Nil (and
            // unencoded) for an untagged single-item capture.
            let jobStatus = await currentJobStatus(jobID: jobID)
            return HandlerResult(
                statusCode: 200,
                response: .ingested(
                    assetId: asset.id, deduplicated: deduplicated, jobStatus: jobStatus))
        case .failed(let error):
            return HandlerResult(
                statusCode: 422, response: .error(String(describing: error)))
        case .cancelled:
            // Batch-only placeholder; a single-item capture path never produces this.
            return HandlerResult(
                statusCode: 499, response: .error("cancelled"))
        }
    }

    /// The owning job's current status string for the relay feedback (7A), or nil
    /// for an untagged capture / when the ledger read fails (never blocks an ingest
    /// that already happened — a missed pause just takes effect on the next item).
    private func currentJobStatus(jobID: UUID?) async -> String? {
        guard let jobLedger, let jobID else { return nil }
        return try? await jobLedger.jobStatus(forJob: jobID).rawValue
    }

    /// Record one capture's outcome into the bulk ledger, when it is tagged with a
    /// `jobID` + `sourceID` and a ledger is wired (3A). Maps the ingest outcome to
    /// the 7A item taxonomy: a dedup → `.deduped`, a fresh ingest → `.ingested`, a
    /// server-side ingest failure → `.permanentFailed` (the bytes were already in
    /// hand, so this is a decode/persistence failure, not a transient fetch blip —
    /// those are classified and retried extension-side before the POST). Best-effort:
    /// a failed ledger write is swallowed so it can never fail an ingest that
    /// already happened (the item just stays re-downloadable on the next sweep).
    private func recordJobItem(
        _ outcome: IngestOutcome, jobID: UUID?, sourceID: String?, sourceURL: String?
    ) async {
        guard let jobLedger, let jobID, let sourceID else { return }
        let status: JobItemStatus
        let blobHash: String?
        switch outcome {
        case .ingested(let asset, let deduplicated):
            status = deduplicated ? .deduped : .ingested
            blobHash = asset.blobHash
        case .failed:
            status = .permanentFailed
            blobHash = nil
        case .cancelled:
            return
        }
        _ = try? await jobLedger.recordJobItem(
            jobID: jobID, sourceID: sourceID, sourceURL: sourceURL,
            status: status, blobHash: blobHash)
    }
}
