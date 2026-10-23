import PreconditionKit
import SwiftUI
import UIKit

/// GPS lap timing: set the start/finish line by driving across it, then every crossing is a lap.
struct LapTimerView: View {
    @Environment(RunStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var location = LapLocation()
    @State private var timer: LapTimer?
    @State private var started: Date?
    @State private var flash: Lap?

    private var miles: Bool { prefs.useMiles }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let timer {
                    running(timer)
                } else {
                    setup
                    sessions
                }
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle("Lap timer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            location.onFix = { fix in
                guard timer != nil else { return }
                let kmh = fix.speed >= 0 ? fix.speed * 3.6 : nil
                if let lap = timer?.add(at: fix.timestamp, point: fix.geoPoint, kmh: kmh) {
                    flash = lap
                }
            }
            location.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            end()
            location.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sensoryFeedback(.success, trigger: flash)
    }

    // MARK: Setup

    private var canSetLine: Bool {
        guard let fix = location.latest else { return false }
        return fix.course >= 0 && fix.speed > 3 && fix.horizontalAccuracy < 20
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Image(systemName: "flag.pattern.checkered.2.crossed")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .padding(.top, 8)
            Text("Drive across your start/finish line and tap the button as you pass it. Every time you cross it the same way after that is a lap.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            gpsStatus
            Button {
                guard let fix = location.latest else { return }
                timer = LapTimer(line: FinishLine(centre: fix.geoPoint, heading: fix.course))
                // This fix is on the line: the next ones start the first lap.
                started = Date()
            } label: {
                Label("Set line here", systemImage: "flag.checkered")
                    .font(.title3.weight(.heavy))
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.orange)
            .disabled(!canSetLine)
            if !canSetLine {
                Text(location.latest == nil ? "Waiting for GPS…" : "Get moving (over 7 mph) with a good GPS signal to set the line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var gpsStatus: some View {
        HStack {
            if location.denied {
                Label("Location is off for this app: turn it on in Settings", systemImage: "location.slash")
                    .foregroundStyle(.orange)
            } else if let fix = location.latest {
                Label(String(format: "GPS ±%.0f m", fix.horizontalAccuracy), systemImage: "location.fill")
                    .foregroundStyle(fix.horizontalAccuracy < 10 ? .green : .yellow)
                Spacer()
                Text(DisplayText.speed(kmh: max(fix.speed, 0) * 3.6, miles: miles)).monospacedDigit()
            } else {
                Label("Finding GPS…", systemImage: "location")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    // MARK: Running

    private func running(_ timer: LapTimer) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(timer.lapStart == nil ? "Cross the line to start" : "Lap \(timer.laps.count + 1)")
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1.5)
                    .foregroundStyle(.orange)
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    Text(DisplayText.seconds(timer.elapsed(at: context.date) ?? 0))
                        .font(.system(size: 76, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                if let delta = timer.delta {
                    Text(String(format: "%+.2f s", delta))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(delta <= 0 ? .green : .red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background((delta <= 0 ? Color.green : Color.red).opacity(0.18), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            HStack(spacing: 10) {
                summary("Last", timer.laps.last)
                summary("Best", timer.best)
            }
            gpsStatus
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !timer.laps.isEmpty {
                LapList(laps: timer.laps, miles: miles)
            }
            Button(role: .destructive) {
                end()
            } label: {
                Text("End session").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    private func summary(_ title: String, _ lap: Lap?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(lap.map { DisplayText.seconds($0.seconds) } ?? "–")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func end() {
        if let timer, let started {
            let name = started.formatted(date: .abbreviated, time: .shortened)
            store.add(LapSession(date: started, name: name, line: timer.line, laps: timer.laps))
        }
        timer = nil
        started = nil
    }

    // MARK: Past sessions

    @ViewBuilder
    private var sessions: some View {
        if !store.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions").font(.headline)
                ForEach(store.sessions.reversed()) { session in
                    NavigationLink {
                        ScrollView {
                            LapList(laps: session.laps, miles: miles).padding(16)
                        }
                        .background(Color.black)
                        .navigationTitle(session.name)
                        .toolbar {
                            ToolbarItem(placement: .destructiveAction) {
                                Button("Delete", role: .destructive) { store.deleteSessions([session.id]) }
                            }
                        }
                    } label: {
                        ToolRow(
                            title: session.name,
                            detail: "\(session.laps.count) laps · best \(session.best.map { DisplayText.seconds($0.seconds) } ?? "–")",
                            systemImage: "stopwatch", tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct LapList: View {
    let laps: [Lap]
    let miles: Bool

    var body: some View {
        let best = laps.min { $0.seconds < $1.seconds }?.number
        VStack(spacing: 0) {
            ForEach(laps.reversed()) { lap in
                HStack {
                    Text("Lap \(lap.number)").fontWeight(.medium)
                    if lap.number == best { Image(systemName: "trophy.fill").foregroundStyle(.yellow).font(.caption) }
                    Spacer()
                    Text("top " + DisplayText.speed(kmh: lap.topKmh, miles: miles)).font(.caption).foregroundStyle(.secondary)
                    Text(DisplayText.seconds(lap.seconds))
                        .fontWeight(.semibold)
                        .frame(minWidth: 80, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                if lap.number != laps.first?.number { Divider().padding(.leading, 12) }
            }
        }
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
