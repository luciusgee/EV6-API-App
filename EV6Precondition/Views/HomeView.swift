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

/// The first tab: your car on a scan bay you can turn round, the connection, and live gauges.
struct HomeView: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs
    @Environment(BatteryReportStore.self) private var battery
    @State private var showingAdapters = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ScanBay()
                    if obd.carState != .connected {
                        ConnectPrompt(showingAdapters: $showingAdapters)
                    }
                    if let report = battery.report {
                        LastHealthCard(report: report)
                    }
                    DashboardGauges()
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle(prefs.car.shortName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionButton(showingAdapters: $showingAdapters)
                }
            }
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
        }
    }
}

/// The car on a dark diagnostics backdrop. Drag to turn it round; the grid glows green while the car
/// is connected.
private struct ScanBay: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs
    @State private var sweep = false

    private var connected: Bool { obd.carState == .connected }
    private var tint: Color { connected ? .green : .teal }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.09, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.03)],
                startPoint: .topTrailing, endPoint: .bottomLeading
            )
            Canvas { context, size in
                var path = Path()
                stride(from: 0, through: size.width, by: 22).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: 0, through: size.height, by: 22).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(tint.opacity(0.10)), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            GeometryReader { geo in
                LinearGradient(colors: [.clear, tint.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60)
                    .offset(x: sweep ? geo.size.width : -60)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            Ellipse()
                .fill(tint.opacity(0.25))
                .frame(width: 280, height: 28)
                .blur(radius: 18)
                .frame(maxWidth: .infinity)
                .offset(y: -40)
                .allowsHitTesting(false)
            CarHeroImage(paint: prefs.paint)
                .padding(.horizontal, 8)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(prefs.car.name.uppercased()).font(.system(size: 13, weight: .heavy)).tracking(3)
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? (obd.demo != nil ? "Demo car connected" : "Connected · live data") : "Drag to turn the car round")
                        .font(.caption)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .allowsHitTesting(false)
        }
        .frame(height: 280)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { sweep = true }
        }
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
