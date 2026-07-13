// AtelierIngestion — SSRF guard for app-side page/image resolution (001 · C2b)
//
// The app now fetches ATTACKER-INFLUENCEABLE content — a pasted page's HTML and
// the og:image URL that HTML names (001 · O3, approved 2026-07-13). That bends the
// "app never downloads" invariant, so every such fetch is walled: only an http(s)
// URL whose host resolves EXCLUSIVELY to public IP addresses may be fetched. This
// blocks the classic SSRF targets — the cloud metadata endpoint (169.254.169.254),
// loopback (127.0.0.1 / ::1), RFC1918 / ULA / link-local ranges — before any bytes
// move.
//
// Design for testability: DNS resolution is INJECTED, so the whole matrix (private
// v4/v6, loopback, link-local, ULA, IPv4-mapped v6, an unresolvable host, a redirect
// to a private host) is unit-tested WITHOUT touching real DNS. The default resolves
// via the system (`getaddrinfo`). The IP classification is pure and total.
//
// LIMITATION (pragmatic v1, a settled decision): the guard validates a host's
// CURRENTLY-resolved addresses; it does NOT pin the socket to the validated IP, so a
// DNS-rebinding attacker who flips the record between validate and connect is not
// fully closed. Accepted for a user-gesture-only resolver; recorded for a future hop.

import Foundation
import Network

/// A typed SSRF-guard failure. `Equatable` so tests assert the exact case.
public enum SSRFError: Error, Equatable {
    /// The URL scheme isn't `http`/`https` — the app fetches nothing else.
    case invalidScheme
    /// The URL has no host to resolve.
    case missingHost
    /// The host resolved to no addresses (a dead name — nothing safe to fetch).
    case unresolvable(String)
    /// A resolved address is private / loopback / link-local / ULA / multicast —
    /// carries the offending IP for diagnostics.
    case blockedAddress(String)
}

/// Validates that a URL is safe for the app to fetch: an http(s) URL whose host
/// resolves ONLY to public addresses. Injectable DNS makes the SSRF matrix testable.
public struct SSRFGuard: Sendable {
    private let resolve: @Sendable (String) -> [String]

    public init(resolve: @escaping @Sendable (String) -> [String] = SSRFGuard.systemResolve) {
        self.resolve = resolve
    }

    /// A guard that permits any http(s) host — for call sites / tests that supply
    /// their OWN network isolation (e.g. a `URLProtocol` stub), where real DNS
    /// resolution of a fake host would spuriously fail. Still enforces the scheme.
    public static let permissive = SSRFGuard { _ in ["93.184.216.34"] } // a public IP

    /// Throw an ``SSRFError`` if `url` is not safe to fetch; return normally if it is.
    /// Call this for the INITIAL url AND for every redirect hop (the resolver follows
    /// redirects manually so each `Location` is re-validated here).
    public func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SSRFError.invalidScheme
        }
        guard let host = url.host, !host.isEmpty else { throw SSRFError.missingHost }

        // A host that is itself an IP literal (`http://127.0.0.1`, `http://[::1]`) is
        // checked directly — no DNS. Otherwise resolve the name to its addresses.
        let addresses: [String]
        if Self.isIPLiteral(host) {
            addresses = [host]
        } else {
            addresses = resolve(host)
            guard !addresses.isEmpty else { throw SSRFError.unresolvable(host) }
        }
        for ip in addresses where !Self.isPublic(ip) {
            throw SSRFError.blockedAddress(ip)
        }
    }

    // MARK: - Pure IP classification (fully unit-tested)

    /// True if `host` parses as an IPv4 or IPv6 literal.
    static func isIPLiteral(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    /// Whether an IP string is a PUBLIC (routable, non-internal) address. An
    /// unparseable string is treated as NOT public (fail closed).
    static func isPublic(_ ip: String) -> Bool {
        if let v4 = IPv4Address(ip) {
            return isPublicV4(Array(v4.rawValue))
        }
        if let v6 = IPv6Address(ip) {
            let b = Array(v6.rawValue) // 16 bytes, big-endian
            // IPv4-mapped (::ffff:a.b.c.d) — classify the embedded v4.
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return isPublicV4(Array(b[12...]))
            }
            return isPublicV6(b)
        }
        return false
    }

    /// RFC-1918 + special-use IPv4 ranges the app must never fetch.
    static func isPublicV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _): return false            // 0.0.0.0/8   "this network"
        case (10, _): return false           // 10.0.0.0/8  private
        case (100, 64...127): return false   // 100.64/10   CGNAT
        case (127, _): return false          // 127/8       loopback
        case (169, 254): return false        // 169.254/16  link-local (incl. metadata)
        case (172, 16...31): return false    // 172.16/12   private
        case (192, 168): return false        // 192.168/16  private
        case (198, 18...19): return false    // 198.18/15   benchmarking
        case (224...239, _): return false    // 224/4       multicast
        case (240...255, _): return false    // 240/4 + 255.255.255.255 reserved/broadcast
        default: return true
        }
    }

    /// Loopback / unspecified / link-local / ULA / multicast IPv6 ranges.
    static func isPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return false }                       // ::   unspecified
        if b.prefix(15).allSatisfy({ $0 == 0 }), b[15] == 1 { return false } // ::1  loopback
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return false }             // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return false }                           // fc00::/7  ULA
        if b[0] == 0xff { return false }                                    // ff00::/8  multicast
        return true
    }

    // MARK: - System resolver (default)

    /// Resolve a hostname to its numeric IP strings via `getaddrinfo` (both A and
    /// AAAA). Empty on failure — the guard then rejects the host as unresolvable.
    public static let systemResolve: @Sendable (String) -> [String] = { host in
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
        defer { freeaddrinfo(result) }
        var ips: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let n = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                n.pointee.ai_addr, n.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                ips.append(String(cString: buffer))
            }
            node = n.pointee.ai_next
        }
        return ips
    }
}
