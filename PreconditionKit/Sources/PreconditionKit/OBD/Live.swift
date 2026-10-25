import Foundation

/// One round of readings.
public struct LiveSample: Sendable, Equatable {
    /// When the round ended.
    public var at: Date
    public var values: [String: Double]
    /// When each value's own reply came in, where it differs from `at`: a round over several modules
    /// takes a few hundred milliseconds, which matters for timing runs.
    public var times: [String: Date]

    public init(at: Date, values: [String: Double], times: [String: Date] = [:]) {
        self.at = at
        self.values = values
        self.times = times
    }

    /// When this sensor's value was read.
    public func time(of id: String) -> Date { times[id] ?? at }
}

/// Reads a set of sensors over and over, one request per module and data page, as fast as the adapter
/// answers. Requests that fail are retried less often, so one silent module doesn't slow the rest.
public actor LivePoller {
    private let elm: ELM327
    private let now: @Sendable () -> Date
    private var sensors: [Sensor]
    private var failures: [OBDRequest: Int] = [:]
    private var round = 0
    public private(set) var latest: [String: Double] = [:]

    public init(elm: ELM327, sensors: [Sensor], now: @escaping @Sendable () -> Date = { Date() }) {
        self.elm = elm
        self.sensors = sensors
        self.now = now
    }

    public func setSensors(_ s: [Sensor]) {
        sensors = s
    }

    /// The distinct requests behind the sensors, in first-seen order.
    public static func requests(for sensors: [Sensor]) -> [OBDRequest] {
        var seen = Set<OBDRequest>()
        return sensors.map(\.request).filter { seen.insert($0).inserted }
    }

    /// One pass over every request; throws only if the adapter itself is gone, or nothing has ever answered.
    /// Once the car has answered, a round where nothing does (car switched off, modules asleep) returns a
    /// sample with no values rather than throwing, so polling carries on and picks the car up again when it
    /// wakes. Callers tell a quiet car by how long samples have come back empty, and stop showing old values.
    public func poll() async throws -> LiveSample {
        try await elm.initialiseIfNeeded()
        round += 1
        var values: [String: Double] = [:]
        var times: [String: Date] = [:]
        var anyAnswer = false
        var lastError: Error?
        for request in Self.requests(for: sensors) {
            // Back off requests that keep failing: try them every 2nd, 4th… round, up to every 16th.
            let fails = failures[request, default: 0]
            if fails > 0 && round % min(1 << min(fails, 4), 16) != 0 { continue }
            do {
                let data = try await elm.read(request)
                let arrived = now()
                failures[request] = 0
                anyAnswer = true
                let decoded = Sensor.decode(sensors, request: request, data: data)
                values.merge(decoded) { $1 }
                for id in decoded.keys { times[id] = arrived }
            } catch let error as OBDError where error == .notConnected {
                throw error
            } catch {
                failures[request, default: 0] += 1
                lastError = error
            }
        }
        if !anyAnswer, let lastError, values.isEmpty, latest.isEmpty { throw lastError }
        latest.merge(values) { $1 }
        return LiveSample(at: now(), values: values, times: times)
    }
}

/// A recording of live samples as CSV. Rows wait in `pending` until the caller drains them to the
/// file, so a long recording isn't held in memory.
public struct DataRecording: Sendable {
    public var started: Date
    public var sensorIds: [String]
    /// The columns, fixed when the recording starts so the header and every row drained later line up
    /// even if the car's sensor list changes meanwhile (a reconnect, a different car identified).
    public private(set) var columns: [Sensor]?
    /// Samples not yet written out.
    public private(set) var pending: [LiveSample] = []
    /// Every sample added, written or not.
    public private(set) var rows = 0
    public private(set) var lastAt: Date?

    /// `sensors` fixes the columns now: the ids it has, in `sensorIds` order.
    public init(started: Date, sensorIds: [String], sensors catalog: [Sensor]? = nil) {
        self.started = started
        self.sensorIds = sensorIds
        columns = catalog.map { Self.resolve(sensorIds, in: $0) }
    }

    public mutating func add(_ s: LiveSample) {
        pending.append(s)
        rows += 1
        lastAt = s.at
    }

    public var duration: TimeInterval { (lastAt ?? started).timeIntervalSince(started) }

    private static func resolve(_ ids: [String], in catalog: [Sensor]) -> [Sensor] {
        ids.compactMap { id in catalog.first { $0.id == id } }
    }

    /// The fixed columns, or, when none were fixed at the start, those `catalog` has.
    private func columns(_ catalog: [Sensor]) -> [Sensor] {
        columns ?? Self.resolve(sensorIds, in: catalog)
    }

    /// The first line: time, then each sensor with its unit.
    public func header(sensors catalog: [Sensor] = []) -> String {
        "time_s," + columns(catalog).map { s in "\"\(s.name)\(s.unit.isEmpty ? "" : " (\(s.unit))")\"" }.joined(separator: ",") + "\n"
    }

    /// The pending rows as CSV lines (seconds since the start, then each sensor, blank when not read that
    /// round), clearing them. With columns fixed at the start, `catalog` is ignored.
    public mutating func drain(sensors catalog: [Sensor] = []) -> String {
        let sensors = columns(catalog)
        var out = ""
        for sample in pending {
            let t = String(format: "%.2f", sample.at.timeIntervalSince(started))
            let cells = sensors.map { s in sample.values[s.id].map { String(format: "%.\(max(s.decimals, 1))f", $0) } ?? "" }
            out += ([t] + cells).joined(separator: ",") + "\n"
        }
        pending = []
        return out
    }

    /// The header and every row not yet drained, as one file.
    public func csv(sensors catalog: [Sensor]) -> String {
        var copy = self
        return header(sensors: catalog) + copy.drain(sensors: catalog)
    }
}
