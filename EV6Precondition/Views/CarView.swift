import PreconditionKit
import SwiftUI

/// The dashboard (HANDOVER.md §6.1).
struct CarView: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(model.banners.enumerated()), id: \.offset) { _, banner in
                        BannerView(banner: banner)
                    }
                    HeroCard(snapshot: model.snapshot, now: model.now)
                    ClimateCard()
                    AutomationCard()
                    if let message = model.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("My EV6")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.busy == .refreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.busy != nil)
                    }
                }
            }
        }
    }
}

// MARK: - Banners

private struct BannerView: View {
    @Environment(CarModel.self) private var model
    let banner: CarModel.Banner

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.subheadline)
                if case .paused = banner {
                    Button("Resume automation") {
                        Task { await model.resumeAutomation() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var text: String {
        switch banner {
        case .setupNeeded: return "Add your Kia Connect refresh token in Settings to connect your car."
        case .authStopped(let reason): return reason
        case .paused(let reason): return reason.capitalizingFirst
        case .fakeMode: return "Fake car: nothing is sent to Kia. Turn it off in Settings › Developer."
        }
    }

    private var icon: String {
        switch banner {
        case .setupNeeded: return "key.fill"
        case .authStopped: return "exclamationmark.octagon.fill"
        case .paused: return "pause.circle.fill"
        case .fakeMode: return "hammer.fill"
        }
    }

    private var tint: Color {
        switch banner {
        case .authStopped: return Brand.red
        case .paused: return Brand.amber
        case .setupNeeded, .fakeMode: return .accentColor
        }
    }
}

// MARK: - Battery

private struct HeroCard: View {
    let snapshot: VehicleSnapshot?
    let now: Date

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(Brand.cyan, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(135))
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(snapshot?.socPercent.map { String($0) } ?? "–")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                        Text("%").font(.title3.weight(.semibold))
                    }
                    Text(snapshot?.rangeKm.map { "\($0) km range" } ?? "range unknown")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)

            if let snapshot, let charging = DisplayText.charging(snapshot) {
                Chip(text: charging, systemImage: snapshot.chargingState == .charging ? "bolt.fill" : "powerplug.fill")
            }
            Text(ageText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Brand.midnight, Brand.midnightLight], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var fraction: Double {
        Double(min(max(snapshot?.socPercent ?? 0, 0), 100)) / 100
    }

    /// We never wake the car, so its data can be old; say how old (HANDOVER.md §3.7).
    private var ageText: String {
        guard let snapshot else { return "No data yet. Pull down to read the car." }
        let reported = snapshot.carCapturedAt.map { "car reported \(DisplayText.age(of: $0, now: now))" }
        let fetched = "read \(DisplayText.age(of: snapshot.fetchedAt, now: now))"
        return [reported, fetched].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        guard let soc = snapshot?.socPercent else { return "Battery unknown" }
        return "Battery \(soc) percent" + (snapshot?.rangeKm.map { ", \($0) kilometres range" } ?? "")
    }
}

// MARK: - Climate

private struct ClimateCard: View {
    @Environment(CarModel.self) private var model
    @State private var target: Double?

    private var shownTarget: Double { target ?? model.settings.defaultTargetC }
    private var running: Bool { model.snapshot?.climate == .running }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Climate").font(.headline)
                Spacer()
                if running {
                    Chip(text: "Running" + (model.snapshot?.targetTempC.map { " to \(Describe.temp($0))" } ?? ""), systemImage: "thermometer.medium")
                }
            }
            HStack {
                stepButton("minus", delta: -0.5)
                Spacer()
                VStack(spacing: 0) {
                    Text(Describe.temp(shownTarget))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("target").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                stepButton("plus", delta: 0.5)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await model.start(targetC: shownTarget) }
                } label: {
                    label(model.busy == .starting ? nil : "Start", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.stop() }
                } label: {
                    label(model.busy == .stopping ? nil : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(model.busy != nil)

            if let outside = model.snapshot?.outsideTempC {
                HStack {
                    Label("Outside", systemImage: "thermometer")
                    Spacer()
                    Text(Describe.temp(outside) + " · car sensor")
                }
                .font(.subheadline)
            }
        }
        .card()
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let next = shownTarget + delta
            target = min(max(next, AppSettings.minTargetC), AppSettings.maxTargetC)
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Lower target" : "Raise target")
    }

    @ViewBuilder
    private func label(_ text: String?, systemImage: String) -> some View {
        if let text {
            Label(text, systemImage: systemImage).frame(maxWidth: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Automation and budget

private struct AutomationCard: View {
    @Environment(CarModel.self) private var model
    @Environment(RulesModel.self) private var rules

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automation").font(.headline)
            Toggle(isOn: Binding(
                get: { model.settings.automationPaused },
                set: { paused in Task { await model.updateSettings { $0.automationPaused = paused } } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause automation")
                    Text("Rules keep logging but never send commands").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let next = rules.nextCheck {
                HStack {
                    Label("Next scheduled check", systemImage: "calendar")
                    Spacer()
                    Text(next.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
                .font(.subheadline)
            }
            if let last = model.automation.lastCommand {
                HStack {
                    Label("Last command", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(last.description.capitalizingFirst), \(DisplayText.age(of: last.at, now: model.now))")
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
            Divider()
            if let budget = model.budget {
                HStack {
                    Text("Requests in the last 24 h").font(.subheadline)
                    Spacer()
                    Text("\(budget.remaining) of \(budget.limit) left").font(.subheadline.weight(.semibold))
                }
                ProgressView(value: Double(budget.remaining), total: Double(max(budget.limit, 1)))
                    .tint(budget.exhaustedUntil == nil ? Brand.cyan : Brand.red)
                Text(DisplayText.budget(budget))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}
