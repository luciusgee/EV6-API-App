import Foundation

/// The cheapest unbroken window to add the charge you need before you leave. One unbroken window means
/// one "start charging" at its start; the car's charge limit (set to the target) ends it.
public struct SmartChargePlan: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var targetPercent: Int
    /// From the wall, including charging losses.
    public var kWh: Double
    public var averagePence: Double
    public var costPence: Double
    /// What charging straight away would cost instead.
    public var nowCostPence: Double

    public var savingPence: Double { max(0, nowCostPence - costPence) }
}

public struct SmartChargeSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var targetPercent: Int
    public var readyBy: ClockTime
    /// The home charger's power.
    public var chargerKW: Double

    public init(enabled: Bool = false, targetPercent: Int = 80, readyBy: ClockTime = ClockTime(hour: 7, minute: 30), chargerKW: Double = 7.0) {
        self.enabled = enabled
        self.targetPercent = targetPercent
        self.readyBy = readyBy
        self.chargerKW = chargerKW
    }
}

public enum SmartCharging {
    public enum Decision: Equatable, Sendable {
        /// In the window, plugged in, not charging, below target.
        case startCharging
        /// Before the window and charging at a dearer price: hold it.
        case stopCharging
        case nothing
    }

    /// Energy from the wall to go from `soc` to `target`.
    public static func kWhNeeded(soc: Int, target: Int, usableKWh: Double, lossFactor: Double) -> Double {
        max(0, Double(target - soc)) / 100 * usableKWh * lossFactor
    }

    /// The next time `readyBy` comes round after `now`.
    public static func nextReadyBy(_ readyBy: ClockTime, after now: Date, calendar: Calendar = .current) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = readyBy.hour
        comps.minute = readyBy.minute
        let today = calendar.date(from: comps) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// `slots` should cover [now, readyBy) in half hours (see `Tariff.slots`). Nil when nothing is
    /// needed or there's no time.
    public static func plan(
        slots: [PriceSlot],
        now: Date,
        readyBy: Date,
        socPercent: Int,
        settings: SmartChargeSettings,
        usableKWh: Double,
        lossFactor: Double
    ) -> SmartChargePlan? {
        let kWh = kWhNeeded(soc: socPercent, target: settings.targetPercent, usableKWh: usableKWh, lossFactor: lossFactor)
        guard kWh > 0.1, settings.chargerKW > 0 else { return nil }
        let usable = slots.filter { $0.end > now && $0.start < readyBy }.sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return nil }
        let slotsNeeded = max(1, Int((kWh / settings.chargerKW / 0.5).rounded(.up)))
        let count = min(slotsNeeded, usable.count)

        func cost(_ window: ArraySlice<PriceSlot>) -> Double {
            // Every slot is full except the last, which takes what's left.
            var left = kWh
            var pence = 0.0
            for slot in window {
                let take = min(left, settings.chargerKW * slot.hours)
                pence += take * slot.pencePerKWh
                left -= take
            }
            return pence
        }

        var best = 0
        var bestCost = Double.infinity
        for i in 0...(usable.count - count) {
            let c = cost(usable[i..<(i + count)])
            if c < bestCost - 0.001 {
                best = i
                bestCost = c
            }
        }
        let window = usable[best..<(best + count)]
        return SmartChargePlan(
            start: max(window.first!.start, now),
            end: window.last!.end,
            targetPercent: settings.targetPercent,
            kWh: kWh,
            averagePence: bestCost / kWh,
            costPence: bestCost,
            nowCostPence: cost(usable[0..<count])
        )
    }

    public static func decide(plan: SmartChargePlan?, now: Date, snapshot: VehicleSnapshot) -> Decision {
        guard let plan, snapshot.pluggedIn == true, let soc = snapshot.socPercent, soc < plan.targetPercent else { return .nothing }
        let charging = snapshot.chargingState == .charging
        if now >= plan.start && now < plan.end {
            return charging ? .nothing : .startCharging
        }
        if now < plan.start && charging {
            return .stopCharging
        }
        return .nothing
    }
}
