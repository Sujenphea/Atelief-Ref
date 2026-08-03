// AtelierExport — the static-site input model (014 · S3)
//
// The third consumer of this package's export layer. Unlike the moodboard and
// the contact sheet, the output is not a drawn surface: it is an `index.html` +
// an `assets/` folder that any browser renders with **no JavaScript and no
// network access**. So the model here is deliberately NOT `MoodboardElement` —
// there are no world coordinates to lay out, because CSS does its own stacking.
// What the renderer needs is what an `<img>` needs: a file name inside
// `assets/`, its pixel dimensions (so the browser reserves the right box before
// the bytes arrive), and the optional words around it.
//
// Naming is not decided here. The app hands over already-final file names from
// `AssetExport` — one sanitizer, one `<base>-<shorthash>.<ext>` shape, shared
// with drag-out and the 008 exporter — so this package never invents a second
// naming rule.

import Foundation

/// What one gallery cell shows.
///
/// A video is its own case rather than an image plus a flag: the export copies
/// **only the poster frame**, never the video file (014 · settled), and the
/// renderer marks it with a play glyph so the page is honest about being a
/// still. Making that a distinct case means a video can never be emitted as a
/// silent, un-badged image by forgetting to read a boolean.
public enum SiteMedia: Equatable, Sendable {
    /// A raster ref: `file` is a name inside `assets/`.
    case image(file: String, pixelWidth: Int?, pixelHeight: Int?)
    /// A video ref shown as its poster frame; `posterFile` is inside `assets/`.
    /// The video itself is never copied.
    case video(posterFile: String, pixelWidth: Int?, pixelHeight: Int?)
    /// A colour swatch — no file at all, drawn by CSS.
    case color(hex: String)

    /// The name this cell reads out of `assets/`, or `nil` for a colour swatch.
    /// The writer uses it to drop cells whose bytes never made it to disk.
    public var assetFilename: String? {
        switch self {
        case .image(let file, _, _): return file
        case .video(let file, _, _): return file
        case .color: return nil
        }
    }
}

/// One cell of the exported page.
public struct SiteItem: Equatable, Sendable {
    public var media: SiteMedia
    /// Title-ish words under the cell. Rendered only when the gallery includes
    /// captions; also supplies the `alt` text in that case.
    public var caption: String
    /// Where this ref came from. Rendered only when the gallery includes
    /// sources — provenance is an explicit choice, never a silent default
    /// either way (014 · provenance option).
    public var sourceURL: String?

    public init(media: SiteMedia, caption: String = "", sourceURL: String? = nil) {
        self.media = media
        self.caption = caption
        self.sourceURL = sourceURL
    }
}

/// A whole page's worth of refs plus the two presentation switches the export
/// popover owns.
public struct SiteGallery: Equatable, Sendable {
    /// Page `<title>` and heading — the collection's name.
    public var title: String
    public var items: [SiteItem]
    /// Requested masonry column count; clamped by ``SiteLayout``.
    public var columns: Int
    /// Draw the caption line under each cell.
    public var includeCaptions: Bool
    /// Draw the source link under each cell.
    public var includeSources: Bool

    public init(
        title: String,
        items: [SiteItem],
        columns: Int = 4,
        includeCaptions: Bool = true,
        includeSources: Bool = true
    ) {
        self.title = title
        self.items = items
        self.columns = columns
        self.includeCaptions = includeCaptions
        self.includeSources = includeSources
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// One file to place in `assets/`: where it is now, and what it is called there.
/// The name is `AssetExport`'s, already de-duplicated for the folder.
public struct SiteAsset: Equatable, Sendable {
    public var source: URL
    public var filename: String

    public init(source: URL, filename: String) {
        self.source = source
        self.filename = filename
    }
}
