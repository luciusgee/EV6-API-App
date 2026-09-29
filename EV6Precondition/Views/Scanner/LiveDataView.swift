import Charts
import PreconditionKit
import SwiftUI

/// Graphs of the sensors you pick, with recording to CSV.
struct LiveDataView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car
    @AppStorage("liveSensors") private var selection = "power,speed,socBMS,battMax"
    @AppStorage("liveWindow") private var window = 120.0
    @State private var picking = false
    @State private var saved: URL?

    private var ids: [String] { selection.split(separator: ",").map(String.init).filter { EV6Sensors.sensor($0) != nil } }

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                Picker("Window", selection: $window) {
                    Text("30 s").tag(30.0)
                    Text("2 min").tag(120.0)
                    Text("5 min").tag(300.0)
                }
                .pickerStyle(.segmented)
            }
            ForEach(ids.compactMap(EV6Sensors.sensor)) { sensor in
                Section {
                    SensorChart(sensor: sensor, points: obd.history[sensor.id] ?? [], window: window, miles: car.settings.useMiles)
                        .frame(height: 150)
                        .padding(.vertical, 6)
                } header: {
                    HStack {
                        Text(sensor.name)
                        Spacer()
                        Text(sensor.display(obd.latest[sensor.id], miles: car.settings.useMiles))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
            }
            if let recording = obd.recording {
                Section {
                    Label(String(format: "Recording · %.0f s · %d rows", recording.duration, recording.samples.count), systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
            }
            if let saved {
                Section {
                    ShareLink(item: saved) { Label("Share \(saved.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Live data")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    picking = true
                } label: {
                    Label("Sensors", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if obd.recording == nil {
                    Button {
                        saved = nil
                        obd.startRecording(ids)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .disabled(obd.carState != .connected)
                } else {
                    Button {
                        saved = obd.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $picking) {
            SensorPicker(selection: $selection)
        }
        .liveSensors(ids, screen: "live")
    }
}

struct SensorChart: View {
    let sensor: Sensor
    let points: [(Date, Double)]
    let window: TimeInterval
    let miles: Bool

    private var shown: [(Date, Double)] {
        guard let last = points.last?.0 else { return [] }
        let convert = miles && sensor.unit == "km/h"
        return points.filter { last.timeIntervalSince($0.0) <= window }.map { (t, v) in (t, convert ? v / DisplayText.kmPerMile : v) }
    }

    var body: some View {
        if shown.count < 2 {
            Text("Waiting for readings…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(Array(shown.enumerated()), id: \.offset) { item in
                LineMark(x: .value("Time", item.element.0), y: .value(sensor.name, item.element.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                AreaMark(x: .value("Time", item.element.0), y: .value(sensor.name, item.element.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor.opacity(0.12).gradient)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartYScale(domain: .automatic(includesZero: sensor.range.lowerBound <= 0))
        }
    }
}

struct SensorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    static let limit = 6

    private var ids: [String] { selection.split(separator: ",").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Sensor.Group.allCases, id: \.self) { group in
                    let sensors = EV6Sensors.all.filter { $0.group == group }
                    if !sensors.isEmpty {
                        Section(group.rawValue) {
                            ForEach(sensors) { sensor in
                                Button {
                                    toggle(sensor.id)
                                } label: {
                                    HStack {
                                        Text(sensor.name).foregroundStyle(.primary)
                                        Spacer()
                                        if ids.contains(sensor.id) {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .disabled(!ids.contains(sensor.id) && ids.count >= Self.limit)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sensors (\(ids.count) of \(Self.limit))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func toggle(_ id: String) {
        var list = ids
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        selection = list.joined(separator: ",")
    }
}

/// Every sensor the car reports, grouped, updating live.
struct AllSensorsView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car
    @State private var search = ""

    private var sensors: [Sensor] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? EV6Sensors.all : EV6Sensors.all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        List {
            NotConnectedHint()
            ForEach(Sensor.Group.allCases, id: \.self) { group in
                let items = sensors.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { sensor in
                            NavigationLink {
                                SensorDetailView(sensor: sensor)
                            } label: {
                                LabeledContent(sensor.name) {
                                    Text(sensor.display(obd.latest[sensor.id], miles: car.settings.useMiles))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search sensors")
        .navigationTitle("All sensors")
        .liveSensors(EV6Sensors.all.map(\.id), screen: "sensors")
    }
}

struct SensorDetailView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car
    let sensor: Sensor

    private var points: [(Date, Double)] { obd.history[sensor.id] ?? [] }

    var body: some View {
        List {
            Section {
                Text(sensor.display(obd.latest[sensor.id], miles: car.settings.useMiles))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                SensorChart(sensor: sensor, points: points, window: 300, miles: car.settings.useMiles)
                    .frame(height: 200)
            }
            Section {
                if let lo = points.map(\.1).min(), let hi = points.map(\.1).max() {
                    LabeledContent("Lowest", value: sensor.display(lo, miles: car.settings.useMiles))
                    LabeledContent("Highest", value: sensor.display(hi, miles: car.settings.useMiles))
                }
                LabeledContent("Module", value: ECU.named(sensor.request.header).name)
                LabeledContent("Request", value: String(format: "%03X: %@", sensor.request.header, sensor.request.command))
            }
        }
        .navigationTitle(sensor.name)
        .navigationBarTitleDisplayMode(.inline)
        .liveSensors([sensor.id], screen: "detail-\(sensor.id)")
    }
}
