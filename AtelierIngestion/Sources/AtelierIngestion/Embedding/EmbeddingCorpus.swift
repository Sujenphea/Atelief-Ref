// AtelierIngestion — semantic embedding corpus + content hash (047 · 3a · 2A/4A)
//
// The ONE definition of "what text represents an asset" for semantic search, so
// the backfill (which embeds assets) and any future re-embed path agree exactly.
// 2A: title + user name + note + OCR, in a FIXED order (most-salient first), so a
// long OCR blob is what gets truncated, not the user's own words. 4A: a stable
// content hash of that exact text is the staleness signal — the backfill re-embeds
// when it changes (rename / late OCR), since `asset` carries no `updated_at`.

import AtelierCore
import CryptoKit
import Foundation

/// Builds the embedding corpus and its content hash for an asset (047 · 3a).
public enum EmbeddingCorpus {
    /// Cap on the corpus length. Bounds embedding cost and keeps the salient
    /// leading fields (title/name/note) from being crowded out by a long OCR tail
    /// — they're concatenated first, so truncation trims OCR.
    public static let maxLength = 1000

    /// The corpus text (2A) — title, name, note, OCR in that fixed order, each
    /// trimmed, blank fields dropped, joined by newlines, truncated to
    /// ``maxLength``. Empty string when the asset has no human text at all.
    public static func text(title: String?, name: String?, note: String?, ocr: String?) -> String {
        let parts = [title, name, note, ocr]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return String(parts.joined(separator: "\n").prefix(maxLength))
    }

    /// The corpus text for a backfill candidate.
    public static func text(_ candidate: EmbeddingCandidate) -> String {
        text(title: candidate.title, name: candidate.name,
             note: candidate.note, ocr: candidate.ocrText)
    }

    /// A stable content hash (SHA-256 hex) of the corpus text. Deterministic
    /// across runs / processes, so it can be compared to a stored hash to detect
    /// text drift without a timestamp.
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
