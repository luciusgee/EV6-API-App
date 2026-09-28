import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, CustomStringConvertible {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// No headers or body: they hold tokens.
    public var description: String { "\(method) \(url.absoluteString)" }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public init(status: Int, text: String) {
        self.init(status: status, body: Data(text.utf8))
    }
}

/// The only way out to the network. The app uses `URLSessionTransport`; tests and fake-car mode swap in
/// something that answers locally, so the real client, budget and error mapping run unchanged.
public protocol HTTPTransport: Sendable {
    /// Throws only when no response arrived (offline, timeout). Any HTTP status is a response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    /// Short timeouts: background wakes on iOS only get a few seconds (HANDOVER.md §8).
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: r) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: HTTPResponse(status: status, body: data ?? Data()))
            }.resume()
        }
    }
}

/// Sends Kia (and later Open-Meteo) traffic to in-app fakes while fake-car mode is on, and everything
/// else to the real network. The Android `FakeRouter`.
public final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private let live: HTTPTransport
    private let fakes: [String: HTTPTransport]
    private let enabled = Locked(false)

    /// - Parameter fakes: host → the fake that answers for it.
    public init(live: HTTPTransport, fakes: [String: HTTPTransport]) {
        self.live = live
        self.fakes = fakes
    }

    public var fakeMode: Bool {
        get { enabled.current }
        set { enabled.withLock { $0 = newValue } }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if fakeMode, let host = request.url.host, let fake = fakes[host] {
            return try await fake.send(request)
        }
        return try await live.send(request)
    }
}
