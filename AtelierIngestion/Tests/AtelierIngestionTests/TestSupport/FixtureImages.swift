// AtelierIngestion tests — the image fixtures, now one type over in
// AtelierCaptureTestSupport (457).
//
// The builders moved when the inbox, the archive and the import all wanted the same
// JPEG / HEIC / oriented / corrupt images this target had kept to itself (098 · finding
// 12). A typealias rather than an import in twenty files, for the reason
// `ContentHasher.swift` gives in the package proper: every test keeps the name it already
// uses, and there is exactly one builder.

import AtelierCaptureTestSupport

typealias FixtureImages = AtelierCaptureTestSupport.FixtureImages
