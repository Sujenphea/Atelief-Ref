//
//  LibraryStatsCopyTests.swift
//  AtelierRefsTests
//
//  016 · A — the words, checked. Same reason `BackupStatusTests` exists: a
//  sentence that states a NUMBER is a claim, and a claim that only a human
//  reading the pane can falsify is a claim nobody falsifies. What matters here
//  is that the figure in the sentence is the figure the measurement produced —
//  particularly the shared-blob case, where "delete this to free 240 MB" and
//  "delete these three items to free 240 MB" are different promises.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@Suite("LibraryStatsCopy (016 A)")
struct LibraryStatsCopyTests {

    private func item(
        bytes: Int64, name: String? = nil, assets: Int = 1,
        kind: AssetKind = .image, platform: Platform = .web
    ) -> LargestItem {
        LargestItem(
            usage: BlobUsage(
                blobHash: "aa11", mimeType: "image/png", kind: kind, platform: platform,
                displayName: name,
                assetIDs: (0 ..< assets).map { _ in UUID() }),
            byteSize: bytes)
    }

    // MARK: - Sizes

    @Test("zero bytes reads as zero, not as blank")
    func zeroSize() {
        #expect(!LibraryStatsCopy.size(0).isEmpty)
    }

    @Test("the storage explainer names the regenerable figure")
    func explainerNamesRegenerable() {
        let usage = LibraryStorageUsage(
            databaseBytes: 1_000, blobBytes: 8_000,
            thumbnailBytes: 2_000, cacheBytes: 500)

        let text = LibraryStatsCopy.storageExplainer(usage)

        #expect(text.contains(LibraryStatsCopy.size(2_500)))
        #expect(text.contains("regenerable"))
    }

    @Test("every tier has a label, and no two share one")
    func tierLabelsAreDistinct() {
        let labels = LibraryStorageTier.allCases.map(LibraryStatsCopy.tier)
        #expect(Set(labels).count == LibraryStorageTier.allCases.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test("every kind and platform has a non-empty label")
    func categoryLabelsExist() {
        #expect(AssetKind.allCases.allSatisfy { !LibraryStatsCopy.kind($0).isEmpty })
        #expect(Platform.allCases.allSatisfy { !LibraryStatsCopy.platform($0).isEmpty })
    }

    // MARK: - Counts

    @Test("the item phrase is singular for one and plural otherwise")
    func itemPluralisation() {
        #expect(LibraryStatsCopy.items(0) == "0 items")
        #expect(LibraryStatsCopy.items(1) == "1 item")
        #expect(LibraryStatsCopy.items(2) == "2 items")
    }

    // MARK: - Largest items

    @Test("a row's title prefers the name, then falls back to the kind")
    func titleFallsBack() {
        #expect(LibraryStatsCopy.title(for: item(bytes: 1, name: "Poster")) == "Poster")
        #expect(LibraryStatsCopy.title(for: item(bytes: 1, name: nil)) == "Images")
        #expect(LibraryStatsCopy.title(for: item(bytes: 1, name: "")) == "Images")
    }

    @Test("a shared file says so; an unshared one doesn't clutter the row")
    func subtitleMentionsSharingOnlyWhenShared() {
        let shared = LibraryStatsCopy.subtitle(for: item(bytes: 2_048, assets: 3))
        let alone = LibraryStatsCopy.subtitle(for: item(bytes: 2_048, assets: 1))

        #expect(shared.contains("shared by 3 items"))
        #expect(!alone.contains("shared"))
        #expect(alone.contains(LibraryStatsCopy.size(2_048)))
    }

    @Test("the delete confirmation states the bytes freed")
    func deleteConfirmationStatesBytes() {
        let text = LibraryStatsCopy.deleteConfirmation(for: item(bytes: 5_000_000))
        #expect(text.contains(LibraryStatsCopy.size(5_000_000)))
        #expect(text.contains("undo"))
    }

    @Test("deleting a shared file warns that every sharing item goes")
    func deleteConfirmationWarnsAboutSharing() {
        let text = LibraryStatsCopy.deleteConfirmation(for: item(bytes: 100, assets: 4))
        #expect(text.contains("4 items share this file"))
        #expect(text.contains("All of them"))
    }

    // MARK: - Staleness

    @Test("a fresh measurement reads as just now")
    func measuredJustNow() {
        let now = Date()
        #expect(LibraryStatsCopy.measured(at: now, now: now) == "Measured just now.")
    }

    @Test("a clock jump can't produce a measurement taken in the future")
    func futureTimestampIsClamped() {
        let now = Date()
        let ahead = now.addingTimeInterval(3 * 3_600)

        let text = LibraryStatsCopy.measured(at: ahead, now: now)

        #expect(text == "Measured just now.")
        #expect(!text.contains("in "))
    }

    @Test("a stale measurement says so and points at the remedy")
    func staleMeasurementSaysSo() {
        let now = Date()
        let text = LibraryStatsCopy.measured(at: now, isStale: true, now: now)

        #expect(text.contains("changed since"))
        #expect(text.contains("Measure again"))
    }

    @Test("an old measurement is dated rather than claimed to be current")
    func oldMeasurementIsDated() {
        let now = Date()
        let text = LibraryStatsCopy.measured(at: now.addingTimeInterval(-7_200), now: now)

        #expect(text.hasPrefix("Measured "))
        #expect(text != "Measured just now.")
    }
}

@Suite("LibraryStatsController job copy (016 A)")
struct LibraryStatsJobCopyTests {

    @Test("every job has a title, a confirmation, and a verb")
    func everyJobIsSpeakable() {
        for job in LibraryStatsController.Job.allCases {
            #expect(!job.title.isEmpty)
            #expect(!job.runningTitle.isEmpty)
            #expect(!job.confirmTitle.isEmpty)
            #expect(!job.confirmVerb.isEmpty)
            #expect(!job.confirmMessage.isEmpty)
        }
    }

    @Test("only the sweep — the one job that moves files to the Trash — reads as destructive")
    func onlyTheSweepIsDestructive() {
        let destructive = LibraryStatsController.Job.allCases.filter(\.isDestructive)
        #expect(destructive == [.orphanSweep])
    }

    @Test("only the jobs that can count their work claim a progress bar")
    func progressIsClaimedHonestly() {
        #expect(LibraryStatsController.Job.scan.reportsProgress)
        #expect(LibraryStatsController.Job.thumbnails.reportsProgress)
        #expect(!LibraryStatsController.Job.integrity.reportsProgress)
        #expect(!LibraryStatsController.Job.reconcile.reportsProgress)
        #expect(!LibraryStatsController.Job.orphanSweep.reportsProgress)
    }

    @Test("a cancelled report reads as stopped, never as failed")
    func cancelledReportWording() {
        for job in LibraryStatsController.Job.allCases {
            let report = LibraryStatsController.Report(job: job, outcome: .cancelled, seq: 1)
            #expect(!report.isFailure)
            #expect(report.message.contains("stopped"))
            #expect(!report.message.lowercased().contains("fail"))
        }
    }

    @Test("a failure report carries its message through and is flagged as one")
    func failureReportWording() {
        let report = LibraryStatsController.Report(
            job: .scan, outcome: .failed("Couldn't measure the library: disk gone"), seq: 2)

        #expect(report.isFailure)
        #expect(report.message == "Couldn't measure the library: disk gone")
    }
}
