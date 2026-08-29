// AtelierIngestion — content hashing, now one type over in AtelierCapture.
//
// The implementation moved when 092 · S6 made the phone a writer of archives: an
// archive's `blob_hash` is this digest, and iOS cannot link this package. A typealias
// rather than a delegating wrapper, so there is exactly one `ContentHasher` type in the
// program and no chance of two that agree today and drift tomorrow — every call site in
// this package keeps the name it already uses.

import AtelierCapture

public typealias ContentHasher = AtelierCapture.ContentHasher
