import PreconditionKit
import SwiftUI

/// The OBD scanner (like Car Scanner, made for the EV6): dashboard, live data, every sensor, trouble
/// codes, module info, battery health, performance timing, trips and recording.
struct ScannerView: View {
    @Environment(OBDService.self) private var obd
    @State private var showingAdapters = false

    private struct Tool: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let tint: Color
    }

    private let tools = [
        Tool(id: "dashboard", title: "Dashboard", systemImage: "gauge.open.with.lines.needle.33percent", tint: .blue),
        Tool(id: "live", title: "Live Data", systemImage: "waveform.path.ecg", tint: .green),
        Tool(id: "sensors", title: "All Sensors", systemImage: "list.bullet.rectangle", tint: .indigo),
        Tool(id: "codes", title: "Trouble Codes", systemImage: "exclamationmark.triangle", tint: .orange),
        Tool(id: "battery", title: "Battery Health", systemImage: "battery.100percent.bolt", tint: .mint),
        Tool(id: "modules", title: "Modules & VIN", systemImage: "cpu", tint: .gray),
        Tool(id: "performance", title: "Performance", systemImage: "stopwatch", tint: .red),
        Tool(id: "trip", title: "Trip Computer", systemImage: "road.lanes", tint: .teal),
        Tool(id: "recordings", title: "Recordings", systemImage: "record.circle", tint: .pink),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                ScannerHeader()
                    .padding([.horizontal, .top], 16)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(tools) { tool in
                        NavigationLink(value: tool.id) {
                            VStack(spacing: 10) {
                                Image(systemName: tool.systemImage)
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(tool.tint)
                                    .frame(height: 34)
                                Text(tool.title)
                                    .font(.footnote.weight(.medium))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2, reservesSpace: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                ConnectionBar(showingAdapters: $showingAdapters)
            }
            .navigationTitle("Scanner")
            .navigationDestination(for: String.self) { id in
                switch id {
                case "dashboard": DashboardView()
                case "live": LiveDataView()
                case "sensors": AllSensorsView()
                case "codes": TroubleCodesView()
                case "battery": BatteryHealthView()
                case "modules": ModulesView()
                case "performance": PerformanceView()
                case "trip": TripView()
                default: RecordingsView()
                }
            }
            .sheet(isPresented: $showingAdapters) {
                AdapterPicker(link: obd.link)
            }
        }
    }
}

/// Kia's GT-Line render on a dark diagnostics backdrop, with the badge and live status. The grid glows
/// green while the car is connected.
private struct ScannerHeader: View {
    @Environment(OBDService.self) private var obd
    @State private var sweep = false

    private var connected: Bool { obd.carState == .connected }
    private var tint: Color { connected ? .green : .teal }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.09, blue: 0.11), Color(red: 0.02, green: 0.02, blue: 0.03)],
                startPoint: .topTrailing, endPoint: .bottomLeading
            )
            // A faint grid, like a scan bay.
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
            // The scan line.
            GeometryReader { geo in
                LinearGradient(colors: [.clear, tint.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60)
                    .offset(x: sweep ? geo.size.width : -60)
                    .blendMode(.plusLighter)
            }
            Ellipse()
                .fill(tint.opacity(0.25))
                .frame(width: 260, height: 26)
                .blur(radius: 18)
                .offset(x: 120, y: -26)
            Image("EV6Spin10")
                .resizable()
                .scaledToFit()
                .frame(height: 150)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, -10)
                .padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image("KiaLogo").renderingMode(.template).resizable().scaledToFit().frame(height: 13)
                    Text("EV6 GT-LINE").font(.system(size: 13, weight: .heavy)).tracking(3)
                }
                HStack(spacing: 6) {
                    Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? (obd.demo ? "Demo car connected" : "Connected to your EV6") : "Diagnostics & live data")
                        .font(.caption)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}

/// Adapter and car status, with Connect, at the bottom of every scanner screen.
struct ConnectionBar: View {
    @Environment(OBDService.self) private var obd
    @Binding var showingAdapters: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Adapter").foregroundStyle(.secondary)
                Spacer()
                Text(obd.adapterText)
                    .foregroundStyle(obd.adapterConnected ? .green : .secondary)
                    .lineLimit(1)
            }
            HStack {
                Text("Car").foregroundStyle(.secondary)
                Spacer()
                if obd.carState == .connecting { ProgressView().controlSize(.small) }
                Text(obd.carText)
                    .foregroundStyle(obd.carState == .connected ? .green : (obd.carState == .disconnected ? .secondary : .orange))
                    .lineLimit(1)
                if case .noAnswer = obd.carState {
                    Button("Retry") { Task { await obd.retryCar() } }
                        .font(.footnote.weight(.semibold))
                }
            }
            HStack(spacing: 10) {
                if obd.adapterConnected {
                    Button(role: .destructive) {
                        obd.disconnect()
                    } label: {
                        Text("Disconnect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        if !obd.connect() { showingAdapters = true }
                    } label: {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .contextMenu {
                        Button("Choose Adapter…") { showingAdapters = true }
                        if obd.link.hasRemembered {
                            Button("Forget \(obd.link.rememberedName ?? "Adapter")", role: .destructive) { obd.link.forgetAdapter() }
                        }
                    }
                }
            }
            .controlSize(.large)
            if !obd.adapterConnected && obd.link.hasRemembered {
                Button("Use a different adapter") { showingAdapters = true }
                    .font(.footnote)
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(.bar)
    }
}

// MARK: - Shared pieces

/// Starts the live loop for a screen's sensors while it's on screen.
struct LiveSensors: ViewModifier {
    @Environment(OBDService.self) private var obd
    let screen: String
    let ids: [String]

    func body(content: Content) -> some View {
        content
            .onAppear { obd.want(ids, for: screen) }
            .onDisappear { obd.release(screen) }
            .onChange(of: ids) { _, new in obd.want(new, for: screen) }
            .onChange(of: obd.carState) { _, state in if state == .connected { obd.want(ids, for: screen) } }
    }
}

extension View {
    func liveSensors(_ ids: [String], screen: String) -> some View {
        modifier(LiveSensors(screen: screen, ids: ids))
    }
}

/// Shown instead of data until the car answers.
struct NotConnectedHint: View {
    @Environment(OBDService.self) private var obd

    var body: some View {
        if obd.carState != .connected {
            ContentUnavailableView {
                Label(obd.adapterConnected ? "Waiting for the car" : "Not connected", systemImage: "cable.connector.slash")
            } description: {
                Text(obd.adapterConnected
                    ? "Switch the car on (ready, or press start without the brake), then tap Retry."
                    : "Plug your adapter into the OBD port under the dashboard and tap Connect.")
            }
        }
    }
}

extension Sensor {
    /// The value formatted for display, with gear letters and yes/no for switches.
    func display(_ v: Double?, miles: Bool) -> String {
        guard let v else { return "–" }
        if id == "gear" { return EV6Sensors.gearName(v) }
        if range == 0...1 && unit.isEmpty { return v >= 0.5 ? "Yes" : "No" }
        if miles, unit == "km/h" { return String(format: "%.0f mph", v / DisplayText.kmPerMile) }
        if miles, unit == "km" { return String(format: "%.0f mi", v / DisplayText.kmPerMile) }
        return format(v)
    }
}
