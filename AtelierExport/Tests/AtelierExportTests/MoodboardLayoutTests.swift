// AtelierExport — layout + pagination exact-value tests (052 · 10A layer 1)
//
// Pure arithmetic, zero rendering: every expected coordinate below is computed
// by hand in the comments so a regression points straight at the broken step.

import CoreGraphics
import Testing
@testable import AtelierExport

@Suite("Moodboard layout")
struct MoodboardLayoutTests {

    private func image(_ x: Double, _ y: Double, _ w: Double, _ h: Double, z: Int = 0)
        -> MoodboardElement
    {
        MoodboardElement(rect: CGRect(x: x, y: y, width: w, height: h), z: z, content: .image(id: "x"))
    }

    // MARK: - Bounding box

    @Test("Bounding box is the union of element rects")
    func boundingBox() throws {
        let box = try #require(MoodboardLayout.boundingBox(of: [
            image(0, 0, 100, 100), image(200, 50, 100, 100),
        ]))
        #expect(box == CGRect(x: 0, y: 0, width: 300, height: 150))
    }

    @Test("Bounding box of nothing is nil")
    func boundingBoxEmpty() {
        #expect(MoodboardLayout.boundingBox(of: []) == nil)
    }

    // MARK: - Fit to single page

    @Test("Empty selection yields no pages")
    func fitEmpty() {
        #expect(MoodboardLayout().fitToSinglePage([], maxDimension: 1000).isEmpty)
    }

    @Test("Fit downscales the board to the max dimension")
    func fitDownscale() throws {
        // board 400×200, margin 24, maxDimension 224.
        // available = 224 - 48 = 176; scale = min(176/400, 1) = 0.44.
        // page = (400·0.44 + 48, 200·0.44 + 48) = (224, 136).
        let pages = MoodboardLayout(margin: 24)
            .fitToSinglePage([image(0, 0, 400, 200)], maxDimension: 224)
        let page = try #require(pages.first)
        #expect(pages.count == 1)
        #expect(page.size == CGSize(width: 224, height: 136))
        // element: pageX = 24; height = 88; pageY = 136 - 24 - 0 - 88 = 24.
        #expect(page.elements.first?.frame == CGRect(x: 24, y: 24, width: 176, height: 88))
        #expect(page.elements.first?.scale == 0.44)
    }

    @Test("Fit never upscales past 1:1")
    func fitNoUpscale() throws {
        // board 100×50, maxDimension 1000 would give scale 9.52 — clamped to 1.
        let pages = MoodboardLayout(margin: 24)
            .fitToSinglePage([image(0, 0, 100, 50)], maxDimension: 1000)
        let page = try #require(pages.first)
        #expect(page.size == CGSize(width: 148, height: 98))  // 100+48, 50+48
        #expect(page.elements.first?.scale == 1)
        #expect(page.elements.first?.frame == CGRect(x: 24, y: 24, width: 100, height: 50))
    }

    @Test("Fit flips y: a higher board element sits higher on the page")
    func fitYFlip() throws {
        // A at world top (y=0), B lower (y=50) and right (x=200). scale 1, margin 24.
        // page = (300+48, 150+48) = (348, 198).
        let pages = MoodboardLayout(margin: 24).fitToSinglePage(
            [image(0, 0, 100, 100, z: 0), image(200, 50, 100, 100, z: 1)],
            maxDimension: 1000)
        let page = try #require(pages.first)
        #expect(page.size == CGSize(width: 348, height: 198))
        // A: pageY = 198 - 24 - 0 - 100 = 74. B: pageY = 198 - 24 - 50 - 100 = 24.
        #expect(page.elements[0].frame == CGRect(x: 24, y: 74, width: 100, height: 100))
        #expect(page.elements[1].frame == CGRect(x: 224, y: 24, width: 100, height: 100))
        // Higher-on-board A has the LARGER page-y (y-up).
        #expect(page.elements[0].frame.minY > page.elements[1].frame.minY)
    }

    @Test("Fit clip is the full content area")
    func fitClip() throws {
        let page = try #require(
            MoodboardLayout(margin: 24)
                .fitToSinglePage([image(0, 0, 100, 50)], maxDimension: 1000).first)
        #expect(page.elements.first?.clip == CGRect(x: 24, y: 24, width: 100, height: 50))
    }

    // MARK: - Paginate

    @Test("Paginate tiles a wide board across columns")
    func paginateColumns() throws {
        // board 250×80, margin 0, page 100×100, scale 1.
        // content = 100×100; columns = ceil(250/100) = 3; rows = 1 -> 3 pages.
        let pages = MoodboardLayout(margin: 0)
            .paginate([image(0, 0, 250, 80)], pageSize: CGSize(width: 100, height: 100), scale: 1)
        #expect(pages.count == 3)
        // The single wide element straddles all three pages, shifting left by 100
        // each page. pageY = 100 - 0 - 0 - 80 = 20.
        #expect(pages[0].elements.first?.frame == CGRect(x: 0, y: 20, width: 250, height: 80))
        #expect(pages[1].elements.first?.frame == CGRect(x: -100, y: 20, width: 250, height: 80))
        #expect(pages[2].elements.first?.frame == CGRect(x: -200, y: 20, width: 250, height: 80))
        // Every page clips to its content area so the bleed can't cross a margin.
        #expect(pages[0].elements.first?.clip == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("Paginate drops elements that miss a page")
    func paginateExcludesOffPage() throws {
        // A near origin, B at x=150 — board 160 wide -> 2 columns.
        let a = image(0, 0, 10, 10, z: 0)
        let b = image(150, 0, 10, 10, z: 1)
        let pages = MoodboardLayout(margin: 0)
            .paginate([a, b], pageSize: CGSize(width: 100, height: 100), scale: 1)
        #expect(pages.count == 2)
        // Page 0 (cols 0–100) holds only A; page 1 (cols 100–200) only B.
        #expect(pages[0].elements.count == 1)
        #expect(pages[0].elements.first?.frame == CGRect(x: 0, y: 90, width: 10, height: 10))
        #expect(pages[1].elements.count == 1)
        #expect(pages[1].elements.first?.frame == CGRect(x: 50, y: 90, width: 10, height: 10))
    }

    @Test("Paginate scales geometry by the fixed scale")
    func paginateScale() throws {
        // scale 2: a 10×10 world element becomes 20×20 points.
        let pages = MoodboardLayout(margin: 10)
            .paginate([image(0, 0, 10, 10)], pageSize: CGSize(width: 200, height: 200), scale: 2)
        let el = try #require(pages.first?.elements.first)
        #expect(el.scale == 2)
        #expect(el.frame.size == CGSize(width: 20, height: 20))
    }

    @Test("Paginate rejects a non-positive scale or content area")
    func paginateDegenerate() {
        let layout = MoodboardLayout(margin: 0)
        #expect(layout.paginate([image(0, 0, 10, 10)],
                                pageSize: CGSize(width: 100, height: 100), scale: 0).isEmpty)
        // Margin swallows the whole page -> no content area.
        #expect(MoodboardLayout(margin: 60)
            .paginate([image(0, 0, 10, 10)],
                      pageSize: CGSize(width: 100, height: 100), scale: 1).isEmpty)
    }
}
