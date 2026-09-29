import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, CustomStringConvertible {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// False to get a 3xx back as the response instead of following it (the Kia login reads the redirect).
    public var followRedirects: Bool

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, followRedirects: Bool = true) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
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
    public var headers: [String: String]
    /// Cookies the response set, name → value.
    public var cookies: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:], cookies: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
        self.cookies = cookies
    }

    public init(status: Int, text: String, headers: [String: String] = [:], cookies: [String: String] = [:]) {
        self.init(status: status, body: Data(text.utf8), headers: headers, cookies: cookies)
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// The only way out to the network. The app uses `URLSessionTransport`; tests and fake-car mode swap in
/// something that answers locally, so the real client, budget and error mapping run unchanged.
public protocol HTTPTransport: Sendable {
    /// Throws only when no response arrived (offline, timeout). Any HTTP status is a response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let policy: RedirectPolicy

    public init() {
        let policy = RedirectPolicy()
        self.policy = policy
        self.session = Self.makeSession(delegate: policy)
    }

    /// Short timeouts: background wakes on iOS only get a few seconds (HANDOVER.md §8). No cookie store:
    /// the one flow that needs cookies (the Kia login) carries them itself.
    static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        let policy = self.policy
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: r) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] {
                    if let k = k as? String, let v = v as? String { headers[k] = v }
                }
                var cookies: [String: String] = [:]
                if let url = http?.url ?? request.url as URL? {
                    for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { cookies[c.name] = c.value }
                }
                continuation.resume(returning: HTTPResponse(status: http?.statusCode ?? 0, body: data ?? Data(), headers: headers, cookies: cookies))
            }
            if !request.followRedirects { policy.stopRedirects(for: task.taskIdentifier) }
            task.resume()
        }
    }
}

/// Stops redirects for the tasks that asked (`followRedirects: false`), so their 3xx comes back as is.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let stopped = Locked<Set<Int>>([])

    func stopRedirects(for task: Int) {
        stopped.withLock { _ = $0.insert(task) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let stop = stopped.withLock { $0.remove(task.taskIdentifier) != nil }
        completionHandler(stop ? nil : request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stopped.withLock { _ = $0.remove(task.taskIdentifier) }
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
