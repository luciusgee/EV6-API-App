import Charts
import PreconditionKit
import SwiftUI

/// One point on the battery-health chart, saved with every read.
struct HealthPoint: Codable, Equatable, Identifiable {
    var takenAt: Date
    var sohPercent: Double?
    var cellSpreadMV: Double?
    var odometerKm: Double?
    /// The car it was read from. Missing on points saved before these were kept.
    var vin: String?
    var modelId: String?
    var id: Date { takenAt }

    /// From this car. Points saved before the car was kept are counted as the user's own.
    func belongs(to car: ReportCar?) -> Bool {
        guard let car else { return true }
        if let vin, let other = car.vin { return vin == other }
        if let modelId { return modelId == car.modelId }
        return true
    }
}

/// The car a battery report was read from, so it's labelled and sized as that car whatever is chosen now.
struct ReportCar: Codable, Equatable {
    var vin: String?
    var modelId: String
}

/// The last battery report, and every read's headline numbers, kept on the phone.
@MainActor
@Observable
final class BatteryReportStore {
    /// One store, so the Car tab's and the Scanner's Battery health screens share a read in progress.
    static let shared = BatteryReportStore()

    private(set) var report: BatteryReport?
    /// The car `report` came from; nil for reports read before this was kept.
    private(set) var car: ReportCar?
    private(set) var history: [HealthPoint] = []
    /// A read of the demo car: kept in memory only, never saved over or added to the user's own.
    private(set) var demoReport: BatteryReport?
    private(set) var demoCar: ReportCar?
    private let historyStore: JSONFileStore<[HealthPoint]>
    private let carStore: JSONFileStore<ReportCar?>
    private(set) var problems: [String] = []
    private(set) var progress: BatteryScanner.Progress?
    private(set) var error: String?
    private let store: JSONFileStore<BatteryReport?>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-report.json"), default: nil)
        historyStore = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-history.json"), default: [])
        carStore = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/battery-report-car.json"), default: nil)
    }

    var scanning: Bool { progress != nil }

    func load() async {
        report = await store.load()
        car = await carStore.load()
        history = await historyStore.load()
        // Reports read before the history existed.
        if history.isEmpty, let report {
            history = [Self.point(report, car: car, odometerKm: nil)]
            await historyStore.save(history)
        }
    }

    /// The reads of this car, oldest first.
    func history(for car: ReportCar?) -> [HealthPoint] {
        history.filter { $0.belongs(to: car) }
    }

    static func point(_ r: BatteryReport, car: ReportCar?, odometerKm: Double?) -> HealthPoint {
        var spread: Double?
        if let high = r.cellMaxVolts, let low = r.cellMinVolts { spread = (high - low) * 1000 }
        return HealthPoint(
            takenAt: r.takenAt, sohPercent: r.sohPercent, cellSpreadMV: spread, odometerKm: odometerKm,
            vin: car?.vin, modelId: car?.modelId
        )
    }

    private func setProgress(_ p: BatteryScanner.Progress) {
        progress = p
    }

    /// Reads the battery. A read of the demo car (`demo`) is kept apart and never saved.
    func scan(_ elm: ELM327, car: ReportCar, demo: Bool, odometerKm: Double? = nil) async {
        guard !scanning else { return }
        error = nil
        problems = []
        progress = BatteryScanner.Progress(step: 0, of: 10, label: "Starting")
        let scanner = BatteryScanner(elm: elm)
        do {
            let (result, issues) = try await scanner.scan { p in await self.setProgress(p) }
            problems = issues
            if demo {
                demoReport = result
                demoCar = car
            } else {
                // History first, with no wait in between, so nothing sees the new report with the old history.
                history.append(Self.point(result, car: car, odometerKm: odometerKm))
                history.sort { $0.takenAt < $1.takenAt }
                report = result
                self.car = car
                await store.save(result)
                await carStore.save(car)
                await historyStore.save(history)
            }
        } catch {
            self.error = (error as? OBDError)?.description ?? error.localizedDescription
        }
        progress = nil
    }
}

/// The battery report: a grade, checks, every cell and module, temperatures, lifetime use and
/// history, with a PDF to share.
struct BatteryHealthView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(OBDService.self) private var obd
    @State private var reports = BatteryReportStore.shared
    @State private var showingAdapters = false
    @State private var pdf: URL?
    @State private var showingPro = false
    @Environment(Store.self) private var store

    private var demo: Bool { obd.demo != nil }
    /// The demo car's read while the demo runs, the user's own otherwise.
    private var shown: BatteryReport? { demo ? reports.demoReport : reports.report }
    private var shownCar: ReportCar? { demo ? reports.demoCar : reports.car }
    /// The car the report came from; the one chosen now for reports read before that was kept.
    private var reportModel: VehicleModel { shownCar.flatMap { Vehicles.model($0.modelId) } ?? prefs.model }
    private var carName: String {
        demo ? "\(reportModel.fullName) · DEMO DATA – not a real vehicle" : reportModel.fullName
    }
    /// The demo's history is never kept; the user's is only that car's reads.
    private var history: [HealthPoint] { demo ? [] : reports.history(for: shownCar) }

    /// Whether the report is from the car chosen now, so the chosen pack applies to it.
    private var isCurrentCar: Bool {
        guard let car = shownCar else { return true }
        if car.modelId != prefs.modelId { return false }
        if let vin = car.vin, let current = prefs.vin { return vin == current }
        return true
    }

    private var analysis: BatteryAnalysis? {
        shown.map { r in
            // No cells read (or left out over a gap): don't infer the pack from a partial count.
            let cells: Int? = r.cellVolts.isEmpty ? nil : r.cellVolts.count
            let pack = isCurrentCar
                ? prefs.pack(cells: cells)
                : cells.flatMap { reportModel.pack(cells: $0, year: shownCar?.vin.flatMap(VIN.init)?.year) }
            return BatteryAnalysis(r, pack: pack)
        }
    }

    /// Everything the PDF is made from, so it's remade when any of it changes.
    private struct PDFInputs: Equatable {
        var takenAt: Date?
        var history: [HealthPoint]
        var car: String
        var pack: Double?
        var miles: Bool
    }

    private var pdfInputs: PDFInputs {
        PDFInputs(takenAt: shown?.takenAt, history: history, car: carName, pack: analysis?.nominalKWh, miles: prefs.useMiles)
    }

    var body: some View {
        if prefs.platform.hasBatteryData {
            report
        } else {
            ContentUnavailableView {
                Label("Battery data needs a supported EV", systemImage: "battery.100percent.bolt")
            } description: {
                Text("The battery report reads the battery management system of E-GMP cars: Kia EV6 and EV9, Hyundai Ioniq 5, 6 and 9, Genesis GV60 and Electrified GV70. Choose your car in More if it's one of these.")
            }
            .navigationTitle("Battery")
        }
    }

    private var report: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let analysis {
                    GradeCard(analysis: analysis, car: carName)
                }
                readCard
                if let analysis {
                    ChecksCard(checks: analysis.checks)
                    if analysis.cellCount > 1 {
                        Card("Cells") { CellsSection(analysis: analysis) }
                        if !analysis.modules.isEmpty {
                            Card("Modules") { ModuleGrid(modules: analysis.modules, mean: analysis.meanVolts ?? 0) }
                        }
                    }
                    Card("Pack") { PackRows(analysis: analysis) }
                    if analysis.report.tyrePressuresPsi.contains(where: { $0 != nil }) {
                        Card("Tyres") { TyreGrid(pressures: analysis.report.tyrePressuresPsi, temps: analysis.report.tyreTempsC) }
                    }
                    if history.filter({ $0.sohPercent != nil }).count >= 2 {
                        Card("History") { HealthHistory(history: history) }
                    }
                    if !reports.problems.isEmpty {
                        Card("Couldn't read") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(reports.problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text(BatteryPDF.caveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle("Battery")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionButton(showingAdapters: $showingAdapters)
            }
            ToolbarItem(placement: .topBarLeading) {
                if let pdf {
                    if store.isPro {
                        ShareLink(item: pdf) { Label("PDF report", systemImage: "doc.richtext") }
                    } else {
                        Button { showingPro = true } label: { Label("PDF report", systemImage: "doc.richtext") }
                    }
                }
            }
        }
        .task { await reports.load() }
        .task(id: pdfInputs) { makePDF() }
        .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
        .sheet(isPresented: $showingPro) { ProSheet() }
    }

    private func makePDF() {
        guard let analysis else {
            pdf = nil
            return
        }
        pdf = BatteryPDF.make(analysis, history: history, car: demo ? reportModel.fullName : carName, miles: prefs.useMiles, demo: demo)
    }

    private var readCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let elm = obd.elm {
                    let car = ReportCar(vin: obd.vin?.text ?? prefs.vin, modelId: prefs.modelId)
                    let isDemo = demo
                    Task { await reports.scan(elm, car: car, demo: isDemo) }
                }
            } label: {
                HStack {
                    Label(shown == nil ? "Read battery" : "Read again", systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    if reports.scanning { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .foregroundStyle(Color.black)
            .disabled(reports.scanning || obd.carState != .connected)
            if let progress = reports.progress {
                ProgressView(value: Double(progress.step), total: Double(progress.of)) {
                    Text(progress.label).font(.caption).foregroundStyle(.secondary)
                }
                .tint(.mint)
            } else if obd.carState != .connected {
                Text("Connect your adapter with the car switched on. Reading takes about 10 seconds and changes nothing on the car.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("For the most telling cell readings, read after the car has rested for an hour or so, not straight after driving or charging.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = reports.error {
                Label(error.capitalizingFirst, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Pieces, shared with the PDF

/// A titled panel.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension BatteryAnalysis.Status {
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .yellow
        case .attention: return .orange
        case .unknown: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .fair: return "minus.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct GradeCard: View {
    let analysis: BatteryAnalysis
    let car: String

    private var soh: Double? { analysis.report.sohPercent }
    private var tint: Color {
        switch analysis.grade {
        case "A": return .green
        case "B": return .mint
        case "C": return .yellow
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(max(((soh ?? 0) - 60) / 40, 0), 1))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(soh.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("% SOH").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(analysis.grade)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(tint)
                    Text("Overall").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let now = analysis.estimatedKWh, let new = analysis.nominalKWh {
                    Text(String(format: "About %.1f of %.1f kWh", now, new)).font(.subheadline.weight(.semibold))
                } else if let new = analysis.nominalKWh {
                    Text(String(format: "%.1f kWh pack", new)).font(.subheadline.weight(.semibold))
                }
                Text("\(car) · \(analysis.report.takenAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            LinearGradient(colors: [tint.opacity(0.22), Color.primary.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

struct ChecksCard: View {
    let checks: [BatteryAnalysis.Check]

    var body: some View {
        Card("Checks") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: check.status.symbol)
                            .foregroundStyle(check.status.color)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(check.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(check.value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct CellsSection: View {
    let analysis: BatteryAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CellChart(cells: analysis.report.cellVolts, mean: analysis.meanVolts, outliers: Set(analysis.outliers.map(\.number)))
                .frame(height: 170)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("Average", analysis.meanVolts.map { String(format: "%.3f V", $0) })
                    stat("Median", analysis.medianVolts.map { String(format: "%.3f V", $0) })
                }
                GridRow {
                    stat("Spread", analysis.spreadMV.map { String(format: "%.0f mV", $0) })
                    stat("Std deviation", analysis.standardDeviationMV.map { String(format: "%.1f mV", $0) })
                }
            }
            HStack(alignment: .top, spacing: 16) {
                cellList("Lowest", analysis.weakest)
                cellList("Highest", analysis.strongest)
            }
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–").font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func cellList(_ title: String, _ cells: [BatteryAnalysis.Cell]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(cells, id: \.number) { cell in
                HStack {
                    Text("#\(cell.number)").frame(width: 40, alignment: .leading)
                    Text(String(format: "%.3f", cell.volts))
                    Text(String(format: "%+.0f", cell.deviationMV)).foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CellChart: View {
    let cells: [Double]
    var mean: Double?
    var outliers: Set<Int> = []

    private var points: [(Int, Double)] { cells.enumerated().map { ($0.offset + 1, $0.element) } }

    var body: some View {
        let lo = (cells.min() ?? 3.5) - 0.01
        let hi = (cells.max() ?? 4.2) + 0.005
        let lowest = cells.min()
        Chart {
            ForEach(points, id: \.0) { cell in
                BarMark(x: .value("Cell", cell.0), yStart: .value("Base", lo), yEnd: .value("Volts", cell.1))
                    .foregroundStyle(cell.1 == lowest || outliers.contains(cell.0) ? Color.orange : Color.mint.opacity(0.85))
            }
            if let mean {
                RuleMark(y: .value("Average", mean))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
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

/// Every module as a tile, shaded by how far its cells sit from the pack's average.
struct ModuleGrid: View {
    let modules: [BatteryAnalysis.Module]
    let mean: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var big: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var small: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 40

    /// Fewer, wider tiles at the larger text sizes, so the numbers still fit.
    private var columns: Int { typeSize.isAccessibilitySize ? 4 : 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                ForEach(modules) { m in
                    let dev = (m.meanVolts - mean) * 1000
                    VStack(spacing: 1) {
                        Text("\(m.number)").font(.system(size: big, weight: .bold))
                        Text(String(format: "%+.0f", dev)).font(.system(size: big).monospacedDigit())
                        if let t = m.temperatureC {
                            Text(String(format: "%.0f°", t)).font(.system(size: small)).opacity(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(color(dev).opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.black)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label(m, dev))
                    .accessibilityValue(status(dev))
                }
            }
            Text("Each tile is a module of six cells: its number, its average against the pack's in mV, and its temperature sensor.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ m: BatteryAnalysis.Module, _ dev: Double) -> String {
        let mV = Int(abs(dev).rounded())
        var text = "Module \(m.number): "
        text += mV == 0 ? "at the pack average" : "\(mV) millivolts \(dev > 0 ? "above" : "below") average"
        if let t = m.temperatureC { text += String(format: ", %.0f °C", t) }
        return text
    }

    /// What the tile's colour means.
    private func status(_ dev: Double) -> String {
        if dev < -15 { return "Well below the others" }
        if dev < -6 { return "A little low" }
        if dev > 6 { return "A little high" }
        return "In line"
    }

    private func color(_ dev: Double) -> Color {
        if dev < -15 { return .orange }
        if dev < -6 { return .yellow }
        if dev > 6 { return .cyan }
        return .mint
    }
}

struct PackRows: View {
    let analysis: BatteryAnalysis
    private var r: BatteryReport { analysis.report }

    var body: some View {
        VStack(spacing: 8) {
            row("Pack", analysis.report.packDescription)
            row("Charge (battery's own)", r.socBMSPercent.map { String(format: "%.1f%%", $0) })
            row("Charge (dashboard)", r.socDisplayPercent.map { String(format: "%.1f%%", $0) })
            row("Voltage", r.packVolts.map { String(format: "%.1f V", $0) })
            row("Current", r.packAmps.map { String(format: "%.1f A", $0) })
            row("Max charge power now", r.availableChargePowerKW.map { String(format: "%.0f kW", $0) })
            row("Battery temperature", temperatureRange)
            row("Coolant inlet", r.inletC.map { String(format: "%.0f °C", $0) })
            row("Charged since new", r.cumulativeChargedKWh.map { String(format: "%.0f kWh", $0) })
            row("Used since new", r.cumulativeDischargedKWh.map { String(format: "%.0f kWh", $0) })
            row("Equivalent full cycles", analysis.equivalentCycles.map { String(format: "%.0f", $0) })
            row("Out / in since new", analysis.throughputRatio.map { String(format: "%.0f%%", $0 * 100) })
            row("Operating time", r.operatingHours.map { String(format: "%.0f h", $0) })
        }
    }

    private var temperatureRange: String? {
        switch (r.batteryMinC, r.batteryMaxC) {
        case let (lo?, hi?): return String(format: "%.0f – %.0f °C", lo, hi)
        case let (nil, hi?): return String(format: "%.0f °C", hi)
        default: return nil
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.subheadline)
        }
    }
}

struct HealthHistory: View {
    let history: [HealthPoint]

    private var soh: [HealthPoint] { history.filter { $0.sohPercent != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(soh) { p in
                LineMark(x: .value("Date", p.takenAt), y: .value("SOH", p.sohPercent ?? 0))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.mint)
                PointMark(x: .value("Date", p.takenAt), y: .value("SOH", p.sohPercent ?? 0))
                    .symbolSize(24)
                    .foregroundStyle(.mint)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("SOH %")
            .frame(height: 160)
            if let first = soh.first?.sohPercent, let last = soh.last?.sohPercent {
                Text(String(format: "%+.1f%% since the first read", last - first)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TyreGrid: View {
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
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
