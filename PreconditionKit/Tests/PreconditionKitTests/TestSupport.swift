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
