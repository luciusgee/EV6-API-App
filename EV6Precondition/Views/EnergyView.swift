import Charts
import PreconditionKit
import SwiftUI

/// Where the energy went over the last 30 days, from the car's own driving history.
struct EnergyView: View {
    @Environment(CarModel.self) private var model
    /// Set once you've asked for the data here, so a failure shows on this screen.
    @State private var asked = false

    private var history: DrivingHistory? { model.energy }
    private var miles: Bool { model.settings.useMiles }

    var body: some View {
        List {
            if asked, model.busy != .energy, let message = model.message, message.hasPrefix("Couldn't load energy data") {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            if let history, !history.days.isEmpty {
                Section {
                    summary(history)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                } footer: {
                    Text("Last 30 days · updated \(DisplayText.age(of: history.fetchedAt, now: model.now))")
                }

                Section("Daily energy") {
                    DailyChart(days: history.days)
                        .frame(height: 220)
                        .padding(.vertical, 8)
                }

                Section("Distance") {
                    DistanceChart(days: history.days, miles: miles)
                        .frame(height: 160)
                        .padding(.vertical, 8)
                }

                Section {
                    breakdownRow("Driving", history.days.reduce(0) { $0 + $1.motorWh }, total: history.totalWh, colour: .blue)
                    breakdownRow("Climate", history.climateWh, total: history.totalWh, colour: .orange)
                    breakdownRow("Electronics", history.days.reduce(0) { $0 + $1.electronicsWh }, total: history.totalWh, colour: .purple)
                    breakdownRow("Battery care", history.days.reduce(0) { $0 + $1.batteryCareWh }, total: history.totalWh, colour: .teal)
                    LabeledContent("Recovered by regen", value: DisplayText.energy(wh: history.regenWh))
                } header: {
                    Text("Breakdown")
                } footer: {
                    if let share = history.climateShare {
                        Text(climateTip(share))
                    }
                }

                if history.lifetimeConsumedWh != nil || history.lifetimeRegenWh != nil {
                    Section("Since new") {
                        if let used = history.lifetimeConsumedWh {
                            LabeledContent("Energy used", value: DisplayText.energy(wh: used))
                        }
                        if let regen = history.lifetimeRegenWh {
                            LabeledContent("Recovered by regen", value: DisplayText.energy(wh: regen))
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("No energy data yet", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("See where your charge went over the last 30 days.")
                    } actions: {
                        Button {
                            load()
                        } label: {
                            HStack(spacing: 8) {
                                if model.busy == .energy { ProgressView().tint(.white) }
                                Text(model.busy == .energy ? "Loading…" : "Load energy data")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Energy use")
        .refreshable {
            asked = true
            await model.refreshEnergy()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.busy == .energy {
                    ProgressView()
                } else {
                    Button {
                        load()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy != nil)
                }
            }
        }
    }

    private func load() {
        asked = true
        Task { await model.refreshEnergy() }
    }

    private func summary(_ h: DrivingHistory) -> some View {
        HStack(alignment: .top) {
            stat(DisplayText.efficiency(kWhPer100km: h.kWhPer100km, miles: miles) ?? "–", "efficiency")
            Divider()
            stat(DisplayText.distance(km: h.totalDistanceKm, miles: miles), "driven")
            Divider()
            stat(DisplayText.energy(wh: h.totalWh), "used")
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func breakdownRow(_ name: String, _ wh: Double, total: Double, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text("\(DisplayText.energy(wh: wh)) · \(total > 0 ? Int((wh / total * 100).rounded()) : 0)%")
                    .monospacedDigit()
            } label: {
                Label {
                    Text(name)
                } icon: {
                    Circle().fill(colour).frame(width: 10, height: 10)
                }
            }
            ProgressView(value: total > 0 ? wh / total : 0).tint(colour)
        }
        .padding(.vertical, 2)
    }

    private func climateTip(_ share: Double) -> String {
        let pct = Int((share * 100).rounded())
        if share > 0.15 {
            return "Climate used \(pct)% of your energy. Warming the car while it's plugged in, before you set off, takes less from the battery on the go."
        }
        return "Climate used \(pct)% of your energy."
    }
}

private struct EnergySlice: Identifiable {
    let date: Date
    let category: String
    let kWh: Double
    var id: String { "\(date.timeIntervalSince1970)-\(category)" }
}

private func date(_ day: CalendarDay) -> Date {
    Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
}

private struct DailyChart: View {
    let days: [DailyEnergy]

    private var slices: [EnergySlice] {
        days.flatMap { d -> [EnergySlice] in
            let at = date(d.day)
            return [
                EnergySlice(date: at, category: "Driving", kWh: d.motorWh / 1000),
                EnergySlice(date: at, category: "Climate", kWh: d.climateWh / 1000),
                EnergySlice(date: at, category: "Electronics", kWh: d.electronicsWh / 1000),
                EnergySlice(date: at, category: "Battery care", kWh: d.batteryCareWh / 1000),
            ]
        }
    }

    var body: some View {
        Chart(slices) { slice in
            BarMark(
                x: .value("Day", slice.date, unit: .day),
                y: .value("kWh", slice.kWh)
            )
            .foregroundStyle(by: .value("Use", slice.category))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            "Driving": Color.blue, "Climate": Color.orange, "Electronics": Color.purple, "Battery care": Color.teal,
        ])
        .chartYAxisLabel("kWh")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartLegend(position: .bottom, spacing: 12)
    }
}

private struct DistanceChart: View {
    let days: [DailyEnergy]
    let miles: Bool

    var body: some View {
        Chart(days) { d in
            AreaMark(
                x: .value("Day", date(d.day), unit: .day),
                y: .value("Distance", miles ? d.distanceKm / DisplayText.kmPerMile : d.distanceKm)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Color.accentColor.opacity(0.2).gradient)
            LineMark(
                x: .value("Day", date(d.day), unit: .day),
                y: .value("Distance", miles ? d.distanceKm / DisplayText.kmPerMile : d.distanceKm)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Color.accentColor)
        }
        .chartYAxisLabel(miles ? "mi" : "km")
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
    }
}
