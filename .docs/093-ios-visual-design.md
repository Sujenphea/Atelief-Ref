# 093 — iOS companion: what the phone actually looks like (design)

> The visual spec for the companion decided in
> [091](091-ios-companion-overview.md) and built by
> [092](092-ios-companion-plan.md). It exists because 092 · S5 specifies the
> phone's UI entirely as a list of exclusions — *"a `LazyVGrid` … No
> `UICollectionView` bridge. No Spaces, no canvas, no reorder, no multiselect"* —
> and S4b is about to draw the first pixels this product ever shows on a phone.
> A list of exclusions is a scope, not a design.
>
> Planned against the code as it stands on `feat/ios-companion` (2026-08-14).
> Every token, hex value and line citation below was read at the line cited, not
> remembered — 092 records stale citations as a recurring error here.
>
> Three things get decided: what the share sheet does, what replaces the sidebar,
> and whether the phone's grid keeps the Mac's rhythm. What it deliberately does
> not decide is listed at the end, so the boundary is legible the way 091's and
> 092's are.

## The design that was about to happen by accident

Nothing on the phone is designed. 091 · D1 settled that the companion is not a
port, and every doc since has been about contracts — the capture DTO, the inbox
record, the drain. That was the right order: S0–S4a landed without an iOS target
existing at all. But it means the first UI decision is being made under
provisioning pressure, in the slice that also invents two Xcode targets, and the
default answers are all available: a stock share-extension form, a
`NavigationSplitView` that collapses to something, `LazyVGrid` with a fixed
`GridItem`. Each is one line, and each quietly decides something the desktop
argued about for thirty-nine documents.

The share sheet in particular is not a small surface. It is the *only* surface in
v1 that a user touches on purpose — browse is what you do afterwards — and it is
the one 091 · D2 constrained hardest, because it runs in a process that must not
open the database.

---

## 1. The share sheet posts and dismisses

**Decided: the extension writes the record and dismisses itself behind a
non-interactive confirmation card. No collection picker, no form, no fields.**

### The architecture argument, which is not the whole argument

092 · S3 settled the target collection at `decoded.collectionID ??
Collection.unsortedID` (`Collection.swift:18`) — the same default the browser
capture endpoint already uses. A picker would have to fill that first operand,
and the extension has no way to know what the options are. It never opens SQLite
(091 · D2), and the three ways across that boundary all cost more than the
picker is worth:

- the host denormalises the collection tree into a JSON file in the App Group and
  the extension reads it — a second, eventually-stale copy of a structure the
  database owns, which is precisely the drift S0 was written to prevent for
  provenance;
- the extension opens the library read-only — GRDB is already on its link line
  (092 · S2 · decision 4), so this is *reachable*, and that is what makes it
  dangerous: D2's invariant is behavioural, and "read-only, just this once" is how
  a one-writer boundary stops being one;
- ask the host at share time — there is no host; a share extension runs whether
  or not the app is alive.

### The UX argument, stated on its own terms

Suppose the boundary were free. A picker would still lose.

A share sheet is an interruption of a different app. The user is reading X, taps
Share, taps Atelier, and wants to be back in X. Post-and-dismiss is one tap and
about a second. A confirmation sheet with a picker is a tap, a screen to read, a
filing decision, and a confirm — and it asks for that decision at the moment the
user has the *least* context: one item in hand, and no view of the collection it
would join. Filing is a comparison, and there is nothing to compare against.

That is 091 · D1's thesis restated at the level of a screen: *capture happens
where you are, curation happens at a desk.* A picker in the share sheet is
curation on a phone.

**The honest cost.** Everything lands in Unsorted, so Unsorted grows, and
clearing it is Mac work. But that pile already exists — every browser capture
with no target lands in exactly the same place (092 · S3), and the phone feeds an
existing chore rather than inventing one. The cheap mitigation, if it turns out
to bite, is a *move* action on the phone's own browse surface, where the
collection is on screen and the comparison is possible. That is a v1 scope
question, not a share-sheet question, and it is left open below.

### What the user sees

**Success.** A card, and then the sheet is gone. Not silence: 091 · D2 names *"a
share sheet that silently does nothing"* as the failure this whole design exists
to avoid, and instant `completeRequest` in `viewDidLoad` is indistinguishable from
it. Not a form either. The card is `ToastCard`'s recipe
(`ToastHost.swift:105`–`:151`) with both buttons removed:
`Theme.Colors.surface` (`#232326`, `Theme.swift:32`) at `Theme.Radius.card` (12,
`Theme.swift:142`), a `hairline` border (`Theme.swift:67`), `Elevation.hover`
(`Theme.swift:188`), the message in `Typography.body` (`Theme.swift:243`).
It animates in on `Motion.toast` (`Theme.swift:169`) and out on `Motion.gentle`
(`:168`), over a clear backdrop so the host app stays visible behind it — the
card is a receipt, not a screen.

The message names the destination: **"Saved to Unsorted"**. That mirrors the Mac's
capture toast (`"Saved \(batch.importedCount) to \(batch.collectionName)"`,
`ContentView.swift:257`), and the destination is the one fact the user cannot
otherwise discover, since nothing else in the flow mentions a collection.

*"Saved" is a small lie and it is the right word.* At the instant the card
appears, the item is an inbox record, not an asset — the host ingests it later.
But the record is durable and committed: `InboxWriter` writes the payload first
and the record second precisely so the record is the commit marker (092 · S2), and
there is no ordinary path from a committed record to a missing asset. The only
exception is host-side quarantine after three failures (092 · S3), which is a bug
and belongs on the surface that can show it. "Queued" would be accurate about the
mechanism and useless about the outcome.

**Failure.** `InboxWriteError` has four cases (`InboxWriter.swift:46`–`:62`) —
inbox unavailable, payload write failed, record encoding failed, record write
failed — and its own doc states the property that collapses them into one UI:
every case is a lost capture, and every case leaves nothing partial for the drain
to act on. So there is one failure card, not four: the same geometry, the message
in `Theme.Colors.warning` (`Theme.swift:93` — the app's single alarm colour and
its only deliberate exception to monochrome), and **it does not auto-dismiss**. A
failure the user did not have time to read is a silent failure with extra steps.

No retry button. Every one of the four cases is a container- or filesystem-level
condition that a second attempt three hundred milliseconds later will hit again;
re-sharing is the retry, and it is a gesture the user already knows. The typed
payloads (`path:`, `id:`) stay in the log — that vocabulary is for whoever reads
the log, not for someone holding a phone.

The alternative was `cancelRequest(withError:)` and letting the system present
the failure. Rejected because the wording would not be ours, and a
system-presented extension failure reads as a crash rather than as "that one
didn't save."

> **A fifth case, and the one sentence that does not fit it** (2026-08-15, changelog
> [406](../.change-log/406-the-image-the-extension-never-held.md)). `InboxWriteError`
> now has five cases: `payloadTooLarge(bytes:limit:)` refuses a share above
> `InboxWriter.maximumPayloadBytes` (64 MiB) before a byte of it is copied, so that an
> absurd share fails *here* rather than by getting the extension jetsammed and leaving a
> share sheet that silently did nothing (091 · D2). It renders on this card, unchanged
> and un-argued-with: it is a lost capture, it leaves nothing partial, and one card was
> always the right answer to that.
>
> What it does not fit is **"Try sharing again."** For the other four, re-sharing is a
> legitimate retry — a full disk empties, a locked device unlocks. For this one, sharing
> the same photo again is guaranteed to fail identically, and the card is telling the
> user to do a thing that cannot work. Raised here rather than reworded on a hunch,
> because the fix is a judgement call between three bad options: a second message (which
> gives up the one-card property this section argues for), a vaguer sentence for all
> five (which makes the common cases less useful to serve the rare one), or leaving it.
> Verified on a simulator with an 82 MiB share: the card appears, stays, and says the
> retry line. It is the user's call on a device, like the dismiss delay.

### Sharing the same thing twice says nothing, on purpose

18A blob-hash dedup makes the second share a no-op:
`IngestOutcome.ingested(asset:deduplicated:)` (`IngestInput.swift:124`) carries
the flag, and `DrainSummary` counts a dedup as an ingest because *"a dedup IS a
successful ingest, and the capture is just as done with"*
(`InboxDrain.swift:62`–`:65`).

The extension cannot know this. It has no database, which is the entire point of
D2, so it shows the same "Saved to Unsorted" card both times and one asset
exists. **We accept that and do not build a phone-side duplicate check.** It
would be technically possible — the extension holds the bytes and could hash them
— but it would need a hash set maintained by the host in the App Group: a second
copy of a fact the library owns, kept in sync across two processes, to warn the
user about an outcome that is already correct. That is the drift S0 exists to
prevent, spent on a non-problem.

What the user loses is a signal that their second share was redundant. What they
never get is a wrong library.

---

## 2. Navigation: the sidebar reduces to one thing, so it should not be a sidebar

**Decided: a single `NavigationStack` rooted at the Unsorted grid, with the
collection switcher in the toolbar. No tab bar, no collections list as root.**

Start by subtracting. The Mac sidebar (273pt expanded per `SidebarView.swift:7`,
though the frame it actually draws is `.frame(width: 250)` at
`SidebarView.swift:127`; the rail is 60 at `:409`) holds six things:

| Sidebar element | On the phone in v1 |
|---|---|
| Nav rows Home / Capture / Archived (`SidebarView.swift:133`–`:148`) | Capture **does not exist** — it is a pairing token and endpoint status for a *browser* extension (`AppShellView.swift:320`–`:339`), and the phone has no endpoint, no token, no browser. Capture on the phone is the share sheet, which is not a screen. Archived is out with the archive round-trip (091 · D1). |
| Settings row (`SidebarView.swift:162`–`:165`) | Opens the ⌘, window on the Mac. The phone has nothing to configure in v1. |
| Spaces section (`SidebarView.swift:195`) | Out — 092 · S5. |
| Collections tree (`SidebarView.swift:247`, an `NSOutlineView`) | **The only survivor.** |
| Footer: sort + trash (`SidebarView.swift:322`) | Both are writes. v1 browse is read-only. |
| Collapse toggle | Chrome for a thing that no longer exists. |

One survivor. A navigation container built to hold one destination type is not a
navigation container; it is a picker.

**Why not a tab bar.** A tab bar wants two or more peer destinations the user
alternates between. v1 has one — the library — and a two-tab bar reading
"Library / Collections" is a filter wearing a tab bar's clothes. It also spends
permanent bottom chrome on a surface whose whole job is showing pictures.

**Why not a collections list as the root.** This is the faithful translation:
Collections → tap → grid → tap → detail, with nesting for free (a subfolder just
pushes). It loses because it puts a list of *folder names* between the user and
the artwork on every cold launch. On the Mac that list costs nothing — it is
permanent chrome to the side, and the grid is on screen at the same time. Promoted
to a root screen it costs a tap and a screenful, every time, to answer a question
("which collection?") the phone user usually is not asking. They are asking "what
did I save."

**So: the grid is the root**, titled with the current collection's name, and the
title is the switcher. Tapping it presents the collection tree as a sheet — a
SwiftUI `List` with `DisclosureGroup`s, ordered by `CollectionTargets.galleryRoots`
(`CollectionTargets.swift:19`), which is already the app's single ordering
authority with Unsorted pinned (`SidebarView.swift:15`–`:16`). Rows carry a
thumbnail rather than a bare name, borrowing the idea from the Mac's Home gallery
of cover cards: a reference library's collections are recognised by their contents,
not their spelling. Drilling into a subfolder pushes onto the same stack; item
detail pushes onto it too.

**The root collection is Unsorted, always, in v1.** It is where every share lands
(092 · S3), so it is the answer to "what did I save" by construction. Restoring
the last-viewed collection — which the Mac does, `NavModel.swift:51`–`:53` — is a
second mechanism and a preference the phone has not yet earned; it can arrive when
the phone has enough browsing history for "last viewed" to mean something.

The detail screen it pushes to echoes the Mac's, but a phone has no room for a
fixed 298pt side panel (`ItemDetailView.swift:461`): the three 041 sections (Data,
Source, Details) move below the media in one scroll, in the same order. The full
detail spec is not decided here — see §6.

---

## 3. The grid keeps its rhythm, and it costs almost nothing

**Decided: masonry, reproduced as `C` lazy column stacks. Not uniform, and not a
ported custom `Layout`.**

092 · S5 says `LazyVGrid`, which does uniform rows. The Mac grid is masonry:
variable heights packed into columns. Same content, different rhythm — so S5 as
written silently undoes a decision rather than deferring one. `MasonryLayout`'s
own header records that it *replaced* a uniform `.adaptive` `LazyVGrid`
(`MasonryLayout.swift:5`–`:7`). In a reference library the shape of an image is
part of its information; a uniform grid either crops it away or pads around it.

### What is portable, precisely

| File | Lines | Verdict |
|---|---:|---|
| `MasonryLayout.swift` | 129 | **Fully portable.** Imports `AtelierCore` and `CoreGraphics` only (`:22`–`:23`) — no AppKit, no SwiftUI. `layout(...)` (`:79`) is a pure function over `[Double]`; `aspect(for:)` (`:125`) bottoms out in `SpaceLayout.aspect` (`SpaceLayout.swift:32`), which is `width/height` arithmetic on an `Asset`. |
| `MasonryLayoutCache.swift` | 55 | Portable and **unnecessary**. Its stated reason is the marquee republishing a selection many times per second (`:5`–`:13`). The phone has no marquee. |
| `MasonryCollectionLayout.swift` | 303 | Not portable — `NSCollectionViewLayout` (`:41`). Worth noting what it is *not*: it contains no masonry math at all, by its own header (`:6`–`:8`). It is a rect-query adapter (`layoutAttributesForElements(in:)` at `:257`, delegating to `masonryMarqueeIndices`, `MarqueeMath.swift:94`) plus one invalidation rule (`:300`). `UICollectionViewLayout` has that same shape — which is exactly the bridge S5 forbids. |
| `MasonryGridHost.swift` | 2,113 | Not portable, and mostly not wanted. Its bulk is interaction, not layout: `GridHostConfiguration` (`:37`) carries a selection store, ⌫ and ⌘⌫, ⌘C, Quick Look, ⌘±, the M/A destination verbs, drag payloads, drag images and a context menu. Every one of those is excluded by 092 · S5. |

So the honest split is 129 portable lines of arithmetic wrapped in ~2,400 lines of
AppKit interaction that v1 does not have.

### The property that makes this cheap

`MasonryLayout` is **round-robin fixed-column**: item `i` lives in column
`i % cols` (`MasonryLayout.swift:96`), and the header says why — feed order equals
reading order, and `row = i / C` stays clean (`:6`–`:9`). It is not
shortest-column-first packing. Column membership is therefore a function of the
index alone, which means the layout *decomposes*: column `c` is the subsequence
`stride(from: c, to: n, by: C)`, stacked top to bottom with `spacing`, each cell
`columnWidth / aspect` tall.

An `HStack` of `C` `LazyVStack`s reproduces those frames exactly. No solver is
ported, no custom `Layout` is written, no collection-view bridge appears, and each
column stays lazy. The rhythm the desktop chose survives because of how it was
chosen.

### Why the two alternatives lose

**Uniform `LazyVGrid`.** Wins on being one line with no unknowns. Loses because it
is not a scoping decision — it is a different library, on a surface showing the
same content, reverting 011-B1 without arguing with it.

**Port the math to a SwiftUI custom `Layout`.** The idiom is not new here;
`TagFlowLayout` (`ItemDetailView.swift:2190`) is already a custom `Layout` in this
app. It loses on laziness: a `Layout` receives `Subviews`, so every subview is
instantiated, and inside a `ScrollView` there is no windowing — a 2,000-item
collection builds 2,000 cells. The Mac measured what that shape costs: at 2,000
items the windowed SwiftUI grid ran p95 50.90 ms against a 16.67 ms budget
([038](038-grid-bakeoff-results.md) § 2). The point is *not* to re-run that
bake-off on iOS — 092 · S5 excludes it and this doc respects that — but knowingly
walking into the shape that lost is not deference to scope, it is amnesia.

**The gate, and the fallback.** That `LazyVStack`s nested in an `HStack` inside a
`ScrollView` stay lazy is the standard SwiftUI recipe, and it is **not verified
here**. S5 should check it the cheap way — scroll a 2,000-item collection and
confirm cell bodies are not built for offscreen items. If it fails, fall back to
uniform `LazyVGrid`. That fallback is a rollback of a layout container, not a
measurement exercise: no protocol, no harness, no gate document. Which is the
whole reason to choose this option over the custom `Layout`, whose failure mode
would have no fallback short of the bridge S5 forbids.

### Column count is a phone constant, not the Mac's notch

`GridDensity` is pure and width-parameterised (`GridDensity.swift:25`), so it
ports — and should not be used. Its stored default is 4 columns (`:31`), which on a
390pt screen gives ~95pt cells; and its width floor, `ceil(width / 512)`
(`:41`), evaluates to 1 there, so nothing catches it. The persisted notch also
lives in `UserDefaults.standard` (`:82`, `:96`), which is not the App Group and
does not cross to the phone anyway.

The phone uses **2 columns in portrait, 3 in landscape**, as a local constant.
There is no ⌘+/⌘− on a phone, and pinch-to-change-density is a gesture v1 has no
need to invent.

---

## 4. Which tokens cross, and which are macOS wearing a token's name

`Theme.swift` is a palette plus four scales plus nine type roles. Most of it is
screen-size-independent and crosses unchanged; what does not cross is not a matter
of size but of *input device* and *window*.

**Crosses unchanged.** The whole palette except the two hovers: `canvasOuter`
`#131313` (`:28`), `panel` `#212121` (`:30`), `surface` `#232326` (`:32`), `field`
`#2C2C30` (`:39`), `selection` `#3A3A40` (`:42`), `mediaBackdrop` `#141416`
(`:56`), `inkPrimary` `#F2F1EE` (`:63`), `inkSecondary` `#9A9A9E` (`:65`),
`hairline` (`:67`), `hairlineStrong` (`:69`), `warning` (`:93`). The 4-pt spacing
scale (`:120`–`:127`) — a rhythm, not a density; 4/8/12/16/24/40 reads the same at
390pt as at 1100. `Radius` chip/field 6, tile 8, card 12, cover 14, panel 16
(`:131`–`:150`). `Motion.snappy` / `gentle` / `toast` (`:167`–`:169`) — durations
and damping, not platform behaviours. `Elevation.hover` / `floating` (`:188`,
`:193`) via the SwiftUI `.elevation()` modifier (`:272`). `disabledOpacity` 0.35
(`:162`), whose stated reason — `.plain`-family controls drop the system's own
dimming — is a SwiftUI fact and therefore true on both platforms.

**Typography crosses, and crosses better.** The nine roles (`:216`–`:265`) are
each *a text style plus a weight, deliberately not a point size*, and the comment
above them (`:206`–`:215`) says why: `Font.system(size:)` does not scale with
Dynamic Type. That reasoning was written for a Mac, where the setting is obscure.
On a phone it is a setting people actually use, so the app inherits accessibility
sizing on the platform where it matters most, for free.

**Does not cross.**

- `Colors.hoverRow` (`:75`) and `Colors.hoverControl` (`:78`). No pointer, no
  state to paint. They must *not* be quietly repurposed as press feedback:
  `hoverRow` is documented as deliberately a whisper so it cannot be mistaken for
  `selection` (`:71`–`:75`), and a press wants to be unmistakable. SwiftUI's own
  button press treatment is the right answer.
- `Theme.NS` (`:106`) — the `NSColor` mirrors. The enum's justification is that
  every `NSView` / `CALayer` seam draws from there (`:96`–`:99`), and v1 has no
  such seam. Its own rule governs any future UIKit twin: a mirror with no reader
  is a second copy waiting to drift (`:100`–`:105`), so it is added when something
  reads it, not before.
- `CALayer.applyElevation` (`:281`). Its body exists to flip the shadow's y sign
  because AppKit's axis is not flipped; UIKit's is. Pure platform.
- `VisualEffectBackground` (`:346`), an `NSViewRepresentable` over
  `NSVisualEffectView`. It exists so the desktop shows through the window's outer
  margins (`ContentView.swift:44`–`:55`). A phone has no window margins and no
  desktop behind them. The phone's ground is `canvasOuter` painted opaque.
- **The panel's geometry, but not its colour.** The Mac insets its content panel
  by `Spacing.md` and clips it to `Radius.panel` (`AppShellView.swift:145`–`:148`)
  because it is a panel inside a window beside a sidebar. The phone has none of
  those, so it paints `Colors.panel` full-bleed: the token supplies the tone, the
  inset and the corner arc stay on the desktop.
- `selectionMark` (`:48`) and `selectionMarkContrast` (`:54`) cross as *values*
  and are drawn by nothing. They exist because marquee-select does — the ring is
  "the selection MARKER drawn over ARTWORK" (`:43`–`:47`) — and v1 has no
  multiselect. Keep them (same palette, and the two-sided-edge reasoning is
  already correct for artwork on any screen); do not invent a phone use.

---

## 5. Touch targets, and what hover was quietly carrying

Every hit area in the Mac app is undersized for a finger, and the numbers are all
written down:

| Site | Size |
|---|---|
| Rail glyphs (`SidebarView.swift:414`–`:416`) | 28 × 28 |
| `Radius.control`'s stated case (`Theme.swift:137`–`:140`) | 15pt icon in a 30 × 28 hit area |
| `HoverHighlight` default padding (`HoverButtonStyle.swift:31`) | 6, so a 15pt glyph ≈ 27pt |
| `PostBadge` capsule + slop (`MasonryGridItem.swift:235`–`:237`) | 18pt tall, +6pt hit padding |

Apple's touch minimum is 44 × 44. Nothing above reaches it, and `PostBadge`'s own
comment already admits the direction of travel — *"fine for a mouse, mean at a
dense zoom."*

**The fix is not to scale the tokens.** `Spacing` and `Radius` describe how
something looks; a hit area is not a look, and inflating the padding to 44 would
make phone chrome visually enormous to solve an invisible problem. The rule is:
visual size stays on the tokens, hit area is a separate `.contentShape(Rectangle())`
of at least 44 × 44 — which is the same separation `HoverHighlight` already makes
between its fill and its padded `.contentShape` (`HoverButtonStyle.swift:38`–`:42`).
Same idiom, different constant.

**What hover was doing, and where it goes.** The Mac grid leans on hover for
everything it refuses to draw permanently over artwork:

| Affordance | Where it lives | v1 phone |
|---|---|---|
| Cell dim at 0.10 (`MasonryGridItem.swift:478`) | "you are pointing at this" | Gone. Touch has no *before* — the tap is the event. |
| Enter-selection circle, shown while hovered or selecting (`:966`) | multiselect entry | Gone with multiselect (092 · S5). |
| GIF animates after a 150 ms dwell (`GifMotion.swift:31`) | motion peek | Gone in v1. The touch equivalent is autoplay-in-view, which is a battery decision nobody has made. |
| `.help()` tooltips — 45 call sites | naming a glyph | Gone. Where a glyph is not self-evident, v1 uses a label. |
| Right-click context menu (`GridContextMenu`) | per-item verbs | Nothing — every verb in it is a write. |

The load-bearing point: on the Mac, hover is *storage* for affordances that would
otherwise be permanent chrome over the pictures. A phone cannot borrow that space,
so v1's answer is that **these affordances do not exist yet**, rather than being
relocated onto the tile. A persistent button in every tile's corner is a worse
grid for the 95% of the time the user is only looking. When multiselect does
arrive, its entry is a long-press — not a visible circle.

---

## 6. Dark only, on a platform that will ask nicely for light

The Mac is committed twice over: `.preferredColorScheme(.dark)`
(`ContentView.swift:43`) and `NSApp.appearance = NSAppearance(named: .darkAqua)`
(`:56`). `Theme`'s header states the rule outright — *"Monochrome by design — both
Figma frames confirm it"* (`Theme.swift:12`–`:14`) — and one cache already depends
on the palette being non-reactive: `PostBadge` never invalidates its rendered
chips because the tokens are fixed, and its comment says explicitly that if the
palette ever becomes appearance-reactive the cache has to be dropped
(`MasonryGridItem.swift:224`–`:229`).

The case for honouring the system setting is real: iOS users set Light or Dark
globally and expect apps to follow, and ignoring it is a visible choice rather
than an omission.

**Decided: the phone is dark only.** `.preferredColorScheme(.dark)` on the root,
plus `UIUserInterfaceStyle = Dark` in the app's Info.plist **and separately in the
share extension's** — the extension is its own bundle and does not inherit the
host app's preference, and a light system chrome around a dark confirmation card
is the worst of both. Three reasons, in order:

1. A light mode is not a variant of these tokens; it is a second design. Every hex
   above would need a counterpart chosen against artwork, and that is a Figma
   exercise nobody has done. Shipping half of it is how `#F2F1EE` ends up on
   `#212121` in bright mode.
2. The dark ground is functional, not stylistic: `mediaBackdrop` is "the art's
   stable dark ground" (`Theme.swift:55`–`:56`), applied so that a light image and
   a dark one sit on the same tone instead of the image's own edges reading as
   chrome (`ItemDetailView.swift:415`). Ambient light does not change that.
3. Two devices showing one library in two palettes is a worse outcome than one
   committed look.

**What it costs, plainly:** a dark UI in direct sun is harder to read and the user
cannot fix it. If that turns out to matter, the fix is a light palette designed
once and applied to *both* platforms — not an iOS-only fork of the token layer.

---

## 7. What this doc does not design

Stated so the boundary is legible, the way 091's open questions and 092's gates
are.

- **The item detail screen's full layout.** §2 decides it is pushed onto the same
  stack and that the 298pt panel reflows below the media. Which of 041's sections
  survive, whether the pager and the fan/pile come along, and what a phone does
  with zoom are all downstream of data reads S5 has not wired.
- **Search.** The Mac keeps a search field permanently in the panel toolbar
  (`AppShellView.swift:156`–`:161`). Whether the phone has search *at all* in v1
  is a scope question for S5, not a look question.
- **Empty and error states**, with one exception worth flagging: 092 · S1 ·
  decision 3 deliberately made a missing App Group container a typed fatal error
  rather than a fallback, so that a provisioning bug fails where it is fixable.
  Something has to render that, and today nothing does. It is the one hole here
  worth closing early in S4b rather than late.
- **iPad.** Everything above assumes a phone. An iPad has room for the sidebar and
  would re-open §2 entirely. v1 is an iPhone app that runs on iPad.
- **Any re-run of [037](037-grid-bakeoff-protocol.md)–[039](039-grid-bakeoff-gate-results.md)
  on iOS.** 092 · S5 excludes it. §3 is written specifically so that no measurement
  is needed to choose — the fallback is a rollback, not a bake-off.
- **App icon, launch screen, App Store presence.**

## Open questions

1. **Should v1 browse have exactly one write — "move to collection"?** 091 · D1
   says read-only, and §1 sends every share to Unsorted, which puts the entire
   sorting cost on the Mac. One write on the phone would let the pile clear itself
   where the collection is actually on screen. This trades a stated invariant
   against a chore whose size nobody has measured yet, and it is a product call, so
   it is the user's rather than this doc's.
2. **How long the confirmation card stays before auto-dismissing.** The Mac's
   toast TTL is 6 s (`ToastQueue.swift:60`), which is far too long for a process
   that is supposed to get out of the way; something under a second is the right
   order. The exact value is a feel judgement that should be set once on a device,
   not guessed here.
