import Foundation
import Network
import WebKit

// Google over HTTP/2.
//
// Apple's HTTP/3 stalls big uploads to Google: the first 4 MB go out and then
// nothing more, until the request times out — Drive says "Upload failure",
// Play Console's document check spins. Same bytes over HTTP/2 go through in
// seconds, and Chrome's own HTTP/3 (Brave's) never had the bug. WebKit has no
// switch for HTTP/3 of its own, and the one CFNetwork reads works only for
// the whole Mac (`defaults write -g CFNetworkHTTP3Override`), Safari and Mail
// included — not ours to flip.
//
// What WebKit does have is a proxy per store, for some domains only. Through
// a proxy a connection is TCP and so HTTP/2. This is that proxy: a tunnel on
// loopback, for Google's sites, that only joins the two ends — it sees
// nothing but encrypted bytes and the name of the site. Video (googlevideo
// .com) and Google's images and scripts (gstatic.com, ytimg.com) aren't
// uploads and keep HTTP/3.
enum Relay {
    /// Where Google takes uploads: Drive, Gmail, Photos and Play Console
    /// under google.com, the APIs under googleapis.com, YouTube's own.
    static let domains = ["google.com", "googleapis.com", "youtube.com"]

    private static let tunnel = Tunnel()

    /// The store's Google traffic through the tunnel. Not when the Mac
    /// already has a proxy of its own — WebKit would go round it, and through
    /// any proxy it's TCP anyway — nor if the tunnel couldn't open; if it
    /// dies later, the store fails over to going direct.
    @MainActor static func fit(_ store: WKWebsiteDataStore) {
        guard store.proxyConfigurations.isEmpty, !systemProxy, let port = tunnel.port else { return }
        var through = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
        through.matchDomains = domains
        through.allowFailover = true
        store.proxyConfigurations = [through]
    }

    private static var systemProxy: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        return ["HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains { (settings[$0] as? Int) == 1 }
    }

    static func allowed(_ host: String) -> Bool {
        let host = host.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// HTTP CONNECT on 127.0.0.1, to the domains above on 443 only, so it is no
/// open door for anything else on the Mac. Idle, it is a listening socket.
private final class Tunnel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "relay")
    private var listener: NWListener?
    private(set) var port: NWEndpoint.Port?

    init() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [queue] in Tunnel.serve($0, on: queue) }
        // The port is known once the socket is open, a moment after launch,
        // before any page asks for it; waiting a little for it here is
        // cheaper than a store fitted without.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1)
        listener.stateUpdateHandler = nil
        if let port = listener.port, port.rawValue != 0 { self.port = port }
    }

    private static func serve(_ inner: NWConnection, on queue: DispatchQueue) {
        inner.start(queue: queue)
        head(inner, Data()) { request, rest in
            guard let (host, port) = target(request), Relay.allowed(host), port == 443 else {
                inner.send(content: Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true,
                           completion: .contentProcessed { _ in inner.cancel() })
                return
            }
            let outer = NWConnection(host: .init(host), port: .init(integerLiteral: port), using: .tcp)
            outer.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    outer.stateUpdateHandler = { if case .failed = $0 { inner.cancel(); outer.cancel() } }
                    inner.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    let both = Pair(inner, outer)
                    if !rest.isEmpty { outer.send(content: rest, completion: .contentProcessed { _ in }) }
                    pipe(inner, outer, both); pipe(outer, inner, both)
                case .failed, .waiting:
                    inner.send(content: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true,
                               completion: .contentProcessed { _ in inner.cancel() })
                    outer.cancel()
                default: break
                }
            }
            outer.start(queue: queue)
        }
    }

    /// The request up to its blank line, and whatever came after it.
    private static func head(_ c: NWConnection, _ got: Data, then: @escaping (Data, Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            let got = got + (data ?? Data())
            if let end = got.range(of: Data("\r\n\r\n".utf8)) {
                then(got[..<end.lowerBound], got[end.upperBound...])
            } else if done || error != nil || got.count > 8192 {
                c.cancel()
            } else {
                head(c, got, then: then)
            }
        }
    }

    /// "CONNECT host:443 HTTP/1.1" → host, port.
    private static func target(_ request: Data) -> (String, UInt16)? {
        let line = String(decoding: request.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
        guard line.count >= 2, line[0] == "CONNECT", let colon = line[1].lastIndex(of: ":"),
              let port = UInt16(line[1][line[1].index(after: colon)...]) else { return nil }
        return (String(line[1][..<colon]), port)
    }

    /// One way of the two; the next read waits for the last write, so a
    /// slow end holds back the fast one rather than piling up in memory.
    private static func pipe(_ from: NWConnection, _ to: NWConnection, _ both: Pair) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
            if error != nil { both.close(); return }
            if done {
                to.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in both.ended() })
                return
            }
            to.send(content: data, completion: .contentProcessed { sent in
                if sent != nil { both.close() } else { pipe(from, to, both) }
            })
        }
    }

    /// Both ends, closed once both ways have finished or either fails.
    private final class Pair: @unchecked Sendable {
        let a: NWConnection, b: NWConnection
        var finished = 0
        init(_ a: NWConnection, _ b: NWConnection) { self.a = a; self.b = b }
        // On the relay's queue only.
        func ended() { finished += 1; if finished == 2 { close() } }
        func close() { a.cancel(); b.cancel() }
    }
}
