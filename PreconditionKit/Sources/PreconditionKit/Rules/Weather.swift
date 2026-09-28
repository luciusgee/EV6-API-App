import Foundation

/// Weather at a point (HANDOVER.md §4.3). Open-Meteo needs no key.
public protocol WeatherSource: Sendable {
    func current(at: LatLon) async -> TempReading?
    func forecast(at: LatLon, time: Date) async -> TempReading?
}

/// Open-Meteo with a 15-minute cache, so rules evaluated close together share one call.
public final class WeatherRepository: WeatherSource, @unchecked Sendable {
    public static let host = "api.open-meteo.com"

    private struct Entry {
        var fetchedAt: Date
        var body: JSONValue
    }

    private let transport: HTTPTransport
    private let time: TimeSource
    private let ttl: TimeInterval
    private let baseURL: String
    private let mutex = AsyncMutex()
    /// Only touched while holding `mutex`.
    private var cache: [String: Entry] = [:]
    private let error = Locked<String?>(nil)

    public init(transport: HTTPTransport, time: TimeSource = SystemTime(), ttl: TimeInterval = 15 * 60, baseURL: String = "https://\(WeatherRepository.host)") {
        self.transport = transport
        self.time = time
        self.ttl = ttl
        self.baseURL = baseURL
    }

    /// The last failure, for the log when a reading comes back nil.
    public var lastError: String? { error.current }

    public func current(at: LatLon) async -> TempReading? {
        guard let body = await fetch(at),
              let t = body.path("current.temperature_2m")?.num,
              let ts = body.path("current.time")?.num
        else { return nil }
        return TempReading(celsius: t, source: "Open-Meteo", at: Date(timeIntervalSince1970: ts))
    }

    /// Linear interpolation between the two hourly values around `time`. Before the first point only
    /// within an hour; beyond the forecast range, nil.
    public func forecast(at: LatLon, time target: Date) async -> TempReading? {
        guard let body = await fetch(at) else { return nil }
        let times = body.path("hourly.time")?.array ?? []
        let temps = body.path("hourly.temperature_2m")?.array ?? []
        let points = zip(times, temps)
            .compactMap { ts, v -> (Double, Double)? in
                guard let ts = ts.num, let v = v.num else { return nil }
                return (ts, v)
            }
            .sorted { $0.0 < $1.0 }
        let t = target.timeIntervalSince1970.rounded(.down)
        guard let after = points.firstIndex(where: { $0.0 >= t }) else { return nil }
        let value: Double
        if after == 0 {
            guard points[0].0 - t <= 3600 else { return nil }
            value = points[0].1
        } else {
            let (t0, v0) = points[after - 1]
            let (t1, v1) = points[after]
            value = t1 == t0 ? v1 : v0 + (v1 - v0) * (t - t0) / (t1 - t0)
        }
        return TempReading(celsius: value, source: "Open-Meteo forecast", at: target)
    }

    private func fetch(_ at: LatLon) async -> JSONValue? {
        await mutex.withLock {
            let key = Self.coord(at.lat) + "," + Self.coord(at.lon)
            let now = time.now()
            if let hit = cache[key], now < hit.fetchedAt.addingTimeInterval(ttl) { return hit.body }
            let query = [
                "latitude=\(Self.coord(at.lat))",
                "longitude=\(Self.coord(at.lon))",
                "current=temperature_2m",
                "hourly=temperature_2m",
                "forecast_days=2",
                "timeformat=unixtime",
                "timezone=GMT",
            ].joined(separator: "&")
            do {
                guard let url = URL(string: "\(baseURL)/v1/forecast?\(query)") else { throw URLError(.badURL) }
                let response = try await transport.send(HTTPRequest(method: "GET", url: url))
                guard (200...299).contains(response.status), let body = JSONValue.parse(response.body), body.isObject else {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.status)"])
                }
                cache[key] = Entry(fetchedAt: now, body: body)
                error.withLock { $0 = nil }
                return body
            } catch let e {
                error.withLock { $0 = (e as? URLError)?.localizedDescription ?? String(describing: e) }
                return nil
            }
        }
    }

    /// A ~100 m grid: nearby points share a cache entry, and Open-Meteo's grid is coarser anyway.
    static func coord(_ d: Double) -> String { String(format: "%.3f", d) }
}

/// Fake-car mode's stand-in for Open-Meteo: a flat forecast at a temperature set in the Developer screen.
public final class FakeWeather: HTTPTransport, @unchecked Sendable {
    private let time: TimeSource
    private let temperature: Locked<Double>

    public init(celsius: Double = 3, time: TimeSource = SystemTime()) {
        self.time = time
        self.temperature = Locked(celsius)
    }

    public var celsius: Double {
        get { temperature.current }
        set { temperature.withLock { $0 = newValue } }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let now = time.now().timeIntervalSince1970
        let t = celsius
        let start = (now / 86400).rounded(.down) * 86400
        let hours: [JSONValue] = (0..<48).map { .number(start + Double($0) * 3600) }
        let body: JSONValue = [
            "current": ["time": .number(now.rounded(.down)), "temperature_2m": .number(t)],
            "hourly": ["time": .array(hours), "temperature_2m": .array(hours.map { _ in .number(t) })],
        ]
        return HTTPResponse(status: 200, body: body.data)
    }
}
