// AtelierIngestion — download a DIRECT image URL (backlog B1)
//
// The one deliberate exception to "the app never downloads" (007 §scope): when a
// drag/paste hands us a BARE image URL and no bytes (a Pinterest drag delivering
// only `https://i.pinimg.com/…​.jpg`), this fetches those bytes so the same local
// pipeline can ingest them. Scoped strictly to DIRECT image URLs — a *page* URL
// that needs HTML scraping is NOT handled here (it fails cleanly as `.notAnImage`
// and stays with link-resolution / the Chrome extension, #6).
//
// Design for testability:
//   • The `URLSession` is INJECTED, so a test drives the whole thing through a
//     `URLProtocol` stub and never touches the real network (mirrors the package's
//     DI style — the pipeline takes its store/services, this takes its session).
//   • "Is it an image?" is answered by SNIFFING the downloaded bytes through the
//     SAME `ImageMetadata.extract` the pipeline uses (ImageIO container detection),
//     not by trusting a `Content-Type` header — a server can mislabel, and the
//     pipeline will re-derive the type from bytes anyway. The header is captured
//     only for the diagnostic on `.notAnImage`.

import Foundation

import AtelierCore

/// A typed failure downloading a remote image (backlog B1). `Equatable` so tests
/// assert on the exact case; ordered from "can't even request" to "got bytes but
/// they aren't an image".
public enum RemoteImageFetchError: Error, Equatable {
    /// The URL isn't an `http`/`https` URL — nothing to download.
    case invalidURL
    /// The request never completed (transport / connectivity failure).
    case requestFailed
    /// The server answered with a non-2xx status. `code` is that status.
    case httpStatus(Int)
    /// The response body exceeded the fetcher's byte cap. `bytes` is what arrived.
    case tooLarge(bytes: Int)
    /// The bytes downloaded fine but aren't a still image we can ingest — e.g. an
    /// HTML page (a link that needs scraping, out of scope) or a video. `mime` is
    /// the response's declared `Content-Type`, for diagnostics.
    case notAnImage(mime: String?)
}

/// Downloads a DIRECT image URL to bytes-plus-type, validating the response is
/// actually a still image and enforcing a size cap (backlog B1). Injectable — the
/// `URLSession` is supplied so tests run entirely off a `URLProtocol` stub.
public struct RemoteImageFetcher: Sendable {

    /// A successfully downloaded, validated image: its bytes plus the type
    /// resolved by SNIFFING those bytes (not the server's header).
    public struct RemoteImage: Sendable, Equatable {
        /// The downloaded image bytes.
        public let data: Data
        /// The byte-derived canonical MIME type (e.g. `image/jpeg`).
        public let mimeType: String
        /// The byte-derived canonical filename extension (e.g. `jpeg`), no dot.
        public let fileExtension: String
    }

    /// The default body cap: 32 MB — generous for a reference image, small enough
    /// that a mis-pointed URL can't exhaust memory.
    public static let defaultMaxByteCount = 32 * 1024 * 1024

    private let session: URLSession
    private let maxByteCount: Int

    public init(session: URLSession = .shared, maxByteCount: Int = RemoteImageFetcher.defaultMaxByteCount) {
        self.session = session
        self.maxByteCount = maxByteCount
    }

    /// Download `url` and validate it is a still image, or throw a
    /// ``RemoteImageFetchError``. Off-actor: this `struct` method is non-isolated,
    /// so its `await`s (the network I/O and the ImageIO sniff) run on the
    /// cooperative pool even when called from a `@MainActor` context.
    public func fetch(_ url: URL) async throws -> RemoteImage {
        guard DirectInputReader.isWebURL(url) else {
            throw RemoteImageFetchError.invalidURL
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            throw RemoteImageFetchError.requestFailed
        }

        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                throw RemoteImageFetchError.httpStatus(http.statusCode)
            }
            // Reject early when the server advertises an over-cap length.
            if let raw = http.value(forHTTPHeaderField: "Content-Length"),
               let length = Int(raw), length > maxByteCount {
                throw RemoteImageFetchError.tooLarge(bytes: length)
            }
        }

        // Stream into a buffer and abort as soon as the cap is exceeded — never
        // land a giant body in RAM first (G8).
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxByteCount {
                    throw RemoteImageFetchError.tooLarge(bytes: data.count)
                }
            }
        } catch let error as RemoteImageFetchError {
            throw error
        } catch {
            throw RemoteImageFetchError.requestFailed
        }

        // Authoritative "is it an image?" — sniff the bytes via ImageIO (the same
        // extractor the pipeline uses), never the server's Content-Type. A page /
        // video / anything non-image fails here and is NOT scraped (out of scope).
        let metadata: ImageMetadata
        do {
            metadata = try ImageMetadata.extract(from: data)
        } catch {
            throw RemoteImageFetchError.notAnImage(mime: response.mimeType)
        }
        guard metadata.kind == .image else {
            throw RemoteImageFetchError.notAnImage(mime: metadata.mimeType)
        }

        return RemoteImage(
            data: data, mimeType: metadata.mimeType, fileExtension: metadata.fileExtension)
    }

    /// Download `url` and turn it into a ready-to-ingest ``IngestInput`` with
    /// `.web` provenance — the image URL itself is the source's `originalURL`.
    ///
    /// Reuses ``DirectInputReader/browserImageInput(imageData:pageURL:into:at:)``:
    /// a downloaded bare image URL and a dragged browser image are the same
    /// provenance shape (a `.web` source whose `originalURL` is where the bytes
    /// came from), so this stays a thin wrapper rather than inventing a new one.
    public func ingestInput(
        for url: URL, into collectionID: UUID, at: Date
    ) async throws -> IngestInput {
        let image = try await fetch(url)
        return DirectInputReader.browserImageInput(
            imageData: image.data, pageURL: url, into: collectionID, at: at)
    }
}
