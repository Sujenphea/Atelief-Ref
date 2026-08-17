//
//  PageFixtureServer.swift
//  AtelierRefsMobileUITests
//
//  A one-page web server, inside the UI test process, so tier 2 has a page to read.
//
//  **Why a server and not a file.** The span tier 2's unit tests cannot reach is the DOM
//  read itself — Safari running `PagePreprocessor.js` inside a real page — and that needs
//  Safari to be ON a page. iOS Safari will not open a `file://` URL from the address bar,
//  and a `data:` URL is refused for top-level navigation, so the only way to put a page in
//  front of it is to serve one. The test process and Safari are on the same simulated
//  device, so `127.0.0.1` reaches from one to the other and no host machine, no network
//  and no fixture web site is involved.
//
//  It is deliberately the smallest thing that can answer an HTTP request: one connection
//  handler, one response, no routing beyond a path check, no keep-alive. A real server
//  here would be a second `AtelierServer` living in a test target.

import Foundation
import Network

/// Serves one HTML page and one JPEG on `127.0.0.1`, for as long as it is held.
final class PageFixtureServer: @unchecked Sendable {

    /// Where the page is, once ``start()`` has returned.
    private(set) var port: UInt16 = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "PageFixtureServer")
    /// The page, built from the port it will be served on.
    ///
    /// A closure rather than a string because the page has to POINT AT ITSELF — its
    /// `og:image` and its `<img>` are absolute URLs on this server — and the port is not
    /// known until the kernel assigns one. Composing the HTML first and starting the
    /// listener second is how the first version of this test ended up serving a page whose
    /// image referred to a port that had already been closed.
    private let html: (UInt16) -> String
    private let image: Data

    init(html: @escaping (UInt16) -> String, image: Data) throws {
        self.html = html
        self.image = image
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0 asks the kernel for a free one, so two runs of this suite never collide.
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Start listening and return once a port is assigned.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.port = self.listener.port?.rawValue ?? 0
            ready.signal()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success, port != 0 else {
            throw ServerError.didNotStart
        }
    }

    func stop() {
        listener.cancel()
    }

    /// The page's address, as Safari should be asked for it.
    var pageURL: String { "http://127.0.0.1:\(port)/page.html" }

    /// The image's address — what the fixture page points `og:image` at.
    static func imageURL(port: UInt16) -> String { "http://127.0.0.1:\(port)/hero.jpg" }

    enum ServerError: Error { case didNotStart }

    // MARK: - One request

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let body: Data
            let type: String
            if request.contains("/hero.jpg") {
                body = self.image
                type = "image/jpeg"
            } else {
                body = Data(self.html(self.port).utf8)
                type = "text/html; charset=utf-8"
            }
            // `Connection: close` so Safari does not hold the socket waiting for more —
            // this server answers once per connection and has nothing else to say.
            let head = """
                HTTP/1.1 200 OK\r
                Content-Type: \(type)\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r

                """
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
