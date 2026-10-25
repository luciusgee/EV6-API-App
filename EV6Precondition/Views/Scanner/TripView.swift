import PreconditionKit
import SwiftUI

/// Distance, time, energy and efficiency of a drive, from live readings.
struct TripView: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs

    private var miles: Bool { prefs.useMiles }
    /// Only E-GMP cars report battery power; other cars get distance and speed only.
    private var electric: Bool { prefs.platform == .egmp }

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                if obd.trip == nil {
                    Button {
                        obd.trip = TripComputer(started: Date())
                        obd.want(electric ? ["speed", "power"] : ["speed"], for: "trip")
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
                Text(electric
                     ? "Keep this screen open with the adapter connected: the trip adds up speed and battery power several times a second. The screen stays on while it runs."
                     : "Keep this screen open with the adapter connected: the trip adds up speed and distance several times a second. The screen stays on while it runs.")
            }
            if let trip = obd.trip {
                Section {
                    stat("Distance", miles ? String(format: "%.1f mi", trip.distanceKm / DisplayText.kmPerMile) : String(format: "%.1f km", trip.distanceKm))
                    stat("Time", Duration.seconds(trip.seconds).formatted(.time(pattern: .hourMinuteSecond)))
                    stat("Average speed", trip.averageSpeedKmh.map { miles ? String(format: "%.0f mph", $0 / DisplayText.kmPerMile) : String(format: "%.0f km/h", $0) } ?? "–")
                    stat("Top speed", miles ? String(format: "%.0f mph", trip.maxSpeedKmh / DisplayText.kmPerMile) : String(format: "%.0f km/h", trip.maxSpeedKmh))
                    if electric {
                        stat("Efficiency", DisplayText.efficiency(kWhPer100km: trip.kWhPer100km, miles: miles) ?? "–")
                    }
                }
                if electric {
                    Section("Energy") {
                        stat("Used", String(format: "%.2f kWh", trip.usedKWh))
                        stat("Recovered by regen", String(format: "%.2f kWh", trip.regenKWh) + (trip.regenShare.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                        stat("Net", String(format: "%.2f kWh", trip.netKWh))
                        stat("Peak power", String(format: "%.0f kW", trip.maxPowerKW))
                        stat("Peak regen", String(format: "%.0f kW", trip.maxRegenKW))
                    }
                    Section {
                        PowerBar(kW: obd.latest["power"])
                    }
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

    /// Leaves out files the user has since deleted or renamed in the Files app.
    private var recordings: [URL] {
        obd.recordings.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        let files = recordings
        List {
            Section {
                if files.isEmpty {
                    Text("No recordings yet. In Live Data, pick your sensors and tap ⏺ to record them to a spreadsheet file.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "tablecells")
                    }
                }
                .onDelete { offsets in
                    // Capture the files first: each delete reloads obd.recordings.
                    for url in offsets.map({ files[$0] }) { obd.deleteRecording(url) }
                }
            } footer: {
                Text("CSV files: open them in Numbers or Excel, or share them. They're also in the Files app under On My iPhone › \(AppInfo.name) › Recordings.")
            }
        }
        .navigationTitle("Recordings")
        // Picks up files added or renamed in the Files app.
        .onAppear { obd.loadRecordings() }
        .refreshable { obd.loadRecordings() }
    }
}
