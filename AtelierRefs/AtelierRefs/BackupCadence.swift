//
//  BackupCadence.swift
//  AtelierRefs
//
//  008 · H5d — how often the off-device backup runs by itself, as a user
//  preference rather than a hidden behaviour.
//
//  This is the same shape as H3's daily-on-launch snapshot (`SnapshotManager`
//  :117), and deliberately so: check on launch whether the last good run is
//  older than a maximum age, and if it is, do one in the background. No timers,
//  no scheduler, no background activity while the app isn't running — a Mac app
//  that is open is the only time this app can copy anything, so "on launch, if
//  stale" is not a compromise, it is the whole available surface.
//
//  What it is NOT is silent. Off-device backup writes to a folder the user chose
//  — an external drive, a synced folder someone pays for by the gigabyte — and a
//  copy job starting on its own has to be something they can see and switch off
//  in the same place they set the folder up.
//

import Foundation

/// How often a backup runs without being asked.
///
/// Only three options, and the gap between them is wide on purpose. A cadence
/// picker with six values invites the user to tune a number that does not
/// matter; what matters is "automatically" versus "when I say so".
nonisolated enum BackupCadence: String, CaseIterable, Codable, Sendable {
    /// Never automatically — "Back Up Now" only.
    case manual
    /// At most once a day, checked at launch.
    case daily
    /// At most once a week, checked at launch.
    case weekly

    /// How stale the last good run may be before a launch takes another.
    ///
    /// `nil` for ``manual``, which is the *absence* of a cadence rather than a
    /// very long one — an important distinction, because the automatic path
    /// returns early on `nil` and therefore never resolves the bookmark, never
    /// touches the destination, and never appears in the status line.
    var maxAge: TimeInterval? {
        switch self {
        case .manual: return nil
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }

    /// The picker label.
    var label: String {
        switch self {
        case .manual: return "Manually"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// What the user gets if they never touch the picker.
    ///
    /// Daily, not manual. Choosing a backup folder is already the statement of
    /// intent — "keep a copy of my library here" — and making the copying itself
    /// a second, separate opt-in produces the single most common backup failure
    /// there is: one that was set up once, ran once, and has been months stale
    /// ever since without anyone noticing. The same reasoning made H3's daily
    /// snapshot on-by-default. A run with no folder chosen, or whose folder
    /// isn't reachable, does nothing at all, so the default costs nothing until
    /// the user has said where.
    static let `default` = BackupCadence.daily
}

/// Reads and writes the cadence preference, per library.
///
/// Namespaced `library.<id>.` per 016 §C item 3, the same discipline
/// `ClipboardWatcher` follows. The bookmark and the last-run summary are single
/// app-wide keys (F2/H5b) because there is one chosen folder; the cadence is a
/// statement about a *library*, and two libraries pointed at one folder must be
/// able to disagree about how often they copy themselves into it.
///
/// `@unchecked Sendable` for the same reason ``BackupSummaryStore`` is: the
/// defaults object is thread-safe and the stored property is immutable.
nonisolated struct BackupCadenceStore: @unchecked Sendable {
    static func key(libraryID: String) -> String {
        "library.\(libraryID).backupCadence"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored cadence, or ``BackupCadence/default`` when there is none.
    ///
    /// An unrecognised value also reads as the default — a preference written by
    /// a future build with a fourth case must degrade to a sane cadence, not to
    /// nothing at all. Falling back to `manual` there would silently stop the
    /// backups of anyone who ran a newer build once.
    func load(libraryID: String) -> BackupCadence {
        guard let raw = defaults.string(forKey: Self.key(libraryID: libraryID)),
              let cadence = BackupCadence(rawValue: raw)
        else { return .default }
        return cadence
    }

    func save(_ cadence: BackupCadence, libraryID: String) {
        defaults.set(cadence.rawValue, forKey: Self.key(libraryID: libraryID))
    }
}
