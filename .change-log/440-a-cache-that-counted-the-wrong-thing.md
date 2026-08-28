# 440 — a cache that counted the wrong thing

`ThumbnailCache` bounded itself by entry count and not by bytes:

```swift
// A generous count rather than a byte budget: these are display tiers, a phone
// screen holds a dozen, and the memory ceiling that matters on iOS belongs to
// the share extension (091 · D2), not to the app.
cache.countLimit = 240
```

Both halves of that reasoning have a hole, and the second one opened after it was written.

**"A phone screen holds a dozen"** describes what is *visible*. The cache retains 240
whatever is on screen — that is what a cache is for. The sentence justifies the working
set and then sets a limit twenty times larger than it.

**"The ceiling that matters belongs to the share extension"** is true of the extension's
observed ~120 MB and says nothing about the app, which has its own jetsam limit and is the
process doing the scrolling.

## Two populations, four times apart

The detail screen joined the grid on this cache, and they decode to very different sizes:

| consumer | tier | `maxPixel` | decoded RGBA |
|---|---|---:|---:|
| `GridTile` | 512 | ~570 (a 2-column phone layout at 3×) | ~1.3 MB |
| `ItemDetailScreen` | 1280 | ~1170 (full width at 3×) | ~5.5 MB |

240 entries of the second is well over a gigabyte. Nothing but `NSCache`'s own
memory-pressure eviction stood between a browse-heavy session and that number.

Pressure eviction is real, so this was never a guaranteed crash — which is exactly why it
was easy to miss. The likely symptom is the milder and more annoying one: a cache that
grows until the system pushes back, then evicts a screenful of tiles that are immediately
re-decoded on the next scroll frame.

## 96 MB, charged by what the bitmap actually weighs

`totalCostLimit` is what the API is for, and the cost is `bytesPerRow * height` off the
backing `CGImage` — the real allocation, not a guess from the point size, so a wide
panorama and a tall skyscraper at the same `maxPixel` are each charged what they cost.

The count limit stays as the coarse bound. `NSCache` enforces whichever is hit first, and
the two answer different questions: 240 caps how many keys pile up, 96 MB caps what those
keys weigh. The second is the one that matters on a phone.

96 MB holds several screenfuls of tiles plus a handful of detail images — the working set
of actually paging around a library — and leaves the rest to be re-decoded, which is cheap
because the files on disk are already small JPEGs. That is the property that makes a modest
budget the right answer rather than a painful one.

## Files changed

- `AtelierRefs/AtelierRefsMobile/ThumbnailImage.swift` — `byteBudget` constant,
  `cache.totalCostLimit`, `cost(of:)`, and the cost passed at `setObject`.

## Verification

`xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'`
→ `** BUILD SUCCEEDED **`.

Not measured on a device. The change is a bound, not a tuning: 96 MB is a defensible point
rather than a number anything observed, and the honest way to move it is a browse session
with the memory graph open — which is [14A](../.docs/092-ios-companion-plan.md)'s job, not
this one's.

## Migration notes

None. Behaviour is unchanged until the cache would have exceeded 96 MB, which is the case
that previously had no answer.
