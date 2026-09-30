import Foundation

/// A half-hour (or any) window with a price, e.g. one Octopus Agile slot.
public struct PriceSlot: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// Pence per kWh including VAT.
    public var pencePerKWh: Double

    public init(start: Date, end: Date, pencePerKWh: Double) {
        self.start = start
        self.end = end
        self.pencePerKWh = pencePerKWh
    }

    public var hours: Double { end.timeIntervalSince(start) / 3600 }
}

/// A time of day, minutes after midnight in the owner's time zone.
public struct ClockTime: Codable, Hashable, Sendable, Comparable {
    public var minutes: Int

    public init(hour: Int, minute: Int = 0) {
        minutes = ((hour * 60 + minute) % 1440 + 1440) % 1440
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

/// How the owner pays for electricity at home.
public enum Tariff: Codable, Equatable, Sendable {
    /// One price all day.
    case flat(pencePerKWh: Double)
    /// A cheap window each night, e.g. Octopus Go (00:30–05:30) or Intelligent Octopus Go (23:30–05:30).
    case offPeak(peakPence: Double, offPeakPence: Double, from: ClockTime, to: ClockTime)
    /// Octopus Agile: a price every half hour, published around 4 pm for the next day. `region` is the
    /// DNO letter (A–P); `fallbackPence` prices times with no published slot.
    case agile(region: String, fallbackPence: Double)

    public static let `default` = Tariff.flat(pencePerKWh: 24.5)

    public var name: String {
        switch self {
        case .flat: return "Standard"
        case .offPeak: return "Off-peak"
        case .agile: return "Octopus Agile"
        }
    }

    /// Prices for [from, to): Agile uses `agileSlots`, the others are built from their rules.
    public func slots(from: Date, to: Date, agileSlots: [PriceSlot] = [], calendar: Calendar = .current) -> [PriceSlot] {
        switch self {
        case .flat(let p):
            return halfHours(from: from, to: to, calendar: calendar).map { PriceSlot(start: $0, end: $0.addingTimeInterval(1800), pencePerKWh: p) }
        case .offPeak(let peak, let off, let start, let end):
            return halfHours(from: from, to: to, calendar: calendar).map { t in
                let minutes = calendar.component(.hour, from: t) * 60 + calendar.component(.minute, from: t)
                let cheap = start.minutes <= end.minutes
                    ? (minutes >= start.minutes && minutes < end.minutes)
                    : (minutes >= start.minutes || minutes < end.minutes)
                return PriceSlot(start: t, end: t.addingTimeInterval(1800), pencePerKWh: cheap ? off : peak)
            }
        case .agile(_, let fallback):
            return halfHours(from: from, to: to, calendar: calendar).map { t in
                let price = agileSlots.first { $0.start <= t && t < $0.end }?.pencePerKWh ?? fallback
                return PriceSlot(start: t, end: t.addingTimeInterval(1800), pencePerKWh: price)
            }
        }
    }

    /// What `kWh` cost if it was drawn at `powerKW` somewhere in [from, to). Readings are far apart
    /// (the car's seen charging at 23:00 and finished at 07:15, say), so the charge is put in the
    /// cheapest half hours of that stretch, which is what the car's charging window does. Anything
    /// that doesn't fit is priced at the dearest half hour.
    public func chargeCost(kWh: Double, powerKW: Double, from: Date, to: Date, agileSlots: [PriceSlot] = [], calendar: Calendar = .current) -> Double {
        guard kWh > 0 else { return 0 }
        let slots = slots(from: from, to: max(to, from.addingTimeInterval(60)), agileSlots: agileSlots, calendar: calendar)
            .map(\.pencePerKWh).sorted()
        guard let dearest = slots.last else { return 0 }
        let perSlot = max(0.1, powerKW) / 2
        var left = kWh
        var pence = 0.0
        for price in slots where left > 0 {
            let take = min(perSlot, left)
            pence += take * price
            left -= take
        }
        return pence + left * dearest
    }

    /// Average price over [from, to), weighted by time.
    public func averagePence(from: Date, to: Date, agileSlots: [PriceSlot] = [], calendar: Calendar = .current) -> Double {
        let slots = slots(from: from, to: max(to, from.addingTimeInterval(60)), agileSlots: agileSlots, calendar: calendar)
        guard !slots.isEmpty else { return 0 }
        return slots.map(\.pencePerKWh).reduce(0, +) / Double(slots.count)
    }

    /// Half-hour boundaries covering [from, to), starting at the boundary at or before `from`.
    private func halfHours(from: Date, to: Date, calendar: Calendar) -> [Date] {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: from)
        comps.minute = (comps.minute ?? 0) < 30 ? 0 : 30
        guard var t = calendar.date(from: comps) else { return [] }
        var out: [Date] = []
        while t < to, out.count < 24 * 2 * 8 {
            out.append(t)
            t = t.addingTimeInterval(1800)
        }
        return out
    }
}
