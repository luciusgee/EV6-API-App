import PreconditionKit
import SwiftUI

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
                    .foregroundStyle(Color.black)
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
            if !obd.adapterConnected {
                Button("No adapter? Try the demo car") { obd.startDemo() }
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

/// The connection at a glance, in the toolbar. Tap for the adapter and the car.
struct ConnectionButton: View {
    @Environment(OBDService.self) private var obd
    @Binding var showingAdapters: Bool
    @State private var showing = false

    private var tint: Color {
        switch obd.carState {
        case .connected: return .green
        case .connecting: return .yellow
        case .noAnswer: return .orange
        case .disconnected: return obd.adapterConnected ? .yellow : .gray
        }
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(obd.demo != nil ? "Demo" : obd.carState == .connected ? "Live" : obd.adapterConnected ? "Adapter" : "Connect")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(obd.carText)")
        .sheet(isPresented: $showing) {
            ConnectionSheet()
        }
    }
}

/// The adapter and car, with Connect, the adapter list and the demo car.
struct ConnectionSheet: View {
    @Environment(OBDService.self) private var obd
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdapters = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: obd.carState == .connected ? "car.side.fill" : "cable.connector")
                    .font(.system(size: 46))
                    .foregroundStyle(obd.carState == .connected ? .green : .secondary)
                    .padding(.top, 20)
                Text("Plug a Bluetooth LE OBD adapter (like the Veepeak OBDCheck BLE) into the port under the dashboard, switch the car on, then connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
                ConnectionBar(showingAdapters: $showingAdapters)
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
        }
        .presentationDetents([.medium, .large])
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
                        Text("Allow Bluetooth for \(AppInfo.name) in iOS Settings.")
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
