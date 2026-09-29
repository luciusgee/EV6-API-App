import Foundation

/// One round of readings.
public struct LiveSample: Sendable, Equatable {
    public var at: Date
    public var values: [String: Double]

    public init(at: Date, values: [String: Double]) {
        self.at = at
        self.values = values
    }
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

    /// One pass over every request; throws only if the adapter itself is gone.
    public func poll() async throws -> LiveSample {
        try await elm.initialiseIfNeeded()
        round += 1
        var values: [String: Double] = [:]
        var anyAnswer = false
        var lastError: Error?
        for request in Self.requests(for: sensors) {
            // Back off requests that keep failing: try them every 2nd, 4th… round, up to every 16th.
            let fails = failures[request, default: 0]
            if fails > 0 && round % min(1 << min(fails, 4), 16) != 0 { continue }
            do {
                let data = try await elm.read(request)
                failures[request] = 0
                anyAnswer = true
                values.merge(EV6Sensors.decode(sensors, request: request, data: data)) { $1 }
            } catch let error as OBDError where error == .notConnected {
                throw error
            } catch {
                failures[request, default: 0] += 1
                lastError = error
            }
        }
        if !anyAnswer, let lastError, values.isEmpty, latest.isEmpty { throw lastError }
        latest.merge(values) { $1 }
        return LiveSample(at: now(), values: values)
    }
}

/// Keeps samples for charts and writes them out as CSV.
public struct DataRecording: Sendable {
    public var started: Date
    public var samples: [LiveSample] = []
    public var sensorIds: [String]

    public init(started: Date, sensorIds: [String]) {
        self.started = started
        self.sensorIds = sensorIds
    }

    public mutating func add(_ s: LiveSample) {
        samples.append(s)
    }

    public var duration: TimeInterval { (samples.last?.at ?? started).timeIntervalSince(started) }

    /// One row per sample: seconds since the start, then each sensor (blank when not read that round).
    public func csv() -> String {
        let sensors = sensorIds.compactMap(EV6Sensors.sensor)
        var lines = ["time_s," + sensors.map { s in "\"\(s.name)\(s.unit.isEmpty ? "" : " (\(s.unit))")\"" }.joined(separator: ",")]
        for sample in samples {
            let t = String(format: "%.2f", sample.at.timeIntervalSince(started))
            let cells = sensors.map { s in sample.values[s.id].map { String(format: "%.\(max(s.decimals, 1))f", $0) } ?? "" }
            lines.append(([t] + cells).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
