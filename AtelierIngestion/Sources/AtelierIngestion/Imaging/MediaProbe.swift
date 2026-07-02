// AtelierIngestion — cheap container sniffing for the image-vs-video fork.
//
// `CGImageSource` cannot open movie containers (an MP4 yields a non-nil source
// with a NIL type — verified), so the pipeline can't tell "video" from "corrupt
// image" by that path alone. This sniffs the leading bytes to answer two cheap
// questions before we reach for AVFoundation:
//   • looksLikeMovie — should we even try the (async, temp-file) video path?
//   • movieContainer — the canonical MIME + extension for the sniffed container.
//
// It reads only the ISO Base Media File Format (MP4/MOV/M4V…) box header, so it's
// a few bytes, never a decode. HEIC/HEIF/AVIF are ALSO `ftyp` boxes but are still
// images, so their brands are deliberately EXCLUDED — those decode fine on the
// image path and must not be mistaken for movies.

import Foundation

/// Byte-level container sniffing (still image vs. movie). A stateless namespace.
public enum MediaProbe {
    /// ISO BMFF `ftyp` major brands (+ common compatible brands) that denote a
    /// MOVIE container. Image `ftyp` brands (`heic`, `mif1`, `avif`, …) are
    /// intentionally absent — those are handled by the image path.
    private static let movieBrands: Set<String> = [
        "isom", "iso2", "iso4", "iso5", "iso6", "iso8",
        "mp41", "mp42", "mp4v", "avc1", "dash", "mmp4",
        "M4V ", "m4v ", "M4VH", "M4VP", "qt  ", "f4v ",
        "3gp4", "3gp5", "3g2a", "MSNV", "NDSC",
    ]

    /// Top-level QuickTime/ISO atoms that appear at the very start of some movies
    /// that lead with something other than `ftyp`.
    private static let movieAtoms: Set<String> = ["moov", "mdat", "free", "skip", "wide", "pnot"]

    /// Whether `data` looks like a movie container worth handing to AVFoundation.
    /// Cheap and conservative: a false negative just means we skip the video path
    /// (and report the original image error), never a wrong ingest.
    public static func looksLikeMovie(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let boxType = fourCC(data, at: 4)
        if boxType == "ftyp" {
            return movieBrands.contains(fourCC(data, at: 8))
        }
        return movieAtoms.contains(boxType)
    }

    /// The canonical MIME + filename extension for a sniffed movie container.
    /// Defaults to MP4 (the common case, incl. Twitter's progressive variants);
    /// a QuickTime brand maps to `.mov`.
    public static func movieContainer(_ data: Data) -> (mime: String, fileExtension: String) {
        if data.count >= 12, fourCC(data, at: 4) == "ftyp", fourCC(data, at: 8) == "qt  " {
            return ("video/quicktime", "mov")
        }
        return ("video/mp4", "mp4")
    }

    /// The four-character (FourCC) ASCII code at `offset`, non-ASCII bytes shown as
    /// "?". Callers only ever compare against ASCII brand constants.
    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard data.count >= offset + 4 else { return "" }
        let start = data.startIndex + offset
        return String(data[start..<start + 4].map {
            (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?"
        })
    }
}
