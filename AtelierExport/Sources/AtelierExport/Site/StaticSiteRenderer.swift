// AtelierExport — the static-site template (014 · S3)
//
// Renders a ``SiteGallery`` to a complete `index.html`. The output is a PURE
// function of its input — no clock, no locale, no dictionary iteration order —
// so it is pinned by golden files in `StaticSiteRendererTests`: change the
// template and the tests say so, loudly.
//
// Self-contained means exactly what it says. The page has:
//   • no <script> of any kind,
//   • no external stylesheet, font, or image — every URL it emits is a relative
//     path into the sibling `assets/` folder,
// so it renders identically on a laptop with the Wi-Fi off, from a `file://`
// URL, out of an email attachment, or on any static host. The play glyph on a
// video poster is inline SVG for the same reason.
//
// Rejected (014): a single-file page with data-URI images. Base64 inflates the
// bytes by a third and produces multi-hundred-megabyte HTML that most editors
// and mail clients refuse to open.

import Foundation

/// The `index.html` writer. Stateless; all members `static`.
public enum StaticSiteRenderer {

    /// The complete document for `gallery`.
    ///
    /// Layout is flexbox columns filled round-robin (``SiteLayout``), each cell
    /// sized by its image's intrinsic `width`/`height` attributes — so the
    /// browser reserves the right box before a byte is decoded (no reflow) and
    /// the page reflows properly at any window size instead of being frozen at
    /// whatever width the exporting Mac happened to have.
    public static func indexHTML(_ gallery: SiteGallery) -> String {
        let groups = SiteLayout.columnGroups(
            itemCount: gallery.items.count, columns: gallery.columns)
        var out = ""
        out += "<!DOCTYPE html>\n"
        out += "<html lang=\"en\">\n"
        out += "<head>\n"
        out += "<meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        out += "<title>\(escape(gallery.title))</title>\n"
        out += "<style>\n\(stylesheet)</style>\n"
        out += "</head>\n"
        out += "<body>\n"
        out += header(gallery)
        out += grid(gallery, groups: groups)
        out += footer(gallery)
        out += "</body>\n"
        out += "</html>\n"
        return out
    }

    // MARK: - Sections

    private static func header(_ gallery: SiteGallery) -> String {
        var out = "<header>\n"
        out += "<h1>\(escape(gallery.title))</h1>\n"
        out += "<p class=\"count\">\(refCount(gallery.items.count))</p>\n"
        out += "</header>\n"
        return out
    }

    private static func grid(_ gallery: SiteGallery, groups: [[Int]]) -> String {
        guard !groups.isEmpty else {
            // An empty gallery never reaches disk — the export action is disabled
            // with nothing to export (014) — but the template still has to say
            // something rather than emit a bare, confusing shell.
            return "<main class=\"grid empty\">\n<p>No refs.</p>\n</main>\n"
        }
        var out = "<main class=\"grid\">\n"
        for group in groups {
            out += "<div class=\"col\">\n"
            for index in group {
                out += figure(gallery.items[index], gallery: gallery)
            }
            out += "</div>\n"
        }
        out += "</main>\n"
        return out
    }

    private static func footer(_ gallery: SiteGallery) -> String {
        var out = "<footer>\n"
        out += "<p>Exported from Atelier — this page and its images are self-contained.</p>\n"
        if gallery.items.contains(where: { if case .video = $0.media { return true }; return false }) {
            // Say it in the page, not just in the export dialog: someone who
            // receives the folder should not have to guess why a video is a still.
            out += "<p>Video refs are shown as poster frames; the video files are "
                + "not included.</p>\n"
        }
        out += "</footer>\n"
        return out
    }

    // MARK: - One cell

    private static func figure(_ item: SiteItem, gallery: SiteGallery) -> String {
        var out = "<figure>\n"
        out += media(item, gallery: gallery)
        out += caption(item, gallery: gallery)
        out += "</figure>\n"
        return out
    }

    private static func media(_ item: SiteItem, gallery: SiteGallery) -> String {
        switch item.media {
        case .image(let file, let width, let height):
            return "<div class=\"frame\">\(img(file: file, width: width, height: height, item: item, gallery: gallery))</div>\n"
        case .video(let file, let width, let height):
            var out = "<div class=\"frame\">"
            out += img(file: file, width: width, height: height, item: item, gallery: gallery)
            out += playGlyph
            out += "</div>\n"
            return out
        case .color(let hex):
            // A colour ref costs no file at all: CSS paints it. The hex is
            // validated by the app's mapping before it gets here.
            return "<div class=\"frame\"><div class=\"swatch\" style=\"background:\(escape(hex))\"></div></div>\n"
        }
    }

    private static func img(
        file: String, width: Int?, height: Int?, item: SiteItem, gallery: SiteGallery
    ) -> String {
        var out = "<img src=\"\(assetHref(file))\" alt=\"\(escape(altText(item, gallery: gallery)))\""
        if let width, let height, width > 0, height > 0 {
            out += " width=\"\(width)\" height=\"\(height)\""
        }
        out += " loading=\"lazy\">"
        return out
    }

    /// `alt` follows the caption switch rather than always using the title.
    /// Turning captions off is how a user strips those words from what they
    /// hand over; leaking them back through `alt` would quietly undo the choice.
    private static func altText(_ item: SiteItem, gallery: SiteGallery) -> String {
        gallery.includeCaptions && !item.caption.isEmpty ? item.caption : "Reference"
    }

    private static func caption(_ item: SiteItem, gallery: SiteGallery) -> String {
        let title = gallery.includeCaptions ? item.caption : ""
        let source = gallery.includeSources ? item.sourceURL : nil
        guard !title.isEmpty || source != nil else { return "" }

        var out = "<figcaption>\n"
        if !title.isEmpty {
            out += "<span class=\"title\">\(escape(title))</span>\n"
        }
        if let source {
            out += "<a class=\"src\" href=\"\(escape(source))\">\(escape(sourceLabel(source)))</a>\n"
        }
        out += "</figcaption>\n"
        return out
    }

    /// The words a source link shows: its host, else the raw string. A full URL
    /// as link text wraps into an unreadable ribbon under a narrow column, and
    /// the host is the part that answers "where is this from".
    static func sourceLabel(_ raw: String) -> String {
        if let host = URL(string: raw)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return raw
    }

    private static func refCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "ref" : "refs")"
    }

    // MARK: - Escaping

    /// HTML-escape text for both element content and double-quoted attributes.
    static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// `assets/<name>` as a URL-safe, HTML-safe attribute value.
    ///
    /// `AssetExport`'s sanitizer already removes `/`, `\` and `:`, but it
    /// deliberately preserves unicode and emoji — and says nothing about `?`,
    /// `#` or `%`, all of which change what a browser asks for. Percent-encode
    /// first (URL grammar), then HTML-escape (attribute grammar); doing it in
    /// that order is what keeps a file called `a&b #2.png` reachable.
    static func assetHref(_ filename: String) -> String {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? filename
        return escape("assets/" + encoded)
    }

    // MARK: - Assets of the template itself

    /// Inline SVG, not an icon font or an image file: a video poster has to be
    /// marked as a still even when the folder is opened from a thumb drive.
    private static let playGlyph = """
        <svg class="play" viewBox="0 0 44 44" aria-hidden="true">\
        <circle cx="22" cy="22" r="20" fill="rgba(0,0,0,0.45)" \
        stroke="rgba(255,255,255,0.92)" stroke-width="1.5"></circle>\
        <path d="M18 14 31 22 18 30 Z" fill="#fff"></path></svg>
        """

    private static let stylesheet = """
        :root {
          color-scheme: light dark;
          --bg: #ffffff; --ink: #141414; --muted: #6b6b6b; --line: #e8e8e8;
        }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #131313; --ink: #f0f0f0; --muted: #9b9b9b; --line: #262626; }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; background: var(--bg); color: var(--ink);
          font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                Helvetica, Arial, sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        header { padding: 40px 28px 20px; }
        h1 { margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.015em; }
        .count { margin: 6px 0 0; color: var(--muted); }
        .grid { display: flex; align-items: flex-start; gap: 14px; padding: 0 28px 40px; }
        .col { display: flex; flex-direction: column; gap: 14px; flex: 1 1 0; min-width: 0; }
        .grid.empty { color: var(--muted); }
        figure { margin: 0; }
        .frame {
          position: relative; overflow: hidden; border-radius: 5px;
          background: var(--line);
        }
        .frame img { display: block; width: 100%; height: auto; }
        .swatch { width: 100%; aspect-ratio: 1 / 1; }
        .play {
          position: absolute; left: 50%; top: 50%; width: 44px; height: 44px;
          margin: -22px 0 0 -22px; pointer-events: none;
        }
        figcaption { margin-top: 7px; color: var(--muted); overflow-wrap: anywhere; }
        figcaption .title { display: block; color: var(--ink); }
        figcaption .src { display: block; color: var(--muted); text-decoration: none; }
        figcaption .src:hover { text-decoration: underline; }
        footer { padding: 0 28px 40px; color: var(--muted); font-size: 11px; }
        footer p { margin: 0 0 4px; }
        /* Narrow viewports: the columns are baked into the markup, so stack them
           rather than squeezing four tracks into a phone. */
        @media (max-width: 700px) {
          .grid { display: block; padding: 0 16px 32px; }
          .col + .col { margin-top: 14px; }
          header { padding: 28px 16px 16px; }
          footer { padding: 0 16px 32px; }
        }

        """
}
