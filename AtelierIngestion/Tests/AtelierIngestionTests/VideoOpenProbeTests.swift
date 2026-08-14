// AtelierIngestion — video-open cost probe (a MEASUREMENT, not an assertion)
//
// The instrument for "opening a video is a bit laggy". It exists to answer one
// question before anything is changed: of the costs on the video-open path, which
// one is the wait a person actually sees?
//
// Opt-in, because it is a stopwatch and its numbers are the point:
//
//     ATELIER_VIDEO_PROBE=1 swift test --filter VideoOpenProbe
//
// It times, on the MAIN ACTOR — which is where `ItemDetailView.loadMedia` does all
// of this:
//
//   1. the AVKit framework load: the first `AVPlayerView` in the process, which is
//      what `linkAVKit()` forces and what `VideoPlayer` builds anyway. Once per
//      process, and only ever paid by the FIRST video opened.
//   2. `AVPlayer(url:)` — the construction `loadMedia` performs synchronously,
//      with no off-main hop, three lines above an image arm that takes one.
//   3. the wait from there until a frame could be shown (`.readyToPlay`) — the
//      black window after construction returns.
//   4. decoding a poster JPEG — what drawing the placeholder instead would cost.
//
// (4) against (2)+(3) is the whole decision. If the poster is an order of
// magnitude cheaper, then drawing it is the fix, and making the construction async
// is a separate and smaller question.
//
// **It lives in this package, not the app target, for a reason worth writing
// down.** The app's test host is the sandboxed app: it cannot write a report
// anywhere a reader outside the container will find it, and xcodebuild does not
// forward the host's stdout, so a probe there passes while producing nothing. What
// is measured here is AVFoundation and AVKit, neither of which is app-specific.
//
// ATELIER_VIDEO_PROBE_PATH=/path/to/real.mp4 measures a REAL file instead of the
// synthetic clip. Worth doing before trusting the absolute numbers: a small
// synthetic H.264 fixture understates what a 1080p file costs to open. The fixture
// is here so the probe runs at all, not because it is typical.

import AVFoundation
import AVKit
import AppKit
import Foundation
import Testing
@testable import AtelierIngestion

@MainActor
@Suite("VideoOpenProbe (measurement)",
       .enabled(if: ProcessInfo.processInfo.environment["ATELIER_VIDEO_PROBE"] == "1"))
struct VideoOpenProbeTests {

    private func ms(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// The clip to measure: `ATELIER_VIDEO_PROBE_PATH`, else a written fixture.
    private func probeVideoURL() async throws -> (url: URL, isReal: Bool) {
        if let path = ProcessInfo.processInfo.environment["ATELIER_VIDEO_PROBE_PATH"] {
            return (URL(fileURLWithPath: path), true)
        }
        let data = try await FixtureVideos.solidVideo(width: 640, height: 480, frames: 30, fps: 30)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierVideoProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("probe-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return (url, false)
    }

    /// A JPEG at the app's `.large` poster tier, to time the placeholder decode
    /// against the player path. Generated from the clip's own poster frame, so it
    /// is the same picture the placeholder would actually draw.
    private func posterJPEG(for video: URL) async throws -> URL {
        let jpeg = try await ThumbnailGenerator.makeVideoPoster(
            from: try Data(contentsOf: video),
            maxPixelSize: ThumbnailTier.large.rawValue)
        let url = video.deletingPathExtension().appendingPathExtension("poster.jpg")
        try jpeg.write(to: url)
        return url
    }

    @Test("time the four costs on the video-open path")
    func measure() async throws {
        let (videoURL, isReal) = try await probeVideoURL()
        let posterURL = try await posterJPEG(for: videoURL)
        let bytes = (try? FileManager.default
            .attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0

        // 1 — AVKit framework load. The first AVPlayerView in the process.
        let avkitMS = ms { _ = AVPlayerView() }

        // 2 — the synchronous construction `loadMedia` does on the main actor.
        var player: AVPlayer?
        let constructMS = ms { player = AVPlayer(url: videoURL) }
        let item = try #require(player?.currentItem)

        // 3 — from there until a frame could be shown. Polled rather than KVO'd:
        // this is a stopwatch, and polling keeps the harness readable.
        let readyStart = DispatchTime.now().uptimeNanoseconds
        var readyMS = -1.0
        for _ in 0 ..< 1_000 {
            if item.status == .readyToPlay {
                readyMS = Double(DispatchTime.now().uptimeNanoseconds - readyStart) / 1_000_000
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        // 4 — what the placeholder would cost instead.
        var poster: NSImage?
        let posterMS = ms { poster = NSImage(contentsOf: posterURL) }

        let blank = readyMS < 0 ? "n/a (timed out)" : String(format: "%.1f ms", constructMS + readyMS)
        print("""

        ── video-open probe ────────────────────────────────────────────
          clip            : \(bytes / 1024) KB \(isReal ? "[real file]" : "[synthetic fixture]")
          1 AVKit load    : \(String(format: "%7.1f", avkitMS)) ms   first video of the session only
          2 AVPlayer(url:): \(String(format: "%7.1f", constructMS)) ms   main actor, blocking
          3 → readyToPlay : \(readyMS < 0 ? "  timed out" : String(format: "%7.1f", readyMS) + " ms")   black screen after 2
          4 poster decode : \(String(format: "%7.1f", posterMS)) ms   \(poster == nil ? "DECODE FAILED" : "the placeholder")
          ──────────────────────────────────────────────────────────────
          user waits      : \(blank)      (2 + 3, plus 1 on the first video)
          could see       : \(String(format: "%.1f", posterMS)) ms      (4, already decoded in DetailSession)
        ────────────────────────────────────────────────────────────────

        """)

        player?.pause()
        #expect(poster != nil)
    }
}
