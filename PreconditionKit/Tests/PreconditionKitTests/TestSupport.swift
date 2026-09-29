import Foundation
import XCTest
@testable import PreconditionKit

let t0 = ISO8601DateFormatter().date(from: "2026-09-23T15:00:00Z")!

func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

final class MutableTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = t0) { current = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class TestCredentials: CredentialsProvider, @unchecked Sendable {
    private let value: Locked<Credentials?>

    init(_ value: Credentials?) { self.value = Locked(value) }

    func set(_ new: Credentials?) { value.withLock { $0 = new } }

    func credentials() async -> Credentials? { value.current }
}

actor RecordingMetaSink: ApiMetaSink {
    private(set) var seen: [(ResponseMeta, ApiError?)] = []
    func onResponse(_ meta: ResponseMeta, error: ApiError?) { seen.append((meta, error)) }
}

/// Deterministic randomness (SplitMix64), like `Random(1)` in the Kotlin tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

/// Answers by path suffix, like the MockWebServer dispatcher in the Android tests: scripted responses
/// are used up first, then the defaults. Records every request.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [(suffix: String, responses: [HTTPResponse])] = []
    private var defaults: [(suffix: String, response: HTTPResponse)] = []
    private var requests: [HTTPRequest] = []
    var offline = false

    func setDefault(_ suffix: String, _ response: HTTPResponse) {
        lock.lock()
        defaults.removeAll { $0.suffix == suffix }
        defaults.append((suffix, response))
        lock.unlock()
    }

    func respond(_ suffix: String, _ responses: HTTPResponse...) {
        lock.lock()
        scripted.append((suffix, responses))
        lock.unlock()
    }

    var seen: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func clearSeen() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }

    /// Paths after the last "/api/", e.g. "v1/spa/vehicles".
    var paths: [String] {
        seen.map { r in
            let p = r.url.path
            guard let range = p.range(of: "/api/", options: .backwards) else { return p }
            return String(p[range.upperBound...])
        }
    }

    func last(_ suffix: String) -> HTTPRequest? {
        seen.last { $0.url.path.hasSuffix(suffix) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try answer(request)
    }

    private func answer(_ request: HTTPRequest) throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        if offline { throw URLError(.notConnectedToInternet) }
        requests.append(request)
        let path = request.url.path
        if let i = scripted.firstIndex(where: { path.hasSuffix($0.suffix) && !$0.responses.isEmpty }) {
            return scripted[i].responses.removeFirst()
        }
        if let d = defaults.first(where: { path.hasSuffix($0.suffix) }) {
            return d.response
        }
        return HTTPResponse(status: 404, text: "")
    }
}

/// XCTest's assertions can't take `await`; these can.
@discardableResult
func expectSuccess<T>(_ result: @autoclosure () async -> ApiResult<T>, file: StaticString = #filePath, line: UInt = #line) async -> T? {
    let r = await result()
    if let e = r.error { XCTFail("expected success, got \(e)", file: file, line: line) }
    return r.value
}

func expectError<T>(
    _ result: @autoclosure () async -> ApiResult<T>, _ expected: ApiError, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    let r = await result()
    XCTAssertEqual(r.error, expected, message, file: file, line: line)
}

func failure<T>(_ result: @autoclosure () async -> ApiResult<T>, file: StaticString = #filePath, line: UInt = #line) async throws -> ApiError {
    let r = await result()
    return try XCTUnwrap(r.error, "expected a failure", file: file, line: line)
}

func jsonResponse(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, text: body)
}

func okResponse(_ resMsg: String) -> HTTPResponse {
    jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":\#(resMsg),"msgId":"x"}"#)
}

func body(_ request: HTTPRequest?) -> JSONValue? {
    request?.body.flatMap(JSONValue.parse)
}

/// The JSON files in the repo's `fixtures/` folder, shared with the Android handover.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PreconditionKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PreconditionKit
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures")

    static func json(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONValue.parse(data), "\(name) is not JSON")
    }
}
