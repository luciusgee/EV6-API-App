import PreconditionKit
import SwiftUI

/// The app's name, in one place while it's settled.
enum AppInfo {
    static let name = "Volt Lab"
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }
}

/// The first tab: the car drawn live from its own data, the connection, and live gauges.
struct HomeView: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs
    @Environment(BatteryReportStore.self) private var battery
    @State private var showingAdapters = false

    private var electric: Bool { prefs.platform == .egmp }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CarHeader()
                    if obd.carState != .connected {
                        ConnectPrompt(showingAdapters: $showingAdapters)
                    }
                    if let charge = obd.charge {
                        NavigationLink {
                            ChargingView()
                        } label: {
                            LiveChargeCard(session: charge, kW: -(obd.latest["power"] ?? 0))
                        }
                        .buttonStyle(.plain)
                    }
                    if electric, let report = battery.report {
                        LastHealthCard(report: report)
                    }
                    DashboardGauges()
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle(prefs.carName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionButton(showingAdapters: $showingAdapters)
                }
            }
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
        }
    }
}

private extension Preferences {
    /// What to call the car on Home: the model for E-GMP cars; for any other car, the make from its VIN.
    /// "Any other car" stays as the picker label only.
    var carName: String {
        guard platform == .generic else { return model.name }
        return vin.flatMap(VIN.init)?.make ?? "Your car"
    }
}

/// The car from above with what it's doing, on a dark scan bay.
private struct CarHeader: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs
    @Environment(BatteryReportStore.self) private var battery

    private var connected: Bool { obd.carState == .connected }
    private var electric: Bool { prefs.platform == .egmp }

    private var moduleDeviations: [Double] {
        guard let report = battery.report else { return [] }
        let a = BatteryAnalysis(report)
        guard let mean = a.meanVolts else { return [] }
        return a.modules.map { ($0.meanVolts - mean) * 1000 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ChassisView(
                socPercent: obd.latest["socBMS"],
                powerKW: obd.latest["power"],
                charging: obd.charge != nil,
                tyrePsi: ["FL", "FR", "RL", "RR"].map { obd.latest["psi\($0)"] },
                modules: moduleDeviations,
                electric: electric
            )
            .frame(maxHeight: 300)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prefs.model.make.isEmpty ? "OBD-II" : prefs.model.make.uppercased())
                        .font(.caption.weight(.heavy))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    Text(prefs.carName).font(.title2.weight(.bold))
                    if let year = prefs.vin.flatMap(VIN.init)?.year {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                stat("Status", connected ? (obd.charge != nil ? "Charging" : obd.demo != nil ? "Demo" : "Live") : "Offline",
                     tint: connected ? .green : .secondary)
                if electric {
                    stat("Power", obd.latest["power"].map { String(format: "%.1f kW", $0) } ?? "–")
                    stat("Battery", obd.latest["battMax"].map { String(format: "%.0f °C", $0) } ?? "–")
                } else {
                    stat("Engine", obd.latest["rpm"].map { String(format: "%.0f rpm", $0) } ?? "–")
                    stat("Coolant", obd.latest["coolant"].map { String(format: "%.0f °C", $0) } ?? "–")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RadialGradient(colors: [(connected ? Color.green : Color.teal).opacity(0.14), Color.white.opacity(0.03)], center: .leading, startRadius: 10, endRadius: 300),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .liveSensors(electric ? ["socBMS", "power", "battMax", "speed", "charged", "psiFL", "psiFR", "psiRL", "psiRR"] : ["rpm", "coolant", "speed"], screen: "home")
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().foregroundStyle(tint)
        }
    }
}

/// The charge under way, from the home screen.
private struct LiveChargeCard: View {
    let session: ChargeSession
    let kW: Double

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.car.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Charging at %.1f kW", max(kW, 0))).font(.headline)
                Text(String(format: "%.1f kWh added in %@", session.energyKWh, DisplayText.duration(minutes: Int(session.duration / 60))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ConnectPrompt: View {
    @Environment(OBDService.self) private var obd
    @Binding var showingAdapters: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(obd.adapterConnected ? "Waiting for the car" : "Not connected", systemImage: "cable.connector")
                .font(.headline)
            Text(obd.adapterConnected
                ? "Switch the car on (ready, or start without the brake), then tap Retry."
                : "Plug your OBD adapter in under the dashboard, switch the car on and tap Connect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if obd.adapterConnected {
                    Button("Retry") { Task { await obd.retryCar() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .foregroundStyle(Color.black)
                } else {
                    Button("Connect") {
                        if !obd.connect() { showingAdapters = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .foregroundStyle(Color.black)
                    Button("Demo car") { obd.startDemo() }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The last battery read, in a line.
private struct LastHealthCard: View {
    let report: BatteryReport

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "battery.100percent.bolt")
                .font(.title2)
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.sohPercent.map { String(format: "Battery health %.1f%%", $0) } ?? "Battery report")
                    .font(.headline)
                Text("Read " + report.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
