import PreconditionKit
import SwiftUI

/// The dashboard (HANDOVER.md §6.1), as a native grouped list.
struct CarView: View {
    @Environment(CarModel.self) private var model
    @Environment(RulesModel.self) private var rules
    @State private var target: Double?

    private var shownTarget: Double { target ?? model.settings.defaultTargetC }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.banners.enumerated()), id: \.offset) { _, banner in
                    Section { BannerRow(banner: banner) }
                }

                Section {
                    BatteryHeader(snapshot: model.snapshot)
                } footer: {
                    Text(ageText)
                }

                climateSection
                automationSection
                requestsSection
            }
            .listStyle(.insetGrouped)
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

    /// We never wake the car, so its data can be old; say how old (HANDOVER.md §3.7).
    private var ageText: String {
        guard let snapshot = model.snapshot else { return "No data yet. Pull down to read the car." }
        let fetched = "Read \(DisplayText.age(of: snapshot.fetchedAt, now: model.now))"
        guard let reported = snapshot.carCapturedAt else { return fetched }
        return "\(fetched) · car reported \(DisplayText.age(of: reported, now: model.now))"
    }

    // MARK: Climate

    private var climateStatus: String {
        guard let v = model.snapshot else { return "Unknown" }
        switch v.climate {
        case .running: return v.targetTempC.map { "On · \(Describe.temp($0))" } ?? "On"
        case .off: return "Off"
        case .unknown: return "Unknown"
        }
    }

    private var climateSection: some View {
        Section {
            LabeledContent("Status", value: climateStatus)
            Stepper(
                value: Binding(get: { shownTarget }, set: { target = $0 }),
                in: AppSettings.minTargetC...AppSettings.maxTargetC,
                step: 0.5
            ) {
                LabeledContent("Target", value: Describe.temp(shownTarget))
            }
            if let outside = model.snapshot?.outsideTempC {
                LabeledContent("Outside", value: Describe.temp(outside))
            }
            actionButton("Start Climate", systemImage: "fan", busy: .starting) {
                await model.start(targetC: shownTarget)
            }
            actionButton("Stop Climate", systemImage: "stop.circle", busy: .stopping) {
                await model.stop()
            }
        } header: {
            Text("Climate")
        } footer: {
            if let message = model.message {
                Text(message)
            } else {
                Text("Commands reach the car within a minute. Climate never starts below the minimum charge unless the car is plugged in.")
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, busy: CarModel.Busy, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if model.busy == busy { ProgressView() }
            }
        }
        .disabled(model.busy != nil)
    }

    // MARK: Automation

    private var automationSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !model.settings.automationPaused },
                set: { on in Task { await model.updateSettings { $0.automationPaused = !on } } }
            )) {
                Label("Automation", systemImage: "wand.and.stars")
            }
            if let next = rules.nextCheck {
                LabeledContent("Next scheduled check") {
                    Text(next.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
            }
            if let last = model.automation.lastCommand {
                LabeledContent("Last command") {
                    Text("\(last.description.capitalizingFirst), \(DisplayText.age(of: last.at, now: model.now))")
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            if model.settings.automationPaused {
                Text("Paused: rules keep logging what they would do, but never send commands.")
            }
        }
    }

    // MARK: Requests

    private var requestsSection: some View {
        Section {
            if let budget = model.budget {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Requests left", value: "\(budget.remaining) of \(budget.limit)")
                    ProgressView(value: Double(budget.remaining), total: Double(max(budget.limit, 1)))
                        .tint(budget.exhaustedUntil == nil ? Color.accentColor : .red)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Kia requests, last 24 h")
        } footer: {
            if let budget = model.budget {
                Text(DisplayText.budget(budget))
            }
        }
    }
}

// MARK: - Battery

private struct BatteryHeader: View {
    let snapshot: VehicleSnapshot?

    private var soc: Int? { snapshot?.socPercent }

    /// iOS battery colours: green, then yellow below 50 %, red below 20 %.
    private var tint: Color {
        guard let soc else { return .secondary }
        if soc < 20 { return .red }
        if soc < 50 { return .yellow }
        return .green
    }

    private var symbol: String {
        switch snapshot?.chargingState {
        case .charging?: return "bolt.fill"
        case .pluggedIn?: return "powerplug.fill"
        default: return "car.side.fill"
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color(.systemFill), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: Double(min(max(soc ?? 0, 0), 100)) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            .frame(width: 88, height: 88)
            .animation(.easeInOut, value: soc)

            VStack(alignment: .leading, spacing: 4) {
                Text(soc.map { "\($0)%" } ?? "–")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(snapshot?.rangeKm.map { "\($0) km range" } ?? "Range unknown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let snapshot, let charging = DisplayText.charging(snapshot) {
                    Text(charging)
                        .font(.subheadline)
                        .foregroundStyle(snapshot.chargingState == .charging ? Color.green : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let soc else { return "Battery unknown" }
        return "Battery \(soc) percent" + (snapshot?.rangeKm.map { ", \($0) kilometres range" } ?? "")
    }
}

// MARK: - Banners

private struct BannerRow: View {
    @Environment(CarModel.self) private var model
    let banner: CarModel.Banner

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text).font(.subheadline)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            if case .paused = banner {
                Button("Resume Automation") {
                    Task { await model.resumeAutomation() }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    private var text: String {
        switch banner {
        case .setupNeeded: return "Add your Kia Connect refresh token in Settings to connect your car."
        case .authStopped(let reason): return reason
        case .paused(let reason): return reason.capitalizingFirst
        case .fakeMode: return "Fake car on. Nothing is sent to Kia."
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
        case .authStopped: return .red
        case .paused: return .orange
        case .setupNeeded, .fakeMode: return .accentColor
        }
    }
}
