//
//  DetailFanPileTests.swift
//  AtelierRefsTests
//
//  080 §5 · T1 / T3 (the pile's half) — the detail page's resting pile, pinned as pure
//  functions, per `DetailStepTests`' standing strategy for this area: the arithmetic lives
//  here and "should not be tested through the view".
//
//  Two things are load-bearing and neither is covered by the suites that already exist.
//
//  **The composed invariant.** `MasonryGridItemBadgeTests.pileNeverClips` pins
//  `fanPileGeometry` against the CELL's bounds. The page applies the same function to a
//  completely different rectangle — the artwork's FITTED rect inside the media pane, whose
//  aspect ratio is the image's rather than the layout's, and which can be a sliver where a
//  cell never is. Composing `fitRect` into `fanPileGeometry` is the only place that
//  rectangle is checked.
//
//  **The pinch gate.** 070 §5.2 proposed gating the pile on `zoom == 1`. `zoom` is `@State`
//  that only moves at a settle point, so that gate is TRUE for the whole of a pinch out
//  from fit — the pile would keep drawing at fit geometry while the picture scaled away
//  from underneath it. `midPinchHidesThePile` is that bug, written down.
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - T1 · the fitted artwork rect

@Suite("Detail page: where the fitted artwork lands (080 T1)")
struct DetailFitRectTests {

    /// The aspect ratios `pileNeverClips` uses, as INTRINSIC pixel dimensions this time —
    /// the page fits from `Asset.width` / `Asset.height`, not from a layout size.
    nonisolated static let aspects: [(w: Int, h: Int)] = [
        (200, 200),     // square
        (200, 400),     // tall portrait
        (200, 900),     // the extreme a screenshot produces
        (400, 120),     // wide banner
        (90, 90),       // small square
    ]

    /// Panes the media area really takes: a default window, a narrow one, a wide one, and
    /// the smallest the splitter allows before the sidebar takes over.
    nonisolated static let panes: [CGSize] = [
        CGSize(width: 900, height: 700),
        CGSize(width: 420, height: 900),
        CGSize(width: 1600, height: 400),
        CGSize(width: 240, height: 180),
    ]

    // MARK: The fit itself

    @Test("the fitted rect keeps the image's aspect ratio and touches the tight axis")
    func fitsToTheTightAxis() throws {
        // Wider than the pane: width binds, and there is letterboxing above and below.
        let wide = try #require(
            fitRect(contentWidth: 400, contentHeight: 200, in: CGSize(width: 800, height: 800)))
        #expect(wide.size == CGSize(width: 800, height: 400))
        #expect(wide.minX == 0)
        #expect(wide.minY == 200)

        // Taller than the pane: height binds, and the bars are at the sides.
        let tall = try #require(
            fitRect(contentWidth: 200, contentHeight: 400, in: CGSize(width: 800, height: 800)))
        #expect(tall.size == CGSize(width: 400, height: 800))
        #expect(tall.minX == 200)
        #expect(tall.minY == 0)
    }

    /// The whole point of §3.2: laid against the PANE the pile floats detached on the long
    /// axis for every image whose aspect ratio isn't the window's (313 on a new surface).
    @Test("the rect is centred, so a pile laid against it is concentric with the picture")
    func isCentredInThePane() throws {
        let pane = CGSize(width: 900, height: 700)
        for (w, h) in Self.aspects {
            let rect = try #require(fitRect(contentWidth: w, contentHeight: h, in: pane))
            #expect(abs(rect.midX - pane.width / 2) < 0.001)
            #expect(abs(rect.midY - pane.height / 2) < 0.001)
            // And never larger than the box it was fitted into.
            #expect(rect.width <= pane.width + 0.001)
            #expect(rect.height <= pane.height + 0.001)
        }
    }

    /// An image SMALLER than the pane is still scaled UP to fit, because that is what
    /// `.aspectRatio(contentMode: .fit)` does to a `.resizable()` image — the pile has to
    /// agree with the picture, not with the file.
    @Test("a small image is scaled up, as the resizable fit scales it")
    func upscalesToFit() throws {
        let rect = try #require(
            fitRect(contentWidth: 100, contentHeight: 50, in: CGSize(width: 800, height: 800)))
        #expect(rect.size == CGSize(width: 800, height: 400))
    }

    // MARK: Degenerate inputs

    /// `nil` dimensions are a media-less kind (003 · O1) — a tweet, a link, a colour. There
    /// is no artwork to fit and so no pile, which is the branch that keeps the page from
    /// drawing two cards behind a card.
    @Test("nothing to fit yields no rect", arguments: [
        (Int?.none, Int?.none), (nil, 100), (100, nil),     // media-less (003 · O1)
        (0, 100), (100, 0), (0, 0),                         // a corrupt row
        (-100, 100), (100, -100),                           // ditto, signed
    ])
    func degenerateContent(width: Int?, height: Int?) {
        #expect(
            fitRect(contentWidth: width, contentHeight: height,
                    in: CGSize(width: 800, height: 600)) == nil)
    }

    @Test("an unmeasured or collapsed pane yields no rect", arguments: [
        CGSize.zero,                                        // before the first layout
        CGSize(width: 800, height: 0),                      // a fully collapsed splitter
        CGSize(width: 0, height: 600),
        CGSize(width: -10, height: 600),
    ])
    func degeneratePane(pane: CGSize) {
        #expect(fitRect(contentWidth: 200, contentHeight: 200, in: pane) == nil)
    }

    /// `1 × 20000` fits to a rect a fraction of a point wide. `fitRect` answers honestly —
    /// that IS where the picture is — and the page's own floor is what stops two tilted
    /// cards being drawn as a smear behind it.
    @Test("a 1 × 20000 asset fits to a sliver, which the page refuses to pile behind")
    func slenderAssetIsBelowTheFloor() throws {
        let rect = try #require(
            fitRect(contentWidth: 1, contentHeight: 20000, in: CGSize(width: 900, height: 700)))
        // The tall axis binds, to within the rounding of a 1:20000 scale factor.
        #expect(abs(rect.height - 700) < 0.001)
        #expect(rect.width < 1)
        #expect(min(rect.width, rect.height) < DetailFanPileMetrics.minFittedSide)
    }

    /// A pane smaller than the pile's own minimum inset. The fit still resolves (the page
    /// is drawable at any size), and the floor is again what declines the pile.
    @Test("a pane smaller than minInset still fits, and still draws no pile")
    func paneSmallerThanTheInset() throws {
        let pane = CGSize(
            width: DetailFanPileMetrics.minInset - 1, height: DetailFanPileMetrics.minInset - 1)
        let rect = try #require(fitRect(contentWidth: 200, contentHeight: 200, in: pane))
        #expect(rect.size == pane)
        #expect(min(rect.width, rect.height) < DetailFanPileMetrics.minFittedSide)
    }

    // MARK: The composed invariant — the test that actually matters (080 §5 · T1)

    /// Whether `point` is inside a rounded rect of `size` centred on the origin. Lifted
    /// from `MasonryGridItemBadgeTests` deliberately: the pile's containment claim must be
    /// checked by the SAME shape on both surfaces, or "it fits" would mean two things.
    private func insideRounded(_ point: CGPoint, size: CGSize, radius: CGFloat) -> Bool {
        let dx = max(0, abs(point.x) - (size.width / 2 - radius))
        let dy = max(0, abs(point.y) - (size.height / 2 - radius))
        return dx * dx + dy * dy <= radius * radius + 0.01
    }

    private func pileGeometry(in size: CGSize) -> (inset: CGFloat, degrees: Double) {
        fanPileGeometry(
            in: size, maxDegrees: DetailFanPileMetrics.maxDegrees,
            maxInset: DetailFanPileMetrics.maxInset, minInset: DetailFanPileMetrics.minInset,
            cornerRadius: DetailFanPileMetrics.cornerRadius)
    }

    /// **The one that matters.** `fanPileGeometry` is pinned against a CELL's bounds
    /// elsewhere; here it is composed onto the rectangle this feature actually uses, whose
    /// aspect ratio is the IMAGE's and not the layout's. Every (image × pane) pair, so a
    /// derivation that happens to hold for a square picture in a landscape window cannot
    /// pass.
    ///
    /// Containment is what licenses the page's outset (see ``DetailFanPile``): an inset
    /// card fitting the fitted rect is the same statement as a fitted-SIZE card overhanging
    /// it by no more than that inset, which is the budget `mediaArea`'s padding pays.
    @Test(
        "no card corner escapes the FITTED rect, at any image × pane",
        arguments: aspects, panes)
    func pileNeverClipsTheFittedRect(aspect: (w: Int, h: Int), pane: CGSize) throws {
        let fitted = try #require(
            fitRect(contentWidth: aspect.w, contentHeight: aspect.h, in: pane)).size
        // Below the page's own floor no pile is drawn at all, so there is nothing to
        // contain — and `fanPileGeometry`'s "never eat more than half" ceiling has taken
        // over from its geometry by then. `slenderAssetIsBelowTheFloor` pins the floor.
        guard min(fitted.width, fitted.height) >= DetailFanPileMetrics.minFittedSide else { return }

        let radius = DetailFanPileMetrics.cornerRadius
        let (inset, degrees) = pileGeometry(in: fitted)
        let w = fitted.width - 2 * inset, h = fitted.height - 2 * inset
        #expect(w > 0 && h > 0)
        let t = CGFloat(degrees * .pi / 180)
        for sx in [CGFloat(-1), 1] {
            for sy in [CGFloat(-1), 1] {
                let x = sx * w / 2, y = sy * h / 2
                let rotated = CGPoint(
                    x: x * cos(t) - y * sin(t),
                    y: x * sin(t) + y * cos(t))
                #expect(insideRounded(rotated, size: fitted, radius: radius))
            }
        }
    }

    /// The page's own half of that budget: the cards are drawn at the fitted rect's SIZE,
    /// so what they spend is the swing OUTWARD, and it has to land inside `mediaArea`'s
    /// `lg` padding or the pile would paint over the divider next to the sidebar. This is
    /// what keeps `DetailFanPileMetrics.maxInset` (12) tied to `Theme.Spacing.lg` (16):
    /// `fanPileGeometry` caps the tilt at `2 · maxInset / longest side`, and the swing is
    /// that tilt times half the longest side.
    @Test("the pile's swing stays inside the media pane's padding", arguments: aspects, panes)
    func swingFitsThePadding(aspect: (w: Int, h: Int), pane: CGSize) throws {
        let fitted = try #require(
            fitRect(contentWidth: aspect.w, contentHeight: aspect.h, in: pane)).size
        guard min(fitted.width, fitted.height) >= DetailFanPileMetrics.minFittedSide else { return }

        let t = CGFloat(pileGeometry(in: fitted).degrees * .pi / 180)
        let c = cos(t), s = sin(t)
        // How far a `fitted`-sized card, turned by the drawn angle, reaches past the
        // artwork on each axis.
        let horizontal = (fitted.width * (c - 1) + fitted.height * s) / 2
        let vertical = (fitted.height * (c - 1) + fitted.width * s) / 2
        #expect(horizontal <= Theme.Spacing.lg)
        #expect(vertical <= Theme.Spacing.lg)
    }
}

// MARK: - T3 · the pile's visibility

@Suite("Detail page: whether the pile is drawn (080 T3)")
struct DetailFanPileVisibilityTests {

    /// The rule the cell states (`postMemberCount > 1`) crossed with the one 080 §2.3
    /// corrects. `memberCount` is never 1 in practice — `PostGroups` drops every group of
    /// one — but the predicate says `> 1` because that is how the cell says it.
    @Test("member count × live scale decides the pile", arguments: [
        (0, CGFloat(1.0), false),       // ungrouped, at fit
        (1, CGFloat(1.0), false),       // a would-be single (never produced; still refused)
        (2, CGFloat(1.0), true),        // the smallest real post
        (15, CGFloat(1.0), true),       // a full rednote carousel (020)
        (0, CGFloat(1.4), false),
        (1, CGFloat(1.4), false),
        (2, CGFloat(1.4), false),       // mid-pinch: `zoom` still says 1, the picture does not
        (15, CGFloat(1.4), false),
        (0, CGFloat(2.5), false),
        (1, CGFloat(2.5), false),
        (2, CGFloat(2.5), false),       // zoomed in and settled
        (15, CGFloat(2.5), false),
    ])
    func visibility(memberCount: Int, effectiveScale: CGFloat, expected: Bool) {
        #expect(showsFanPile(memberCount: memberCount, effectiveScale: effectiveScale) == expected)
    }

    /// **The case §2.3 exists for.** Through a pinch out from fit, `zoom` — the `@State` —
    /// is still exactly `1`: the magnification lives in `@GestureState pinch` and is only
    /// folded in at `MagnifyGesture.onEnded`. So the gate 070 §5.2 proposed is true for the
    /// whole gesture, and the pile would sit at fit geometry while the artwork scaled away
    /// from underneath it, then vanish when the fingers lifted.
    @Test("mid-pinch the pile is gone, though `zoom` alone would have kept it")
    func midPinchHidesThePile() {
        let zoom: CGFloat = 1           // @State — unmoved for the entire gesture
        let pinch: CGFloat = 1.35       // @GestureState — moving on every tick

        #expect(zoom == 1)              // 070 §5.2's gate: still true, still wrong
        #expect(!showsFanPile(memberCount: 4, effectiveScale: zoom * pinch))

        // A pinch INWARD is the same problem mirrored — the artwork shrinks below fit
        // while `zoom` is clamped at 1, so the pile would stand proud of the picture.
        #expect(!showsFanPile(memberCount: 4, effectiveScale: zoom * 0.7))
    }

    /// The settle points, both of them: a gesture that ends back at fit (`onEnded` clamps
    /// `zoom` to 1 and `pinch` reverts to 1) and a double-tap reset (`zoom = 1` directly).
    /// Both arrive at the same one scalar, which is the reason it is one scalar.
    @Test("back at fit — by gesture or by double-tap — the pile returns")
    func settlingAtFitRestoresThePile() {
        #expect(showsFanPile(memberCount: 4, effectiveScale: 1 * 1))
        // Double-tap: `zoom` is assigned 1 while no pinch is in flight.
        #expect(showsFanPile(memberCount: 4, effectiveScale: 1))
        // And the float slack, so a product that lands a hair off fit still counts.
        #expect(showsFanPile(memberCount: 4, effectiveScale: 0.9999))
    }

    /// The page's floor on the artwork itself. Not part of `showsFanPile` — it is a
    /// property of the RECT, not of the post — but it is the other half of "is there a
    /// pile", so it is pinned beside it.
    @Test("a picture below the floor gets no pile however big its post")
    func slenderArtworkIsRefused() throws {
        let sliver = try #require(
            fitRect(contentWidth: 1, contentHeight: 20000, in: CGSize(width: 900, height: 700)))
        #expect(showsFanPile(memberCount: 15, effectiveScale: 1))
        #expect(min(sliver.width, sliver.height) < DetailFanPileMetrics.minFittedSide)
    }
}

// MARK: - `fanBackingRotations` — one statement of the off-by-one

@Suite("Fan backing rotations (080 §3.4)")
struct FanBackingRotationsTests {

    private let seed = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    private let other = UUID(uuidString: "FEDCBA09-8765-4321-FEDC-BA0987654321")!

    @Test("same seed + count → identical angles, as `fanRotations` promises")
    func deterministic() {
        #expect(
            fanBackingRotations(seed: seed, cardCount: 2)
                == fanBackingRotations(seed: seed, cardCount: 2))
        #expect(
            fanBackingRotations(seed: seed, cardCount: 2)
                != fanBackingRotations(seed: other, cardCount: 2))
    }

    @Test("returns exactly `cardCount` angles — the front card is not one of them")
    func countMatches() {
        #expect(fanBackingRotations(seed: seed, cardCount: 0).isEmpty)
        #expect(fanBackingRotations(seed: seed, cardCount: 1).count == 1)
        #expect(fanBackingRotations(seed: seed, cardCount: 2).count == 2)
        #expect(fanBackingRotations(seed: seed, cardCount: 7).count == 7)
        // A negative count is a caller bug, not a crash.
        #expect(fanBackingRotations(seed: seed, cardCount: -3).isEmpty)
    }

    @Test("all angles stay within ±maxDegrees")
    func withinBounds() {
        for angle in fanBackingRotations(seed: seed, cardCount: 4, maxDegrees: 5) {
            #expect(angle >= -5 && angle <= 5)
        }
    }

    /// **The refactor is behaviour-preserving, or it is a visual regression nobody can
    /// see.** The grid cell used to ask for three angles and read indices 1 and 2, with a
    /// comment for the reason. Same seed, same angles, same cards.
    @Test("the grid cell's pile is angle-for-angle what it was")
    func matchesTheCellsFormerArithmetic() {
        // `fanGeometry.degrees` is size-dependent, so a value the cap really produces.
        for degrees in [5.0, 3.7, 1.2] {
            let former = fanRotations(seed: seed, count: 3, maxDegrees: degrees)
            #expect(
                fanBackingRotations(seed: seed, cardCount: 2, maxDegrees: degrees)
                    == [former[1], former[2]])
        }
    }

    /// And `FanCard`, whose convention the cell's comment pointed at: it asked for one
    /// angle per TILE and skipped index 0, so N tiles have N − 1 tilted ones.
    @Test("the Home overview card's fan is angle-for-angle what it was")
    func matchesFanCardsFormerArithmetic() {
        for tiles in 1...6 {
            let former = fanRotations(seed: seed, count: tiles)
            let now = fanBackingRotations(seed: seed, cardCount: tiles - 1)
            #expect(now == Array(former.dropFirst()))
            for index in 1..<tiles {
                #expect(now[index - 1] == former[index])
            }
        }
    }
}
