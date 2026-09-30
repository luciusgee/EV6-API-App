import PreconditionKit
import SwiftUI

/// 0–60, 0–100, 50–70 and quarter-mile times from the car's own speed readings.
struct PerformanceView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car
    @State private var test = Test.zeroToSixty
    @AppStorage("performanceRuns") private var runsJSON = "[]"

    enum Test: String, CaseIterable, Identifiable {
        case zeroToSixty = "0–60 mph"
        case zeroToHundred = "0–100 km/h"
        case fiftyToSeventy = "50–70 mph"
        case quarterMile = "¼ mile"
        var id: String { rawValue }

        var kind: AccelerationTimer.Kind {
            switch self {
            case .zeroToSixty: return .zeroTo60mph
            case .zeroToHundred: return .zeroTo100
            case .fiftyToSeventy: return .fiftyTo70mph
            case .quarterMile: return .quarterMile
            }
        }
    }

    struct Run: Codable, Identifiable, Hashable {
        var id = UUID()
        var test: String
        var at: Date
        var seconds: Double
        var endKmh: Double
        var peakKW: Double?
    }

    private var runs: [Run] {
        (try? JSONDecoder().decode([Run].self, from: Data(runsJSON.utf8))) ?? []
    }

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                Picker("Test", selection: $test) {
                    ForEach(Test.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(obd.timer != nil)
                timerCard
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                if obd.timer == nil {
                    Button {
                        obd.timer = AccelerationTimer(kind: test.kind)
                    } label: {
                        Label("Arm Timer", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(obd.carState != .connected)
                } else {
                    Button("Cancel", role: .cancel) { obd.timer = nil }
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Closed roads and tracks only. Timing starts as soon as the car moves.")
            }

            if !runs.isEmpty {
                Section("Best times") {
                    ForEach(Test.allCases) { t in
                        if let best = runs.filter({ $0.test == t.rawValue }).min(by: { $0.seconds < $1.seconds }) {
                            LabeledContent(t.rawValue) {
                                Text(String(format: "%.2f s", best.seconds)).monospacedDigit().fontWeight(.semibold)
                            }
                        }
                    }
                }
                Section("All runs") {
                    ForEach(runs.reversed()) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(run.test).fontWeight(.medium)
                                Spacer()
                                Text(String(format: "%.2f s", run.seconds)).monospacedDigit()
                            }
                            Text(details(run)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        var list = runs
                        let reversed = Array(list.indices.reversed())
                        for o in offsets { list.remove(at: reversed[o]) }
                        save(list)
                    }
                }
            }
        }
        .navigationTitle("Performance")
        .liveSensors(["speed", "power"], screen: "performance")
        .onChange(of: finished) { _, result in
            guard let result else { return }
            save(runs + [Run(test: test.rawValue, at: Date(), seconds: result.seconds, endKmh: result.endSpeedKmh, peakKW: result.peakPowerKW)])
        }
        .onDisappear { obd.timer = nil }
    }

    private var finished: AccelerationTimer.Result? {
        if case .finished(let r)? = obd.timer?.state { return r }
        return nil
    }

    private var speedText: String {
        guard let v = obd.latest["speed"] else { return "–" }
        return car.settings.useMiles ? String(format: "%.0f mph", v / DisplayText.kmPerMile) : String(format: "%.0f km/h", v)
    }

    @ViewBuilder
    private var timerCard: some View {
        VStack(spacing: 8) {
            switch obd.timer?.state {
            case nil:
                big("0.00")
                Text("Arm the timer, then go when ready").foregroundStyle(.secondary)
            case .waiting?:
                big("0.00")
                Text(test == .fiftyToSeventy ? "Slow to below 45 mph" : "Come to a stop").foregroundStyle(.orange)
            case .armed?:
                big("0.00")
                Text("Ready: go!").foregroundStyle(.green).fontWeight(.semibold)
            case .running(let since)?:
                TimelineView(.animation) { context in
                    big(String(format: "%.2f", context.date.timeIntervalSince(since)))
                }
                Text("Timing…").foregroundStyle(.red)
            case .finished(let r)?:
                big(String(format: "%.2f", r.seconds))
                Text(detailsText(r)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Again") { obd.timer = AccelerationTimer(kind: test.kind) }
            }
            Text(speedText).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func big(_ text: String) -> some View {
        Text(text + " s")
            .font(.system(size: 60, weight: .bold, design: .rounded))
            .monospacedDigit()
    }

    private func detailsText(_ r: AccelerationTimer.Result) -> String {
        let distance = car.settings.useMiles ? String(format: "%.0f ft", r.distanceMetres * 3.281) : String(format: "%.0f m", r.distanceMetres)
        var parts = [distance]
        if test == .quarterMile {
            parts.append(car.settings.useMiles ? String(format: "%.0f mph trap", r.endSpeedKmh / DisplayText.kmPerMile) : String(format: "%.0f km/h trap", r.endSpeedKmh))
        }
        if let kw = r.peakPowerKW { parts.append(String(format: "peak %.0f kW (%.0f bhp)", kw, kw * 1.341)) }
        return parts.joined(separator: " · ")
    }

    private func details(_ run: Run) -> String {
        var parts = [run.at.formatted(date: .abbreviated, time: .shortened)]
        if let kw = run.peakKW { parts.append(String(format: "peak %.0f kW", kw)) }
        return parts.joined(separator: " · ")
    }

    private func save(_ list: [Run]) {
        if let data = try? JSONEncoder().encode(Array(list.suffix(50))), let text = String(data: data, encoding: .utf8) {
            runsJSON = text
        }
    }
}

/// Distance, time, energy and efficiency of a drive, from live readings.
struct TripView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car

    private var miles: Bool { car.settings.useMiles }

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                if obd.trip == nil {
                    Button {
                        obd.trip = TripComputer(started: Date())
                        obd.want(["speed", "power"], for: "trip")
                    } label: {
                        Label("Start Trip", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.onAccent)
                    .disabled(obd.carState != .connected)
                } else {
                    Button(role: .destructive) {
                        obd.release("trip")
                        obd.trip = nil
                    } label: {
                        Label("End Trip", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                Text("Keep this screen open with the adapter connected: the trip adds up speed and battery power several times a second. The screen stays on while it runs.")
            }
            if let trip = obd.trip {
                Section {
                    stat("Distance", miles ? String(format: "%.1f mi", trip.distanceKm / DisplayText.kmPerMile) : String(format: "%.1f km", trip.distanceKm))
                    stat("Time", Duration.seconds(trip.seconds).formatted(.time(pattern: .hourMinuteSecond)))
                    stat("Average speed", trip.averageSpeedKmh.map { miles ? String(format: "%.0f mph", $0 / DisplayText.kmPerMile) : String(format: "%.0f km/h", $0) } ?? "–")
                    stat("Efficiency", DisplayText.efficiency(kWhPer100km: trip.kWhPer100km, miles: miles) ?? "–")
                }
                Section("Energy") {
                    stat("Used", String(format: "%.2f kWh", trip.usedKWh))
                    stat("Recovered by regen", String(format: "%.2f kWh", trip.regenKWh) + (trip.regenShare.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                    stat("Net", String(format: "%.2f kWh", trip.netKWh))
                    stat("Peak power", String(format: "%.0f kW", trip.maxPowerKW))
                    stat("Peak regen", String(format: "%.0f kW", trip.maxRegenKW))
                    stat("Top speed", miles ? String(format: "%.0f mph", trip.maxSpeedKmh / DisplayText.kmPerMile) : String(format: "%.0f km/h", trip.maxSpeedKmh))
                }
                Section {
                    PowerBar(kW: obd.latest["power"])
                }
            }
        }
        .navigationTitle("Trip computer")
    }

    private func stat(_ name: String, _ value: String) -> some View {
        LabeledContent(name) { Text(value).monospacedDigit() }
    }
}

struct RecordingsView: View {
    @Environment(OBDService.self) private var obd

    var body: some View {
        List {
            Section {
                if obd.recordings.isEmpty {
                    Text("No recordings yet. In Live Data, pick your sensors and tap ⏺ to record them to a spreadsheet file.")
                        .foregroundStyle(.secondary)
                }
                ForEach(obd.recordings, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "tablecells")
                    }
                }
                .onDelete { offsets in
                    for o in offsets { obd.deleteRecording(obd.recordings[o]) }
                }
            } footer: {
                Text("CSV files: open them in Numbers or Excel, or share them. They're also in the Files app under On My iPhone › EV6.")
            }
        }
        .navigationTitle("Recordings")
    }
}
