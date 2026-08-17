# 417 — one control that sends

[416](416-the-inbox-is-what-the-phone-has-to-send.md) built the writer. This is the button,
and the argument is mostly about what it does NOT do.

## Earning the second thing in the toolbar

093 § 2 spent its whole argument on subtraction: the Mac sidebar's six things become one,
and since the phone has a single destination it has a single navigation control — the title.
Adding a second control has to clear that bar, so:

- **It appears only when the inbox has something in it.** An empty phone shows the grid and
  nothing else, which is the resting state 093 designed. A button permanently reading "0" is
  chrome apologising for itself.
- **It says the count.** "Send 3" answers the question a bare glyph raises, and a user who
  has just shared something into the app wants to watch the number go up.
- **It is on the root only.** A pushed subcollection is a place you are reading, not a place
  you send from — the same rule that already keeps the switcher off pushed screens.

The count re-reads on `scenePhase == .active`, because a share arrives while this app is in
the background — the extension is a different process — which is the same cadence the Mac's
drain runs on (407).

## Nothing is deleted, and that is the design

After an export the records stay exactly where they were. Deleting would mean trusting that
a share sheet the user might have cancelled, an AirDrop that might have failed, and an
import that might not have happened yet, all succeeded.

Keeping means the worst case is importing the same capture twice — which is precisely what
091 · D4 bought when it chose the archive manifest over shipping the inbox folder:
provenance crosses verbatim, so 18A blob-hash dedup collapses the second import instead of
forking a second asset. **The expensive property paid for in the format is what makes the
cheap behaviour here safe.** A UI test asserts it: send, dismiss, and the control still says
3.

## The system's share sheet, deliberately

092 · S6 says transport is whatever moves a folder — AirDrop, iCloud Drive, a cable — so the
app hands a folder URL to `UIActivityViewController` and stops. Building a picker for
"AirDrop or Files?" would be a worse copy of a thing every iOS user already has.

The archive is written into Caches under a sortable name (`Atelier 2026-08-17 2005`),
because it is a copy of bytes the inbox still holds and the system is welcome to reclaim it.
A fresh folder per run: writing into a previous export would leave last time's files beside
this time's manifest, and a manifest being wrong about its own contents is the one failure
the format cannot survive.

**Unverified, and stated rather than glossed:** a simulator has no AirDrop, so
folder-over-AirDrop could not be exercised here. "Save to Files" is offered and takes a
directory. If a real device turns out to dislike AirDropping a folder, the fallback is
`NSFileCoordinator`'s `.forUploading` coordination — it hands over a zip of the same folder
and is one call away, at the cost of an unzip step the Mac side would then need.

## Verification

Six UI tests now, all passing on iPhone 17 Pro / iOS 26.5 — the four from 414 plus:

| test | the claim |
|---|---|
| `testTheControlSaysHowManyCapturesAreWaiting` | it appears, and it says 3 |
| `testSendingPresentsAShareSheetAndKeepsTheCaptures` | tapping produces a share sheet, and the captures survive it |

`FixtureLibrary` now seeds the **inbox** as well as the library, through the real
`InboxWriter`. That is a second thing a fixture has to make, and the reason is 416's finding
restated: a capture on a phone never becomes a row, so a seeded library alone leaves the
export control correctly invisible and its behaviour undrivable.

`scripts/verify.sh fast` — all 9 stages.

## Files

    AtelierRefs/AtelierRefsMobile/             the controller: counts, writes off the main
      CaptureExport.swift                      actor, keeps the records
    AtelierRefs/AtelierRefsMobile/             the toolbar control, the share-sheet
      ExportControls.swift                     representable, the failure toast
    AtelierRefs/AtelierRefsMobile/             root-only toolbar item, activation refresh,
      ContentView.swift                        share sheet + failure overlay
    AtelierRefs/AtelierRefsMobile/             `libraryRoot` published for the inbox
      LibraryStore.swift
    AtelierRefs/AtelierRefsMobile/Debug/       seeds three pending captures
      FixtureLibrary.swift
    AtelierRefs/AtelierRefsMobileUITests/      2 tests
      ExportUITests.swift
    AtelierRefs/AtelierRefs.xcodeproj          the mobile target links AtelierArchive

## Migration notes

None — new surface only, and it is invisible until an inbox has something in it.

**What S6 still owes:** the Mac end. `ArchiveImportController` already imports a folder
(H7), so the remaining work is confirming a PHONE-written archive round-trips through it —
S6c — rather than any new import path.
