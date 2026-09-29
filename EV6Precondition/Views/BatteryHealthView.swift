import Charts
import PreconditionKit
import SwiftUI

/// One point on the battery-health chart, saved with every read.
struct HealthPoint: Codable, Equatable, Identifiable {
    var takenAt: Date
    var sohPercent: Double?
    var cellSpreadMV: Double?
    var odometerKm: Double?
    var id: Date { takenAt }
}

/// The last battery report, and every read's headline numbers, kept on the phone.
@MainActor
@Observable
final class BatteryReportStore {
    /// One store, so the Car tab's and the Scanner's Battery health screens share a read in progress.
    static let shared = BatteryReportStore()

    private(set) var report: BatteryReport?
    private(set) var history: [HealthPoint] = []
    private let historyStore: JSONFileStore<[HealthPoint]>
    private(set) var problems: [String] = []
    private(set) var progress: BatteryScanner.Progress?
    private(set) var error: String?
    private let store: JSONFileStore<BatteryReport?>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-report.json"), default: nil)
        historyStore = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-history.json"), default: [])
    }

    var scanning: Bool { progress != nil }

    func load() async {
        report = await store.load()
        history = await historyStore.load()
        // Reports read before the history existed.
        if history.isEmpty, let report {
            history = [Self.point(report, odometerKm: nil)]
            await historyStore.save(history)
        }
    }

    static func point(_ r: BatteryReport, odometerKm: Double?) -> HealthPoint {
        var spread: Double?
        if let high = r.cellMaxVolts, let low = r.cellMinVolts { spread = (high - low) * 1000 }
        return HealthPoint(takenAt: r.takenAt, sohPercent: r.sohPercent, cellSpreadMV: spread, odometerKm: odometerKm)
    }

    private func setProgress(_ p: BatteryScanner.Progress) {
        progress = p
    }

    func scan(_ elm: ELM327, odometerKm: Double? = nil) async {
        guard !scanning else { return }
        error = nil
        problems = []
        progress = BatteryScanner.Progress(step: 0, of: 10, label: "Starting")
        let scanner = BatteryScanner(elm: elm)
        do {
            let (result, issues) = try await scanner.scan { p in await self.setProgress(p) }
            report = result
            problems = issues
            await store.save(result)
            history.append(Self.point(result, odometerKm: odometerKm))
            history.sort { $0.takenAt < $1.takenAt }
            await historyStore.save(history)
        } catch {
            self.error = (error as? OBDError)?.description ?? error.localizedDescription
        }
        progress = nil
    }
}

struct BatteryHealthView: View {
    @Environment(CarModel.self) private var car
    @Environment(OBDService.self) private var obd
    @State private var reports = BatteryReportStore.shared
    @State private var showingAdapters = false

    var body: some View {
        List {
            if let soh = car.snapshot?.details?.batteryHealthPercent, reports.report?.sohPercent == nil {
                Section {
                    LabeledContent("State of health (Kia Connect)", value: String(format: "%.1f%%", soh))
                }
            }

            Section {
                Button {
                    if let elm = obd.elm { Task { await reports.scan(elm, odometerKm: car.snapshot?.details?.odometerKm) } }
                } label: {
                    HStack {
                        Label("Read battery", systemImage: "waveform.path.ecg")
                        Spacer()
                        if reports.scanning { ProgressView() }
                    }
                }
                .disabled(reports.scanning || obd.carState != .connected)
                if obd.carState != .connected, !reports.scanning {
                    Text("Connect an adapter first")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let progress = reports.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.step), total: Double(progress.of))
                        Text(progress.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = reports.error {
                    Label(error.capitalizingFirst, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            } footer: {
                Text("Plug the OBD adapter in under the dashboard, switch the car on and connect below, then tap Read battery. It takes about 10 seconds and changes nothing on the car.")
            }

            if let report = reports.report {
                ReportSections(report: report, problems: reports.problems, miles: car.settings.useMiles)
            }

            if reports.history.filter({ $0.sohPercent != nil }).count >= 2 {
                HealthHistorySection(history: reports.history)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Battery health")
        .task { await reports.load() }
        .safeAreaInset(edge: .bottom) {
            ConnectionBar(showingAdapters: $showingAdapters)
        }
        .sheet(isPresented: $showingAdapters) {
            AdapterPicker(link: obd.link)
        }
    }
}

// MARK: - History

/// State of health and cell balance over time: the numbers that matter for the battery's life and
/// the car's resale value.
private struct HealthHistorySection: View {
    let history: [HealthPoint]

    private var soh: [HealthPoint] { history.filter { $0.sohPercent != nil } }

    var body: some View {
        Section {
            Chart(soh) { p in
                LineMark(x: .value("Date", p.takenAt), y: .value("SOH", p.sohPercent ?? 0))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", p.takenAt), y: .value("SOH", p.sohPercent ?? 0))
                    .symbolSize(24)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("SOH %")
            .frame(height: 180)
            .padding(.vertical, 6)
            if let first = soh.first?.sohPercent, let last = soh.last?.sohPercent {
                LabeledContent("Change since first read", value: String(format: "%+.1f%%", last - first))
            }
            let spreads = history.compactMap(\.cellSpreadMV)
            if let latest = spreads.last {
                LabeledContent("Cell spread, latest", value: String(format: "%.0f mV", latest))
            }
        } header: {
            Text("History")
        } footer: {
            Text("Read it once a month or so to see the trend. If the cell spread keeps climbing past about 50 mV, get it checked.")
        }
    }
}

// MARK: - Adapter picker

struct AdapterPicker: View {
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
                        Text("Turn Bluetooth on in Control Centre.")
                    } else if link.state == .bluetoothDenied {
                        Text("Allow Bluetooth for My EV6 in iOS Settings.")
                    } else {
                        Text("Connect your adapter here, not in iOS Settings. Bluetooth LE and Wi-Fi adapters work.")
                    }
                }

                Section {
                    Button("Connect to a Wi-Fi adapter") { link.connectWiFi() }
                } footer: {
                    Text("Join the adapter's Wi-Fi network in iOS Settings first (it's usually called WiFi_OBDII or similar). Uses 192.168.0.10, port 35000.")
                }
            }
            .navigationTitle("OBD adapter")
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
                Label(finding, systemImage: "info.circle")
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
            row("Charge (battery's own reading)", report.socBMSPercent.map { String(format: "%.1f%%", $0) })
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
            Section("Couldn't read") {
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
