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
    /// Manual: copying a whole library somewhere is the user's call to make, and
    /// an install that already has a folder chosen must not quietly start doing
    /// it because it was updated. The picker sits beside the folder row, so the
    /// choice is offered exactly where the intent is formed.
    ///
    /// Distinct from ``unrecognised`` on purpose — see there.
    static let `default` = BackupCadence.manual

    /// What an *unreadable* stored cadence degrades to.
    ///
    /// Deliberately not ``default``. "No preference recorded" and "a preference
    /// recorded by a build that knew a case this one doesn't" are opposite
    /// facts: the first user never asked for automatic backups, the second
    /// demonstrably did. Degrading a future build's choice to `manual` would
    /// silently stop the backups of anyone who ran a newer build once, so an
    /// unrecognised value keeps backing up on the shortest sane cadence.
    static let unrecognised = BackupCadence.daily
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
    /// A value that is present but unreadable takes ``BackupCadence/unrecognised``
    /// instead: a preference written by a future build with a fourth case is
    /// evidence the user chose automatic, and must not degrade to `manual`.
    func load(libraryID: String) -> BackupCadence {
        guard let raw = defaults.string(forKey: Self.key(libraryID: libraryID))
        else { return .default }
        return BackupCadence(rawValue: raw) ?? .unrecognised
    }

    func save(_ cadence: BackupCadence, libraryID: String) {
        defaults.set(cadence.rawValue, forKey: Self.key(libraryID: libraryID))
    }
}
