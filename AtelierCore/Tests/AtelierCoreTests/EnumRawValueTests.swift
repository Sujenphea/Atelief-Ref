import Testing
@testable import AtelierCore

// Guards the on-disk encoding (decision C5): these rawValues become the stored
// strings, so an accidental edit here is a silent data-format break. Asserting
// the EXACT string — not just round-trip — is what catches a renamed case.
@Suite("Enum rawValue stability")
struct EnumRawValueTests {
    @Test("AssetKind rawValues are stable", arguments: [
        (AssetKind.image, "image"),
        (AssetKind.video, "video"),
    ])
    func assetKind(kind: AssetKind, raw: String) {
        #expect(kind.rawValue == raw)
        #expect(AssetKind(rawValue: raw) == kind)
    }

    @Test("Platform rawValues are stable (incl. snake_case)", arguments: [
        (Platform.twitter, "twitter"),
        (Platform.pinterest, "pinterest"),
        (Platform.instagram, "instagram"),
        (Platform.cosmos, "cosmos"),
        (Platform.web, "web"),
        (Platform.localPaste, "local_paste"),
        (Platform.localDrag, "local_drag"),
    ])
    func platform(platform: Platform, raw: String) {
        #expect(platform.rawValue == raw)
        #expect(Platform(rawValue: raw) == platform)
    }

    @Test("DownloadState rawValues are stable", arguments: [
        (DownloadState.pending, "pending"),
        (DownloadState.downloaded, "downloaded"),
        (DownloadState.failed, "failed"),
    ])
    func downloadState(state: DownloadState, raw: String) {
        #expect(state.rawValue == raw)
        #expect(DownloadState(rawValue: raw) == state)
    }

    @Test("TagSource rawValues are stable", arguments: [
        (TagSource.user, "user"),
        (TagSource.agent, "agent"),
    ])
    func tagSource(source: TagSource, raw: String) {
        #expect(source.rawValue == raw)
        #expect(TagSource(rawValue: raw) == source)
    }

    // CaseIterable counts pin the full set — a removed or sneaked-in case fails.
    @Test("enum case counts are as specified")
    func caseCounts() {
        #expect(AssetKind.allCases.count == 2)
        #expect(Platform.allCases.count == 7)
        #expect(DownloadState.allCases.count == 3)
        #expect(TagSource.allCases.count == 2)
    }

    // Every case round-trips through its own rawValue.
    @Test("all enums round-trip through rawValue")
    func allRoundTrip() {
        for c in AssetKind.allCases { #expect(AssetKind(rawValue: c.rawValue) == c) }
        for c in Platform.allCases { #expect(Platform(rawValue: c.rawValue) == c) }
        for c in DownloadState.allCases { #expect(DownloadState(rawValue: c.rawValue) == c) }
        for c in TagSource.allCases { #expect(TagSource(rawValue: c.rawValue) == c) }
    }
}
