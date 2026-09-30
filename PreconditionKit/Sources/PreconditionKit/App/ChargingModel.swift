import Foundation
import Observation

/// Charging costs, the home tariff and Agile prices, the smart-charging plan and car alerts.
@MainActor
@Observable
public final class ChargingModel {
    public private(set) var settings = ChargingSettings()
    public private(set) var data = ChargingData()
    /// Octopus Agile prices kept from the last fetch (a day or two).
    public private(set) var agile: [PriceSlot] = []
    public private(set) var plan: SmartChargePlan?
    public private(set) var loadingPrices = false
    public var problem: String?

    private let settingsStore: JSONFileStore<ChargingSettings>
    private let dataStore: JSONFileStore<ChargingData>
    private let pricesStore: JSONFileStore<[PriceSlot]>
    private let alertStore: JSONFileStore<AlertState>
    private let previousStore: JSONFileStore<VehicleSnapshot?>
    private let octopus: OctopusClient
    private let time: TimeSource
    private let calendar: Calendar

    public nonisolated init(directory: URL, transport: HTTPTransport, time: TimeSource = SystemTime(), calendar: Calendar = .current) {
        settingsStore = JSONFileStore(url: directory.appendingPathComponent("charging-settings.json"), default: ChargingSettings())
        dataStore = JSONFileStore(url: directory.appendingPathComponent("charging.json"), default: ChargingData())
        pricesStore = JSONFileStore(url: directory.appendingPathComponent("agile-prices.json"), default: [])
        alertStore = JSONFileStore(url: directory.appendingPathComponent("alerts.json"), default: AlertState())
        previousStore = JSONFileStore(url: directory.appendingPathComponent("alerts-previous.json"), default: nil)
        octopus = OctopusClient(transport: transport)
        self.time = time
        self.calendar = calendar
    }

    public var now: Date { time.now() }

    @ObservationIgnored private var loaded = false

    public func load() async {
        settings = await settingsStore.load()
        data = await dataStore.load()
        agile = await pricesStore.load()
        loaded = true
        var d = data
        ChargeLedger.recostOldHomeCharges(&d, settings: settings, agileSlots: agile, calendar: calendar)
        if d != data {
            data = d
            await dataStore.save(d)
        }
    }

    /// Everything that writes starts here, so a write never replaces the files with defaults.
    private func ensureLoaded() async {
        if !loaded { await load() }
    }

    public func update(_ change: (inout ChargingSettings) -> Void) async {
        await ensureLoaded()
        var copy = settings
        change(&copy)
        copy.smart.targetPercent = min(100, max(50, copy.smart.targetPercent))
        copy.smart.chargerKW = min(22, max(1, copy.smart.chargerKW))
        copy.alerts.backgroundEveryHours = min(12, max(1, copy.alerts.backgroundEveryHours))
        settings = copy
        await settingsStore.save(copy)
    }

    // MARK: - Tariff and prices

    /// Switches to Octopus Agile for the region of `postcode`, then fetches prices.
    public func useAgile(postcode: String) async {
        problem = nil
        do {
            let region = try await octopus.region(postcode: postcode)
            let fallback: Double
            if case .flat(let p) = settings.tariff { fallback = p } else { fallback = 24.5 }
            await update {
                $0.postcode = postcode.uppercased()
                $0.tariff = .agile(region: region, fallbackPence: fallback)
            }
            await refreshPrices()
        } catch {
            problem = (error as? OctopusClient.Failure)?.description ?? "Couldn't reach Octopus."
        }
    }

    /// Fetches Agile prices from an hour ago to tomorrow night. Does nothing for other tariffs.
    public func refreshPrices() async {
        await ensureLoaded()
        guard case .agile(let region, _) = settings.tariff, region != "?" else { return }
        loadingPrices = true
        defer { loadingPrices = false }
        do {
            let product = try await octopus.agileProduct()
            let from = now.addingTimeInterval(-3600)
            let to = now.addingTimeInterval(40 * 3600)
            let fresh = try await octopus.agileRates(product: product, region: region, from: from, to: to)
            // Keep a few days for costing charges that span a fetch.
            let keepFrom = now.addingTimeInterval(-3 * 86400)
            var merged = agile.filter { $0.start >= keepFrom && !fresh.map(\.start).contains($0.start) }
            merged.append(contentsOf: fresh)
            merged.sort { $0.start < $1.start }
            agile = merged
            await pricesStore.save(merged)
            problem = nil
        } catch {
            problem = (error as? OctopusClient.Failure)?.description ?? "Couldn't reach Octopus."
        }
    }

    /// True when the Agile prices don't yet reach the next ready-by time (published about 4 pm).
    public var pricesStale: Bool {
        guard case .agile = settings.tariff else { return false }
        let readyBy = SmartCharging.nextReadyBy(settings.smart.readyBy, after: now, calendar: calendar)
        return (agile.last?.end ?? .distantPast) < readyBy
    }

    /// Prices from now until the next ready-by time, for the chart and the plan.
    public var upcoming: [PriceSlot] {
        let readyBy = SmartCharging.nextReadyBy(settings.smart.readyBy, after: now, calendar: calendar)
        let until = max(readyBy, now.addingTimeInterval(12 * 3600))
        return settings.tariff.slots(from: now, to: until, agileSlots: agile, calendar: calendar)
    }

    public var currentPence: Double? {
        settings.tariff.slots(from: now, to: now.addingTimeInterval(60), agileSlots: agile, calendar: calendar).first?.pencePerKWh
    }

    // MARK: - Smart charging

    public func replan(soc: Int?) {
        guard settings.smart.enabled, let soc else {
            plan = nil
            return
        }
        let readyBy = SmartCharging.nextReadyBy(settings.smart.readyBy, after: now, calendar: calendar)
        let slots = settings.tariff.slots(from: now, to: readyBy, agileSlots: agile, calendar: calendar)
        plan = SmartCharging.plan(
            slots: slots, now: now, readyBy: readyBy, socPercent: soc, settings: settings.smart,
            usableKWh: settings.usableKWh, lossFactor: settings.homeLossFactor
        )
    }

    // MARK: - New readings

    public struct Outcome: Sendable {
        public var alerts: [CarAlert]
        public var finished: ChargeSession?
        public var decision: SmartCharging.Decision
    }

    /// Feeds a reading of the car in: records charges, works out alerts and what smart charging
    /// wants. Safe to call with the same reading more than once.
    public func process(_ snapshot: VehicleSnapshot, home: LatLon?) async -> Outcome {
        await ensureLoaded()
        var d = data
        let finished = ChargeLedger.ingest(&d, snapshot: snapshot, settings: settings, home: home, agileSlots: agile, calendar: calendar)
        if d != data {
            data = d
            await dataStore.save(d)
        }
        let previous = await previousStore.load()
        var state = await alertStore.load()
        let alerts = AlertEngine.evaluate(previous: previous, current: snapshot, state: &state, settings: settings.alerts, now: now)
        await alertStore.save(state)
        if previous?.fetchedAt != snapshot.fetchedAt {
            await previousStore.save(snapshot)
        }
        replan(soc: snapshot.socPercent)
        let decision = settings.smart.enabled ? SmartCharging.decide(plan: plan, now: now, snapshot: snapshot) : .nothing
        return Outcome(alerts: alerts, finished: finished, decision: decision)
    }

    // MARK: - Sessions

    public func addManual(start: Date, percentAdded: Int, costPounds: Double, note: String?) async {
        await ensureLoaded()
        let battery = Double(percentAdded) / 100 * settings.usableKWh
        let session = ChargeSession(
            start: start, end: start, startPercent: 0, endPercent: percentAdded,
            batteryKWh: battery, paidKWh: battery, costPence: (costPounds * 100).rounded(), atHome: false, manual: true, note: note
        )
        data.sessions.append(session)
        data.sessions.sort { $0.start > $1.start }
        await dataStore.save(data)
    }

    public func delete(_ id: String) async {
        await ensureLoaded()
        data.sessions.removeAll { $0.id == id }
        await dataStore.save(data)
    }

    public var monthly: [(month: Date, totals: ChargingTotals)] { ChargingTotals.byMonth(data.sessions, calendar: calendar) }
    public var perMile: (electric: Double, petrol: Double)? { ChargingTotals.perMile(data, settings: settings) }
}

public extension DisplayText {
    /// "£4.12", "86p".
    static func money(pence: Double) -> String {
        let p = pence.rounded()
        if abs(p) < 100 { return "\(Int(p))p" }
        return String(format: "£%.2f", p / 100)
    }
}
