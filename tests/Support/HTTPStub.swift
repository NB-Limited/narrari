import Foundation
import NarrariKit
import Synchronization

// Answers requests to one made-up host inside the URL loading system, so no socket or server is involved.
final class HTTPStub: Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
        }

        static func redirect(to url: URL) -> Reply {
            Reply(status: 302, headers: ["Location": url.absoluteString])
        }
    }

    struct Request: Sendable {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    // nil leaves the request unanswered, like a service that never replies.
    typealias Handler = @Sendable (Request) -> Reply?

    let host: String
    let session: URLSession
    fileprivate let handler: Handler
    private let recorded = Mutex<[Request]>([])

    init(_ handler: @escaping Handler) {
        host = "\(UUID().uuidString.lowercased()).stub.invalid"
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.register(self)
    }

    deinit {
        StubProtocol.unregister(host)
    }

    var baseURL: URL { URL(string: "https://\(host)/v1")! }
    var address: ServiceAddress { try! ServiceAddress(baseURL.absoluteString) }
    var requests: [Request] { recorded.withLock { $0 } }

    fileprivate func record(_ request: Request) {
        recorded.withLock { $0.append(request) }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let stubs = Mutex<[String: HTTPStub]>([:])

    static func register(_ stub: HTTPStub) {
        stubs.withLock { $0[stub.host] = stub }
    }

    static func unregister(_ host: String) {
        _ = stubs.withLock { $0.removeValue(forKey: host) }
    }

    private static func stub(for request: URLRequest) -> HTTPStub? {
        guard let host = request.url?.host else { return nil }
        return stubs.withLock { $0[host] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let seen = HTTPStub.Request(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        stub.record(seen)
        guard let reply = stub.handler(seen) else { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let location = reply.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
