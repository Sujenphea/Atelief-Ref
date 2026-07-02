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

    public init(
        coordinator: IngestCoordinator,
        defaultCollectionID: @escaping @Sendable () -> UUID,
        onCapture: (@Sendable (UUID, [IngestOutcome]) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.defaultCollectionID = defaultCollectionID
        self.onCapture = onCapture
    }

    /// Ingest one captured image from a raw JSON body. `now` is the server-owned
    /// capture time. Never throws — every failure becomes a `HandlerResult`.
    public func handleIngest(body: Data, now: Date) async -> HandlerResult {
        let decoded: DecodedCapture
        do {
            decoded = try CaptureDecoder.decode(body: body, now: now)
        } catch let error as CaptureDecodeError {
            return HandlerResult(statusCode: 400, response: .error(error.message))
        } catch {
            return HandlerResult(statusCode: 400, response: .error("Bad request."))
        }

        let collectionID = decoded.collectionID ?? defaultCollectionID()
        let input = DirectInputReader.remoteInput(
            imageData: decoded.imageData,
            provenance: decoded.provenance,
            into: collectionID)

        let outcomes = await coordinator.ingest([input])
        onCapture?(collectionID, outcomes)

        guard let outcome = outcomes.first else {
            // The coordinator returns one outcome per input; an empty result would
            // mean the single item was cancelled — surface it rather than lie.
            return HandlerResult(
                statusCode: 500, response: .error("Ingest produced no outcome."))
        }

        switch outcome {
        case .ingested(let asset, let deduplicated):
            return HandlerResult(
                statusCode: 200,
                response: .ingested(assetId: asset.id, deduplicated: deduplicated))
        case .failed(let error):
            return HandlerResult(
                statusCode: 422, response: .error(String(describing: error)))
        }
    }
}
