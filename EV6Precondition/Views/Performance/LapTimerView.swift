import CoreLocation
import PreconditionKit
import SwiftUI
import UIKit

/// GPS lap timing: arm the start/finish line while stopped on it, and it is set as you drive off. Every crossing after that is a lap.
struct LapTimerView: View {
    @Environment(RunStore.self) private var store
    @Environment(Preferences.self) private var prefs
    /// Made on first appearance, not in init: the parent rebuilds this view on every speed sample.
    @State private var model: LapSessionModel?

    private var miles: Bool { prefs.useMiles }
    private var location: LapLocation? { model?.location }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let timer = model?.timer {
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
        // While a session runs, End session is the way out, so its laps are always saved.
        .navigationBarBackButtonHidden(model?.timer != nil)
        .onAppear {
            let model = self.model ?? LapSessionModel()
            self.model = model
            model.location.start()
            ScreenAwake.hold(model.awakeReason)
        }
        .onDisappear {
            // Switching tabs keeps an armed line or a running session going (GPS and screen on).
            guard let model, model.timer == nil, !model.armed else { return }
            model.location.stop()
            ScreenAwake.release(model.awakeReason)
        }
        .sensoryFeedback(.success, trigger: model?.flash)
        .sensoryFeedback(.start, trigger: model?.started)
    }

    // MARK: Setup

    private var canArm: Bool {
        guard let location, !location.denied else { return false }
        return location.latest != nil
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Image(systemName: "flag.pattern.checkered.2.crossed")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .padding(.top, 8)
            Text("Stop on your start/finish line and tap Arm. The line is set as you drive off, facing the way you go. Every time you cross it the same way after that is a lap.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Closed circuits only, never on public roads. Mount your phone before you set off and don't touch it while driving.")
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.orange)
            gpsStatus
            if model?.armed == true {
                Label("Armed: drive off across the line", systemImage: "flag.checkered")
                    .font(.title3.weight(.heavy))
                    .textCase(.uppercase)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 58)
                Text("The line is set once you pass \(DisplayText.speed(kmh: LapSessionModel.lineSpeed * 3.6, miles: miles)) with a good GPS signal.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Cancel") { model?.armed = false }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            } else {
                Button {
                    model?.armed = true
                } label: {
                    Label("Arm line", systemImage: "flag.checkered")
                        .font(.title3.weight(.heavy))
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.orange)
                .disabled(!canArm)
                if !canArm, location?.denied != true {
                    Text("Waiting for GPS…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var gpsStatus: some View {
        HStack {
            if location?.denied == true {
                Label("Location is off for this app: turn it on in Settings", systemImage: "location.slash")
                    .foregroundStyle(.orange)
            } else if let fix = location?.latest {
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
        guard let model else { return }
        model.save()
        model.timer = nil
        model.started = nil
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

/// One lap session's GPS and timer. A class, so a tab switch doesn't lose it and its GPS callback needn't hold the view.
@MainActor
@Observable
private final class LapSessionModel {
    /// Speed (m/s) the car must be doing, with a good course, for a fix to set the line.
    static let lineSpeed = 3.0

    let location = LapLocation()
    /// Waiting for the first good moving fix to set the line.
    var armed = false
    var timer: LapTimer?
    var started: Date?
    var flash: Lap?
    /// The session's id in the store, kept so each lap updates the same saved session.
    private var sessionId = UUID()
    /// This screen's claim on keeping the display awake.
    let awakeReason = "lap " + UUID().uuidString

    init() {
        location.onFix = { [weak self] fix in self?.add(fix) }
    }

    deinit {
        // Popped without End session (tapping the tab again pops to the root): let the screen sleep again.
        let reason = awakeReason
        Task { @MainActor in ScreenAwake.release(reason) }
    }

    /// Saves the session as it stands (after every lap, and at the end), so its laps survive the
    /// screen being popped or the app being stopped.
    func save() {
        guard let timer, let started, !timer.laps.isEmpty else { return }
        let name = started.formatted(date: .abbreviated, time: .shortened)
        RunStore.shared.upsert(LapSession(id: sessionId, date: started, name: name, line: timer.line, laps: timer.laps))
    }

    private func add(_ fix: CLLocation) {
        if armed {
            guard fix.course >= 0, fix.speed > Self.lineSpeed, fix.horizontalAccuracy < 20 else { return }
            armed = false
            // This fix is on the line: the first lap runs from it.
            timer = LapTimer(line: FinishLine(centre: fix.geoPoint, heading: fix.course), startedAt: fix.timestamp)
            started = fix.timestamp
            sessionId = UUID()
            return
        }
        guard timer != nil else { return }
        // A poor fix can jump across the line: leave it out.
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 20 else { return }
        let kmh = fix.speed >= 0 ? fix.speed * 3.6 : nil
        if let lap = timer?.add(at: fix.timestamp, point: fix.geoPoint, kmh: kmh, course: fix.course >= 0 ? fix.course : nil) {
            flash = lap
            save()
        }
    }
}
