// AtelierCapture — what Safari's preprocessing script saw (092 · S4b, tier 2).
//
// **The split this file exists to keep.** `NSExtensionJavaScriptPreprocessingFile` runs a
// JavaScript file inside the shared page and hands its result to the share extension as a
// dictionary. That script is the only part of tier 2 that needs a DOM — so it does only
// DOM reading, returns a RAW snapshot of plain values, and decides nothing. Everything
// that can be got wrong — which meta wins, which images are worth keeping, what the media
// URL is, which platform this is — is decided here, in Swift, over plain values, and
// tested under `swift test` on macOS with no device, no Safari and no page.
//
// That is not a new idea; it is the browser extension's own split, applied to the phone.
// `extension/src/harvest.js` separates `harvestSignals()` (runs in the page, serialized,
// no imports, minimal and hand-checked) from `buildHarvest(raw)` (a pure module function,
// unit-tested with plain objects, no jsdom). ``RawPageSignals`` is that file's raw
// snapshot and ``PageHarvest/build(from:)`` is its `buildHarvest`, rule for rule.
//
// **What the phone's script does NOT gather, and why.** The browser extension rasterizes
// the first eligible `<video>`'s current frame to a data-URL, because a video tweet has no
// still on the server and the frame the user is looking at is the closest thing to the
// picture. The phone does not: a share-sheet preprocessing script runs on a user gesture
// with a share sheet already on screen, `canvas` is tainted for cross-origin video (so it
// fails on exactly the sites this is for), and a data-URL of a decoded frame is an image's
// worth of bytes crossing an XPC boundary — which is the memory rule 091 · D2 spends the
// whole extension avoiding. The poster is still harvested, so a video post yields its
// poster rather than nothing.

import Foundation

/// The raw snapshot the preprocessing script returns, before any classification.
///
/// Every field is optional or defaulted because it comes from JavaScript through a plist:
/// a page that has no `<meta>` at all is a page, not an error, and a script that changed
/// shape should degrade to "nothing found" rather than throw where nobody can see it.
public struct RawPageSignals: Codable, Equatable, Sendable {
    public struct Meta: Codable, Equatable, Sendable {
        public var key: String?
        public var content: String?

        public init(key: String? = nil, content: String? = nil) {
            self.key = key
            self.content = content
        }
    }

    public struct Image: Codable, Equatable, Sendable {
        public var src: String?
        public var width: Int?
        public var height: Int?
        public var alt: String?
        /// The index of the containing `<article>`, or -1. On a tweet status page the
        /// focal tweet is the first `<article>` and the replies follow, which is how the
        /// twitter extractor avoids borrowing a reply's image.
        public var articleIndex: Int?

        public init(
            src: String? = nil, width: Int? = nil, height: Int? = nil,
            alt: String? = nil, articleIndex: Int? = nil
        ) {
            self.src = src
            self.width = width
            self.height = height
            self.alt = alt
            self.articleIndex = articleIndex
        }
    }

    public struct Video: Codable, Equatable, Sendable {
        public var poster: String?
        public var src: String?
        public var width: Int?
        public var height: Int?
        public var articleIndex: Int?

        public init(
            poster: String? = nil, src: String? = nil, width: Int? = nil,
            height: Int? = nil, articleIndex: Int? = nil
        ) {
            self.poster = poster
            self.src = src
            self.width = width
            self.height = height
            self.articleIndex = articleIndex
        }
    }

    public var url: String?
    public var title: String?
    public var canonical: String?
    public var metas: [Meta]?
    public var images: [Image]?
    public var videos: [Video]?

    public init(
        url: String? = nil, title: String? = nil, canonical: String? = nil,
        metas: [Meta]? = nil, images: [Image]? = nil, videos: [Video]? = nil
    ) {
        self.url = url
        self.title = title
        self.canonical = canonical
        self.metas = metas
        self.images = images
        self.videos = videos
    }
}

/// A page's signals, classified — the shape the extractors read.
public struct PageHarvest: Equatable, Sendable {
    /// One piece of media the page rendered.
    public struct Media: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case image
            /// A `<video>`'s poster frame — the only still a video post offers.
            case videoPoster
            /// A real (non-blob, non-data) `<video>` source. Not ingestible here, but a
            /// strong "this is a video" signal, and kept for the same reason the browser
            /// extension keeps it.
            case videoSource
        }

        public var kind: Kind
        public var src: String
        public var width: Int
        public var height: Int
        public var alt: String?
        public var articleIndex: Int?

        public init(
            kind: Kind, src: String, width: Int = 0, height: Int = 0,
            alt: String? = nil, articleIndex: Int? = nil
        ) {
            self.kind = kind
            self.src = src
            self.width = width
            self.height = height
            self.alt = alt
            self.articleIndex = articleIndex
        }

        var area: Int { width * height }
    }

    /// The live URL — `location.href`, kept correct by an SPA's `pushState`.
    public var url: String?
    public var title: String?
    public var canonical: String?
    /// Meta content by `property`/`name`, FIRST occurrence winning.
    public var metas: [String: String]
    public var media: [Media]

    public init(
        url: String? = nil, title: String? = nil, canonical: String? = nil,
        metas: [String: String] = [:], media: [Media] = []
    ) {
        self.url = url
        self.title = title
        self.canonical = canonical
        self.metas = metas
        self.media = media
    }

    // MARK: - Classification

    /// Classify a raw snapshot — `buildHarvest` (`extension/src/harvest.js:110`), in Swift.
    ///
    /// Three rules, each mirroring that function:
    ///
    /// - **First meta wins.** A page that declares `og:title` twice means the first one;
    ///   later duplicates are how a template and its content disagree.
    /// - **A `data:` src is skipped.** It is an inlined image the page already holds, and
    ///   nothing downstream can fetch it — on the phone that matters more than in the
    ///   browser, because the fetch happens in a process with a memory ceiling.
    /// - **An empty title is no title**, matching `ShareCapture.normalizedTitle(_:)`
    ///   rather than inventing a second emptiness rule.
    public static func build(from raw: RawPageSignals) -> PageHarvest {
        var metas: [String: String] = [:]
        for meta in raw.metas ?? [] {
            guard let key = meta.key, !key.isEmpty,
                  let content = meta.content, !content.isEmpty,
                  metas[key] == nil
            else { continue }
            metas[key] = content
        }

        var media: [Media] = []
        for image in raw.images ?? [] {
            guard let src = usable(image.src) else { continue }
            media.append(Media(
                kind: .image, src: src, width: image.width ?? 0, height: image.height ?? 0,
                alt: image.alt, articleIndex: image.articleIndex))
        }
        for video in raw.videos ?? [] {
            if let poster = usable(video.poster) {
                media.append(Media(
                    kind: .videoPoster, src: poster, width: video.width ?? 0,
                    height: video.height ?? 0, articleIndex: video.articleIndex))
            }
            if let source = usable(video.src), !source.hasPrefix("blob:") {
                media.append(Media(
                    kind: .videoSource, src: source, width: video.width ?? 0,
                    height: video.height ?? 0, articleIndex: video.articleIndex))
            }
        }

        return PageHarvest(
            url: nonBlank(raw.url), title: nonBlank(raw.title),
            canonical: nonBlank(raw.canonical), metas: metas, media: media)
    }

    /// A src worth keeping: present, non-blank, and not an inlined `data:` URL.
    private static func usable(_ src: String?) -> String? {
        guard let src = nonBlank(src), !src.hasPrefix("data:") else { return nil }
        return src
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Decoding

    /// The key Safari puts its preprocessing result under in the shared item.
    ///
    /// Spelled here rather than taken from `NSExtensionJavaScriptPreprocessingResultsKey`
    /// so this package — which links no UIKit and builds on macOS — owns the whole
    /// contract, and so the extension has one place to look when a share arrives empty.
    public static let resultsKey = "NSExtensionJavaScriptPreprocessingResultsKey"

    /// Classify what Safari handed over, or nil when it is not a page snapshot.
    ///
    /// The dictionary crosses an XPC boundary as a property list, so it arrives as
    /// `[String: Any]` of plist primitives. Rather than hand-walking that (a cast per
    /// field, in a process with no tests), it is re-serialized to JSON and decoded — one
    /// conversion, and the typed shape above is then the only description of the wire.
    /// A dictionary that will not serialize is a script returning something this does not
    /// understand, which is exactly the case that should yield nil rather than a
    /// half-filled harvest.
    public static func harvest(fromResults results: Any?) -> PageHarvest? {
        guard let dictionary = results as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let raw = try? JSONDecoder().decode(RawPageSignals.self, from: data)
        else { return nil }
        let harvest = build(from: raw)
        // A snapshot with no URL is not a page. Safari always supplies one; a script that
        // failed early might not, and everything downstream keys off it.
        return harvest.url == nil ? nil : harvest
    }
}
