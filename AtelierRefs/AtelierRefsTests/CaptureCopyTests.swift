//
//  CaptureCopyTests.swift
//  AtelierRefsTests
//
//  ``CaptureCopy`` — the strings and display rules the Capture pane and the
//  Settings window's capture section now share. They previously duplicated all of
//  this and had already drifted apart in wording, so the point of these tests is
//  the rules themselves: one placeholder, one enabled-rule, one endpoint format.
//

import Foundation
import Testing
@testable import AtelierRefs

@Suite("CaptureCopy")
struct CaptureCopyTests {

    // MARK: - Token display

    @Test("an unminted token shows the placeholder, not an empty gap")
    func emptyTokenShowsPlaceholder() {
        #expect(CaptureCopy.tokenDisplay("") == CaptureCopy.tokenPlaceholder)
        #expect(!CaptureCopy.tokenPlaceholder.isEmpty)
    }

    @Test("a real token is shown verbatim — never trimmed, cased, or truncated")
    func realTokenShownVerbatim() {
        // Truncation is a RENDERING concern (`.truncationMode(.middle)`); the
        // string itself must stay exact so `.textSelection` copies the real token.
        let token = "AbCd-1234-EfGh-5678-IjKl-9012-MnOp-3456"
        #expect(CaptureCopy.tokenDisplay(token) == token)
    }

    @Test("a whitespace-only token is NOT treated as absent")
    func whitespaceTokenIsNotAbsent() {
        // Deliberate: `hasToken` mirrors `copyCaptureToken()`'s own `isEmpty`
        // guard. Trimming here would enable Copy for a token whose action no-ops.
        #expect(CaptureCopy.tokenDisplay("   ") == "   ")
        #expect(CaptureCopy.hasToken("   "))
    }

    // MARK: - Copy / Regenerate enablement

    @Test("Copy and Regenerate are offered only once a token exists")
    func hasTokenGatesTheActions() {
        #expect(!CaptureCopy.hasToken(""))
        #expect(CaptureCopy.hasToken("t"))
    }

    // MARK: - Endpoint

    @Test("the endpoint is the loopback host and port, both surfaces alike")
    func endpointFormat() {
        #expect(CaptureCopy.endpoint(port: 47321) == "127.0.0.1:47321")
        #expect(CaptureCopy.endpoint(port: 1) == "127.0.0.1:1")
    }

    @Test("the endpoint never leaves the loopback host")
    func endpointIsLoopback() {
        // The privacy claim in `explainer` ("never leaves your Mac") rests on this.
        #expect(CaptureCopy.host == "127.0.0.1")
        #expect(CaptureCopy.endpoint(port: 47321).hasPrefix("127.0.0.1:"))
    }

    @Test("a running endpoint reads as listening, on the same address")
    func statusWhenRunning() {
        let status = CaptureCopy.endpointStatus(port: 47321, running: true)
        #expect(status == "Listening on 127.0.0.1:47321")
        #expect(status.contains(CaptureCopy.endpoint(port: 47321)))
    }

    @Test("a stopped endpoint names the port that is in use")
    func statusWhenStopped() {
        let status = CaptureCopy.endpointStatus(port: 47321, running: false)
        #expect(status == "Endpoint unavailable (port 47321 in use)")
        // The failure mode is stated, not just the absence of success.
        #expect(status.contains("47321"))
    }

    @Test("the two endpoint states are distinguishable")
    func statusStatesDiffer() {
        #expect(CaptureCopy.endpointStatus(port: 47321, running: true)
                != CaptureCopy.endpointStatus(port: 47321, running: false))
    }

    // MARK: - Explainer

    @Test("the explainer names the browser once, consistently")
    func explainerNamesChromeOnce() {
        // The bug this shared constant fixes: the Settings copy said "browser
        // extension" while the Capture pane said "Chrome extension". Settled on
        // Chrome — the store the extension actually ships to.
        #expect(CaptureCopy.explainer.contains("Chrome extension"))
        #expect(!CaptureCopy.explainer.contains("browser extension"))
    }

    @Test("the explainer keeps the local-only promise")
    func explainerStatesLocalOnly() {
        #expect(CaptureCopy.explainer.contains("never leaves your Mac"))
    }
}
