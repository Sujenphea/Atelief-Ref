// AtelierIngestion — SSRF guard tests (001 · C2b)
//
// The guard is the security boundary for app-side page/image resolution, so its IP
// classification + validation are unit-tested exhaustively with an INJECTED resolver
// (no real DNS): every private / loopback / link-local / ULA / multicast range, the
// IPv4-mapped-v6 case, IP literals, and the scheme / unresolvable / mixed-address
// paths. A miss here is an SSRF hole, so the matrix is deliberately broad.

import Foundation
import Testing
@testable import AtelierIngestion

@Suite("SSRF guard (001 · C2b)")
struct SSRFGuardTests {

    /// A guard whose DNS is a fixed host→IPs map (no real network).
    private func guarded(_ map: [String: [String]]) -> SSRFGuard {
        SSRFGuard { host in map[host] ?? [] }
    }

    // MARK: - IPv4 classification

    @Test("IPv4: public addresses pass, every internal range is blocked")
    func ipv4Ranges() {
        // Public.
        #expect(SSRFGuard.isPublic("8.8.8.8"))
        #expect(SSRFGuard.isPublic("1.1.1.1"))
        #expect(SSRFGuard.isPublic("93.184.216.34"))
        // Internal / special-use → not public.
        for ip in [
            "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254",
            "172.16.0.1", "172.31.255.255", "192.168.1.1", "198.18.0.1",
            "224.0.0.1", "240.0.0.1", "255.255.255.255",
        ] {
            #expect(!SSRFGuard.isPublic(ip), "\(ip) must be blocked")
        }
        // Just OUTSIDE the private 172.16/12 boundary is public.
        #expect(SSRFGuard.isPublic("172.15.0.1"))
        #expect(SSRFGuard.isPublic("172.32.0.1"))
    }

    // MARK: - IPv6 classification

    @Test("IPv6: public passes; loopback / unspecified / link-local / ULA / multicast blocked")
    func ipv6Ranges() {
        #expect(SSRFGuard.isPublic("2606:4700:4700::1111")) // public (Cloudflare)
        for ip in ["::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1"] {
            #expect(!SSRFGuard.isPublic(ip), "\(ip) must be blocked")
        }
    }

    @Test("IPv4-mapped IPv6 is classified by its embedded v4 address")
    func ipv4MappedV6() {
        #expect(!SSRFGuard.isPublic("::ffff:127.0.0.1"))    // mapped loopback → blocked
        #expect(!SSRFGuard.isPublic("::ffff:169.254.169.254"))
        #expect(SSRFGuard.isPublic("::ffff:8.8.8.8"))       // mapped public → allowed
    }

    @Test("an unparseable IP string is treated as NOT public (fail closed)")
    func unparseableFailsClosed() {
        #expect(!SSRFGuard.isPublic("not-an-ip"))
        #expect(!SSRFGuard.isPublic(""))
    }

    // MARK: - validate(_:)

    @Test("non-http(s) schemes are refused before any DNS")
    func rejectsScheme() {
        let g = SSRFGuard.permissive
        #expect(throws: SSRFError.invalidScheme) { try g.validate(URL(string: "file:///etc/passwd")!) }
        #expect(throws: SSRFError.invalidScheme) { try g.validate(URL(string: "ftp://host/x")!) }
        #expect(throws: SSRFError.invalidScheme) { try g.validate(URL(string: "gopher://host")!) }
    }

    @Test("an IP-literal host is validated directly, no DNS")
    func ipLiteralHost() {
        // resolve() would return [] (→ unresolvable) if it were consulted; a literal
        // must bypass it and be classified in place.
        let g = guarded([:])
        #expect(throws: SSRFError.blockedAddress("169.254.169.254")) {
            try g.validate(URL(string: "http://169.254.169.254/latest/meta-data/")!)
        }
        #expect(throws: SSRFError.blockedAddress("127.0.0.1")) {
            try g.validate(URL(string: "http://127.0.0.1:8080/")!)
        }
        #expect(throws: Never.self) { try g.validate(URL(string: "https://8.8.8.8/")!) }
    }

    @Test("a hostname resolving to a private IP is blocked")
    func hostnameToPrivate() {
        let g = guarded(["internal.corp": ["10.1.2.3"]])
        #expect(throws: SSRFError.blockedAddress("10.1.2.3")) {
            try g.validate(URL(string: "https://internal.corp/x")!)
        }
    }

    @Test("if ANY resolved address is private, the host is blocked (mixed A records)")
    func mixedAddressesBlocked() {
        // A rebinding-style record with one public and one private answer must fail.
        let g = guarded(["evil.example": ["93.184.216.34", "127.0.0.1"]])
        #expect(throws: SSRFError.blockedAddress("127.0.0.1")) {
            try g.validate(URL(string: "https://evil.example/")!)
        }
    }

    @Test("an unresolvable host is refused")
    func unresolvableHost() {
        let g = guarded([:])
        #expect(throws: SSRFError.unresolvable("nope.invalid")) {
            try g.validate(URL(string: "https://nope.invalid/")!)
        }
    }

    @Test("a host resolving only to public addresses passes")
    func publicHostPasses() {
        let g = guarded(["example.com": ["93.184.216.34", "2606:2800:220:1::1"]])
        #expect(throws: Never.self) { try g.validate(URL(string: "https://example.com/page")!) }
    }
}
