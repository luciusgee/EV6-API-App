import Foundation

/// Where "now" comes from. Tests pass a clock they can move.
public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTime: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// Runs async work one piece at a time, like Kotlin's `Mutex`. An actor alone isn't enough: it lets other
/// calls in at every `await`, and a Kia call awaits several HTTP requests that must not interleave.
final class AsyncMutex: Sendable {
    private let state = State()

    func withLock<T>(_ body: () async -> T) async -> T {
        await state.acquire()
        let result = await body()
        await state.release()
        return result
    }

    private actor State {
        private var locked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !locked {
                locked = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                locked = false
            } else {
                // Hand the lock straight to the next waiter; it stays locked.
                waiters.removeFirst().resume()
            }
        }
    }
}

/// A plain lock for small synchronous critical sections.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}
