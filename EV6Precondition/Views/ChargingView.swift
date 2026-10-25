import Charts
import PreconditionKit
import SwiftUI

/// Charge sessions: the one under way live, and every recorded charge with its power curve.
struct ChargingView: View {
    @Environment(OBDService.self) private var obd
    @Environment(ChargeStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let live = obd.charge {
                    ChargeSessionCard(session: live, live: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Not charging", systemImage: "powerplug")
                            .font(.headline)
                        Text("Plug in with the adapter connected and this screen open: the charge is recorded as it happens, with its power curve, energy added and battery temperature. The screen stays on while it records.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                ProLock(feature: "Charge history") {
                    if !store.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Past charges").font(.headline)
                            ForEach(store.sessions.reversed()) { session in
                                NavigationLink {
                                    ScrollView {
                                        ChargeSessionCard(session: session, live: false).padding(16)
                                    }
                                    .background(Color.black)
                                    .navigationTitle(session.started.formatted(date: .abbreviated, time: .shortened))
                                    .toolbar {
                                        ToolbarItem(placement: .destructiveAction) {
                                            Button("Delete", role: .destructive) { store.delete([session.id]) }
                                        }
                                    }
                                } label: {
                                    ToolRow(
                                        title: session.started.formatted(date: .abbreviated, time: .shortened),
                                        detail: summary(session),
                                        systemImage: session.isRapid ? "bolt.fill" : "powerplug.fill",
                                        tint: session.isRapid ? .orange : .green
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle("Charging")
        .liveSensors(["power", "socBMS", "battMax", "battMin", "speed", "maxCharge", "charged"], screen: "charging")
    }

    private func summary(_ s: ChargeSession) -> String {
        var parts = [String(format: "%.1f kWh", s.energyKWh)]
        if let a = s.startSoc, let b = s.endSoc { parts.append(String(format: "%.0f → %.0f%%", a, b)) }
        parts.append(String(format: "peak %.0f kW", s.peakKW))
        return parts.joined(separator: " · ")
    }
}

struct ChargeSessionCard: View {
    let session: ChargeSession
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(live ? "Charging now" : (session.isRapid ? "Rapid charge" : "Charge"), systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(live ? .green : .primary)
                    .symbolEffect(.pulse, isActive: live)
                Spacer()
                Text(DisplayText.duration(minutes: Int(session.duration / 60))).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                stat("Added", String(format: "%.1f kWh", session.energyKWh))
                stat("Peak", String(format: "%.0f kW", session.peakKW))
                stat("Average", session.averageKW.map { String(format: "%.0f kW", $0) } ?? "–")
                stat("Start", session.startSoc.map { String(format: "%.0f%%", $0) } ?? "–")
                stat(live ? "Now" : "End", session.endSoc.map { String(format: "%.0f%%", $0) } ?? "–")
                stat("10–80%", session.minutes(from: 10, to: 80).map { "\(Int($0.rounded())) min" } ?? "–")
            }
            if session.curve.count > 2 {
                Text("Power against charge").font(.subheadline.weight(.semibold))
                Chart(session.curve, id: \.soc) { p in
                    AreaMark(x: .value("Charge", p.soc), y: .value("kW", p.kW))
                        .foregroundStyle(LinearGradient(colors: [.green.opacity(0.4), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Charge", p.soc), y: .value("kW", p.kW))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                }
                .chartXAxisLabel("charge %")
                .chartYAxisLabel("kW")
                .frame(height: 180)
            }
            let temps = session.points.filter { $0.batteryMaxC != nil }
            if temps.count > 2 {
                Text("Battery temperature").font(.subheadline.weight(.semibold))
                Chart(temps, id: \.seconds) { p in
                    LineMark(x: .value("Minutes", p.seconds / 60), y: .value("°C", p.batteryMaxC ?? 0))
                        .foregroundStyle(.orange)
                }
                .chartXAxisLabel("minutes")
                .chartYAxisLabel("°C")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 120)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
