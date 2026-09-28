import Charts
import PreconditionKit
import SwiftUI

/// Reads the battery straight from the car through an OBD adapter, and keeps the last report.
@MainActor
@Observable
final class OBDModel {
    let link = OBDLink()
    private(set) var report: BatteryReport?
    private(set) var problems: [String] = []
    private(set) var progress: BatteryScanner.Progress?
    private(set) var error: String?
    private let store: JSONFileStore<BatteryReport?>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-report.json"), default: nil)
    }

    var scanning: Bool { progress != nil }

    private func setProgress(_ p: BatteryScanner.Progress) {
        progress = p
    }

    func load() async {
        report = await store.load()
    }

    /// `simulated` uses the fake car's adapter, for trying the screen without a car.
    func scan(simulated: Bool) async {
        guard !scanning else { return }
        error = nil
        problems = []
        progress = BatteryScanner.Progress(step: 0, of: 10, label: "Starting")
        let transport: OBDTransport = simulated ? FakeOBDAdapter() : OBDLinkTransport(link: link)
        let scanner = BatteryScanner(elm: ELM327(transport: transport))
        do {
            let (result, issues) = try await scanner.scan { p in await self.setProgress(p) }
            report = result
            problems = issues
            await store.save(result)
        } catch {
            self.error = (error as? OBDError)?.description ?? error.localizedDescription
        }
        progress = nil
    }
}

struct BatteryHealthView: View {
    @Environment(CarModel.self) private var car
    @State private var obd = OBDModel()
    @State private var showingAdapters = false

    private var simulated: Bool { car.settings.fakeMode }

    var body: some View {
        List {
            if let soh = car.snapshot?.details?.batteryHealthPercent, obd.report?.sohPercent == nil {
                Section {
                    LabeledContent("State of health (Kia Connect)", value: String(format: "%.1f%%", soh))
                }
            }

            Section {
                connectionRow
                Button {
                    Task { await obd.scan(simulated: simulated) }
                } label: {
                    HStack {
                        Label("Read Battery", systemImage: "waveform.path.ecg")
                        Spacer()
                        if obd.scanning { ProgressView() }
                    }
                }
                .disabled(obd.scanning || !(simulated || obd.link.isReady))
                if let progress = obd.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.step), total: Double(progress.of))
                        Text(progress.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = obd.error {
                    Label(error.capitalizingFirst, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            } header: {
                Text("OBD adapter")
            } footer: {
                Text(simulated
                    ? "Fake car on: a simulated adapter answers."
                    : "Plug a Bluetooth LE or Wi-Fi ELM327 adapter into the port under the dashboard, switch the car on, then read. Reading takes about 10 seconds and only listens: nothing is written to the car.")
            }

            if let report = obd.report {
                ReportSections(report: report, problems: obd.problems, miles: car.settings.useMiles)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Battery Health")
        .task { await obd.load() }
        .sheet(isPresented: $showingAdapters) {
            AdapterPicker(link: obd.link)
        }
        .onDisappear { obd.link.stopScan() }
    }

    @ViewBuilder
    private var connectionRow: some View {
        if simulated {
            LabeledContent("Adapter", value: "Simulated")
        } else {
            Button {
                showingAdapters = true
            } label: {
                LabeledContent {
                    Text(stateText).foregroundStyle(obd.link.isReady ? .green : .secondary)
                } label: {
                    Label("Adapter", systemImage: "cable.connector")
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private var stateText: String {
        switch obd.link.state {
        case .idle: return "Not connected"
        case .bluetoothOff: return "Bluetooth off"
        case .bluetoothDenied: return "Bluetooth not allowed"
        case .scanning: return "Searching…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .ready(let name): return name
        case .failed: return "Failed"
        }
    }
}

// MARK: - Adapter picker

private struct AdapterPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var link: OBDLink

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(link.visibleAdapters) { adapter in
                        Button {
                            link.connect(adapter)
                        } label: {
                            HStack {
                                Label(adapter.name, systemImage: adapter.likelyOBD ? "car.side" : "dot.radiowaves.left.and.right")
                                Spacer()
                                if case .connecting(let name) = link.state, name == adapter.name { ProgressView() }
                                if case .ready(let name) = link.state, name == adapter.name {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if link.visibleAdapters.isEmpty {
                        HStack {
                            Text(link.state == .scanning ? "Searching for adapters…" : "No adapters found")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if link.state == .scanning { ProgressView() }
                        }
                    }
                    Toggle("Show all Bluetooth devices", isOn: $link.showAllDevices)
                } header: {
                    Text("Bluetooth")
                } footer: {
                    if case .failed(let reason) = link.state {
                        Text(reason).foregroundStyle(.orange)
                    } else if link.state == .bluetoothOff {
                        Text("Turn Bluetooth on in Control Center.")
                    } else if link.state == .bluetoothDenied {
                        Text("Allow Bluetooth for EV6 Precondition in iOS Settings.")
                    } else {
                        Text("Adapters don't pair in iOS Settings; they connect here. Classic-Bluetooth adapters can't be used with an iPhone.")
                    }
                }

                Section {
                    Button("Connect to Wi-Fi Adapter") { link.connectWiFi() }
                } footer: {
                    Text("Join the adapter's Wi-Fi network in iOS Settings first (it's usually called WiFi_OBDII or similar). Uses 192.168.0.10, port 35000.")
                }
            }
            .navigationTitle("OBD Adapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if link.isReady {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Disconnect", role: .destructive) { link.disconnect() }
                    }
                }
            }
            .onAppear { link.startScan() }
            .onDisappear { link.stopScan() }
            .onChange(of: link.isReady) { _, ready in if ready { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Report

private struct ReportSections: View {
    let report: BatteryReport
    let problems: [String]
    let miles: Bool

    var body: some View {
        Section {
            HealthGauge(soh: report.sohPercent, description: report.packDescription)
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            ForEach(report.findings, id: \.self) { finding in
                Label(finding, systemImage: "checkmark.seal")
                    .font(.subheadline)
            }
        } footer: {
            Text("Read \(report.takenAt.formatted(date: .abbreviated, time: .shortened))")
        }

        if !report.cellVolts.isEmpty {
            Section {
                CellChart(cells: report.cellVolts)
                    .frame(height: 180)
                    .padding(.vertical, 8)
                if let hi = report.cellVolts.max(), let lo = report.cellVolts.min() {
                    LabeledContent("Highest", value: volts(hi) + (report.cellMaxNumber.map { " · cell \($0)" } ?? ""))
                    LabeledContent("Lowest", value: volts(lo) + (report.cellMinNumber.map { " · cell \($0)" } ?? ""))
                }
                if let spread = report.cellSpreadMillivolts {
                    LabeledContent("Spread", value: String(format: "%.0f mV", spread))
                }
            } header: {
                Text("Cells")
            }
        }

        Section("Pack") {
            row("Charge (BMS)", report.socBMSPercent.map { String(format: "%.1f%%", $0) })
            row("Charge (dashboard)", report.socDisplayPercent.map { String(format: "%.1f%%", $0) })
            row("Voltage", report.packVolts.map { String(format: "%.1f V", $0) })
            row("Current", report.packAmps.map { String(format: "%.1f A", $0) })
            row("Power", report.powerKW.map { String(format: "%.1f kW", $0) })
            row("Max charge power", report.availableChargePowerKW.map { String(format: "%.0f kW", $0) })
        }

        Section("Temperatures") {
            row("Battery", temperatureRange)
            row("Coolant inlet", report.inletC.map { Describe.temp($0) })
            if !report.moduleTempsC.isEmpty {
                row("Modules", report.moduleTempsC.map { String(format: "%.0f", $0) }.joined(separator: " · ") + " °C")
            }
        }

        Section("Since new") {
            row("Charged", report.cumulativeChargedKWh.map { String(format: "%.0f kWh", $0) })
            row("Used", report.cumulativeDischargedKWh.map { String(format: "%.0f kWh", $0) })
            row("Equivalent full cycles", report.cumulativeChargedKWh.map { String(format: "%.0f", $0 / 77.4) })
            row("Operating time", report.operatingHours.map { String(format: "%.0f h", $0) })
        }

        if report.tyrePressuresPsi.contains(where: { $0 != nil }) {
            Section("Tyres") {
                TyreGrid(pressures: report.tyrePressuresPsi, temps: report.tyreTempsC)
                    .padding(.vertical, 6)
            }
        }

        if !problems.isEmpty {
            Section("Not read") {
                ForEach(problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private var temperatureRange: String? {
        switch (report.batteryMinC, report.batteryMaxC) {
        case let (lo?, hi?): return String(format: "%.0f – %.0f °C", lo, hi)
        case let (nil, hi?): return Describe.temp(hi)
        default: return nil
        }
    }

    private func volts(_ v: Double) -> String { String(format: "%.2f V", v) }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value { LabeledContent(title, value: value) }
    }
}

private struct HealthGauge: View {
    let soh: Double?
    let description: String?

    private var tint: Color {
        guard let soh else { return .secondary }
        if soh >= 95 { return .green }
        if soh >= 85 { return .yellow }
        return .orange
    }

    var body: some View {
        HStack(spacing: 20) {
            Gauge(value: min(max((soh ?? 0) - 70, 0), 30), in: 0...30) {
                Text("SOH")
            } currentValueLabel: {
                Text(soh.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(1.5)
            .frame(width: 90, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text("State of health").font(.headline)
                Text(soh.map { String(format: "%.1f%% of original capacity", $0) } ?? "Not reported")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CellChart: View {
    let cells: [Double]

    private var points: [(Int, Double)] { cells.enumerated().map { ($0.offset + 1, $0.element) } }

    var body: some View {
        let lo = (cells.min() ?? 3.5) - 0.02
        let hi = (cells.max() ?? 4.2) + 0.02
        Chart(points, id: \.0) { cell in
            BarMark(
                x: .value("Cell", cell.0),
                yStart: .value("Base", lo),
                yEnd: .value("Volts", cell.1)
            )
            .foregroundStyle(cell.1 == cells.min() ? Color.orange : Color.green.opacity(0.8))
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.2f", v)) } }
            }
        }
        .chartXAxisLabel("Cell")
    }
}

private struct TyreGrid: View {
    let pressures: [Double?]
    let temps: [Double?]
    private let names = ["Front left", "Front right", "Rear left", "Rear right"]

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow { cell(0); cell(1) }
            GridRow { cell(2); cell(3) }
        }
    }

    private func cell(_ i: Int) -> some View {
        let psi = pressures.indices.contains(i) ? pressures[i] : nil
        let temp = temps.indices.contains(i) ? temps[i] : nil
        let low = (psi ?? 99) < 33
        return VStack(spacing: 2) {
            Text(psi.map { String(format: "%.1f", $0) } ?? "–")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(low ? .orange : .primary)
            Text("psi · \(temp.map { String(format: "%.0f °C", $0) } ?? "–")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(names[i]).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
