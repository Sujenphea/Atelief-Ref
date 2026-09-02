// AtelierIngestion — the SSRF guard, now one type over in AtelierCapture (457).
//
// The implementation moved when 098 · finding 2 found the share extension's tier-2 media
// fetch running with no wall at all: the extension makes the same attacker-influenceable
// fetch the Mac's `PageResolver` and `RemoteImageFetcher` make, links AtelierCapture, and
// cannot link this package. A typealias rather than a delegating wrapper, for the reason
// `ContentHasher.swift` gives — so there is exactly one guard in the program and no chance
// of two that agree today and drift tomorrow. Every call site in this package keeps the
// name it already uses, and nothing about the Mac's behaviour changed in the move.

import AtelierCapture

public typealias SSRFGuard = AtelierCapture.SSRFGuard
public typealias SSRFError = AtelierCapture.SSRFError
