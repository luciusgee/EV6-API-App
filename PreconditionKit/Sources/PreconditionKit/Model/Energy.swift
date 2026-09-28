import Foundation

/// One day of energy use, from Kia's driving history.
public struct DailyEnergy: Codable, Equatable, Identifiable, Sendable {
    public var day: CalendarDay
    public var totalWh: Double
    public var motorWh: Double
    public var climateWh: Double
    public var electronicsWh: Double
    public var batteryCareWh: Double
    public var regenWh: Double
    public var distanceKm: Double

    public var id: String { day.description }

    /// kWh per 100 km, when the car moved.
    public var kWhPer100km: Double? {
        distanceKm > 0 ? totalWh / distanceKm / 10 : nil
    }

    public init(day: CalendarDay, totalWh: Double, motorWh: Double, climateWh: Double, electronicsWh: Double, batteryCareWh: Double, regenWh: Double, distanceKm: Double) {
        self.day = day
        self.totalWh = totalWh
        self.motorWh = motorWh
        self.climateWh = climateWh
        self.electronicsWh = electronicsWh
        self.batteryCareWh = batteryCareWh
        self.regenWh = regenWh
        self.distanceKm = distanceKm
    }
}

/// Kia's `drvhistory`: lifetime totals and the last 30 days.
public struct DrivingHistory: Codable, Equatable, Sendable {
    public var lifetimeConsumedWh: Double?
    public var lifetimeRegenWh: Double?
    /// Oldest first.
    public var days: [DailyEnergy]
    /// Wh per km over the last 30 days, as the car works it out.
    public var average30dWhPerKm: Double?
    public var fetchedAt: Date

    public init(lifetimeConsumedWh: Double? = nil, lifetimeRegenWh: Double? = nil, days: [DailyEnergy] = [], average30dWhPerKm: Double? = nil, fetchedAt: Date) {
        self.lifetimeConsumedWh = lifetimeConsumedWh
        self.lifetimeRegenWh = lifetimeRegenWh
        self.days = days
        self.average30dWhPerKm = average30dWhPerKm
        self.fetchedAt = fetchedAt
    }

    public var totalDistanceKm: Double { days.reduce(0) { $0 + $1.distanceKm } }
    public var totalWh: Double { days.reduce(0) { $0 + $1.totalWh } }
    public var climateWh: Double { days.reduce(0) { $0 + $1.climateWh } }
    public var regenWh: Double { days.reduce(0) { $0 + $1.regenWh } }

    /// kWh/100 km over the period, from the days, else the car's own average.
    public var kWhPer100km: Double? {
        if totalDistanceKm > 0 { return totalWh / totalDistanceKm / 10 }
        return average30dWhPerKm.map { $0 / 10 }
    }

    /// Share of energy spent on climate, 0–1.
    public var climateShare: Double? {
        totalWh > 0 ? climateWh / totalWh : nil
    }

    /// Field names as in hyundai_kia_connect_api (KiaUvoApiEU._get_driving_info).
    static func parse(allTime: JSONValue, month: JSONValue, fetchedAt: Date) -> DrivingHistory {
        let lifetime = allTime.path("resMsg.drivingInfo.0")
        var days: [DailyEnergy] = []
        for d in month.path("resMsg.drivingInfoDetail")?.array ?? [] {
            guard let raw = d["drivingDate"]?.str, raw.count == 8,
                  let y = Int(raw.prefix(4)), let m = Int(raw.dropFirst(4).prefix(2)), let dd = Int(raw.suffix(2))
            else { continue }
            days.append(DailyEnergy(
                day: CalendarDay(y, m, dd),
                totalWh: d["totalPwrCsp"]?.num ?? 0,
                motorWh: d["motorPwrCsp"]?.num ?? 0,
                climateWh: d["climatePwrCsp"]?.num ?? 0,
                electronicsWh: d["eDPwrCsp"]?.num ?? 0,
                batteryCareWh: d["batteryMgPwrCsp"]?.num ?? 0,
                regenWh: d["regenPwr"]?.num ?? 0,
                distanceKm: d["calculativeOdo"]?.num ?? 0
            ))
        }
        let average = (month.path("resMsg.drivingInfo")?.array ?? []).first { item in
            item["drivingPeriod"]?.int == 0 && (item["calculativeOdo"]?.num ?? 0) > 0
        }.flatMap { item -> Double? in
            guard let total = item["totalPwrCsp"]?.num, let odo = item["calculativeOdo"]?.num, odo > 0 else { return nil }
            return total / odo
        }
        return DrivingHistory(
            lifetimeConsumedWh: lifetime?["totalPwrCsp"]?.num,
            lifetimeRegenWh: lifetime?["regenPwr"]?.num,
            days: days.sorted { $0.day < $1.day },
            average30dWhPerKm: average,
            fetchedAt: fetchedAt
        )
    }
}
