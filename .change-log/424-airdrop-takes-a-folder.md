# 424 — AirDrop takes a folder

S6's transport is proven. A phone export was AirDropped to the Mac, arrived **as a
folder**, and imported through Settings → Import Archive… with its image captures landing
in the library.

## Why this was the last open thing in S6

S6 chose "whatever moves a folder" over a sync service (091 · D4), which is only a
defensible choice if something actually moves a folder. Every other part of S6 has a test:
`InboxArchive` writes one, `CaptureDecoder` reads one, and S6c drives phone → archive →
Mac library end to end in `AtelierRefsTests`. The transport had none, because **a simulator
has no AirDrop** — so the plan said "AirDrop, iCloud Drive, a cable" on the strength of
those being things that move folders, and left it at that.

The specific doubt was that AirDrop might refuse a directory, or accept it by silently
zipping it — which would have meant the Mac's importer receiving something it does not
read. It does neither. The folder arrives as a folder.

## What this retires

`NSFileCoordinator`'s `.forUploading` zip was specified as the fallback and is **not
built**. It stays in the plan as the answer if a future transport refuses a directory,
which is the only thing it was ever for. Building it now would be code with no caller
defending against a failure that does not occur.

## Files

Documentation only — `.docs/092` gate discharged. No code was needed, which is the
outcome the slice wanted.

## Verification

By hand on a device, because that is the only place the question exists: export from the
phone's inbox (4 pending), AirDrop to the Mac, import. The two byte-carrying captures
landed as images. The two `payload=none` link captures from Safari are expected to land as
link assets rather than images; that half is not separately confirmed here.
