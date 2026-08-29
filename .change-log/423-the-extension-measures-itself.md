# 423 — the extension measures itself

Gate 2 (092 · "Gates and risks" 2) asks for the share extension's footprint against the
~120 MB ceiling, and has asked since 395 on the grounds that it must be a **measurement,
not an assertion**. It stayed open because the obvious instrument does not fit the target.

## Why not Instruments

The process lives about two seconds, is launched by another app, and dies as soon as the
receipt card dismisses. Attaching a profiler to that is a matter of timing luck, and the
one number that matters is the peak — the thing you miss when you attach late.

It is also easy to measure the wrong number. `Allocations` reports the heap; jetsam kills
on `phys_footprint`, which is dirty plus compressed. Xcode 26 no longer ships VM Tracker,
so the instrument that used to show the right figure is gone.

And a debug build measures itself, not the product: `AtelierRefsShare.debug.dylib` is
~30 MB, and this configuration also compiles with `-profile-generate
-profile-coverage-mapping`. A debug-attached extension can be jetsammed where the shipping
one sits comfortably — which is exactly what happened while trying to profile it, and is
evidence about the scaffolding rather than about the code.

## What it does instead

`footprint()` reads `phys_footprint` from `TASK_VM_INFO` and pairs it with
`os_proc_available_memory()`, and the existing `captured` line carries both:

```
captured <uuid> platform=twitter payload=<file>.bin bytes=27384219 \
  footprint=6.3MB headroom=113.7MB
```

`bytes=` is there so the footprint never has to be read next to a remembered file size.
A footprint of 6.3MB means nothing on its own; 6.3MB while writing a 27MB payload is the
whole claim. The two belong on one line or the measurement decays into an anecdote.

Two syscalls on a path that has already done file I/O, so it stays in permanently.

**Read at the capture, because that is the high-water mark** — the bytes have been fetched
or adopted and the writer has just staged and committed them. Anything read earlier
measures the wrong moment.

`headroom` is the more useful half. The 120 MB ceiling is observed, not documented, so a
footprint on its own has to be compared against a number nobody guarantees; remaining
memory is what the system itself is willing to state.

It also keeps working as the regression check gate 2 exists for. Risk 2 is not "the
extension is too big today", it is "do not let a small optimization pull decoding back
into this process" — and that is a thing a permanent log line can catch and a one-off
profiling session cannot.

## How to take the measurement

1. Release build — Product → Profile, or Run with the scheme's build configuration set to
   Release. **Not** a debug build with the debugger attached.
2. Share a large photo (ProRAW, a panorama), the worst case for
   `harvest` → `adopt` → `InboxWriter.write`.
3. Read `footprint=` and `headroom=` off the `captured` line in Console.

## Files

| File | Change |
|---|---|
| `AtelierRefs/AtelierRefsShare/ShareViewController.swift` | `footprint()`; the `captured` line carries it |

## Verification

`Tier2ShareUITests` on the simulator — **TEST SUCCEEDED**, with a record and its payload
written. The numbers mean nothing there: a simulator has no jetsam ceiling and no memory
pressure. The measurement is a device exercise, and a device produced it.

**Gate 2, measured (device, Release, debugger detached):**

| share | payload | footprint | headroom |
|---|---|---|---|
| link capture | 0 | 6.2 MB | 113.8 MB |
| photo | 16,337,697 B | 6.4 MB | 113.6 MB |

Two readings worth stating separately.

**The ceiling is exactly 120.0 MB.** `footprint + headroom` sums to it on every share.
"~120 MB, observed not documented" has been the plan's phrasing since 395; it is right,
and it no longer has to be hedged.

**16.3 MB of payload costs 0.2 MB of memory.** That image in memory would be ~22 MB. The
80:1 ratio between payload and footprint is only possible if the bytes never enter this
process's address space — file copies from `loadFileRepresentation` through `adopt` to
`write`. S2's "write bytes, decode nothing" is demonstrated rather than asserted, which is
what gate 2 asked for.

Not measured: the 64 MiB cap itself. The largest payload seen is 16.3 MB, and the claim
that the footprint stays flat to the cap rests on the mechanism — a file copy does not
scale with the file — rather than on a reading at it.
