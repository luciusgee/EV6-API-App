import PreconditionKit
import SwiftUI

/// The dashboard (HANDOVER.md §6.1): the car, its controls and its health, as a native grouped list.
struct CarView: View {
    @Environment(CarModel.self) private var model
    @Environment(RulesModel.self) private var rules
    @Environment(ChargingModel.self) private var chargingModel
    @AppStorage(CarPaint.storageKey) private var paint: CarPaint = .runwayRed
    @State private var target: Double?
    @State private var confirmUnlock = false
    @State private var editingLimits = false

    private var shownTarget: Double { target ?? model.settings.defaultTargetC }
    private var snapshot: VehicleSnapshot? { model.snapshot }
    private var details: VehicleDetails? { snapshot?.details }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.banners.enumerated()), id: \.offset) { _, banner in
                    Section { BannerRow(banner: banner) }
                }

                Section {
                    HeroCard(snapshot: snapshot, paint: paint, miles: model.settings.useMiles)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text(ageText)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                Section {
                    controls
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    if let message = model.message {
                        Text(message)
                    }
                }

                if let alerts = details?.alerts, !alerts.isEmpty {
                    Section {
                        ForEach(alerts, id: \.self) { alert in
                            Label(alert, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                climateSection
                vehicleSection
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
            .confirmationDialog("Unlock the car?", isPresented: $confirmUnlock, titleVisibility: .visible) {
                Button("Unlock") { Task { await model.send(.unlock) } }
            } message: {
                Text("The doors unlock remotely. The car locks itself again if no door is opened.")
            }
            .sheet(isPresented: $editingLimits) {
                ChargeLimitSheet(ac: details?.chargeLimitAC ?? 80, dc: details?.chargeLimitDC ?? 80)
            }
        }
    }

    /// We never wake the car, so its data can be old; say how old (HANDOVER.md §3.7).
    private var ageText: String {
        guard let snapshot else { return "No data yet. Pull down to read the car." }
        let fetched = "Read \(DisplayText.age(of: snapshot.fetchedAt, now: model.now))"
        guard let reported = snapshot.carCapturedAt else { return fetched }
        return "\(fetched) · car reported \(DisplayText.age(of: reported, now: model.now))"
    }

    // MARK: Controls

    private var climateOn: Bool { snapshot?.climate == .running }
    private var charging: Bool { snapshot?.chargingState == .charging }
    private var pluggedIn: Bool { snapshot?.pluggedIn == true }

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ControlTile(
                title: "Climate",
                subtitle: waiting(["climatise", "stop climatisation"]) ? "Waiting for car…" : (climateOn ? (snapshot?.targetTempC.map { "On · \(Describe.temp($0))" } ?? "On") : "Off"),
                systemImage: climateOn ? "fan.fill" : "fan",
                tint: .orange,
                active: climateOn,
                busy: model.busy == .starting || model.busy == .stopping || waiting(["climatise", "stop climatisation"])
            ) {
                Task { climateOn ? await model.stop() : await model.start(targetC: shownTarget) }
            }
            ControlTile(
                title: details?.locked == false ? "Unlocked" : "Locked",
                subtitle: waiting(["lock the car", "unlock the car"]) ? "Waiting for car…" : (details?.locked == nil ? "Unknown" : (details?.locked == true ? "Tap to unlock" : "Tap to lock")),
                systemImage: details?.locked == false ? "lock.open.fill" : "lock.fill",
                tint: details?.locked == false ? .red : .blue,
                active: details?.locked == false,
                busy: model.busy == .command(.lock) || model.busy == .command(.unlock) || waiting(["lock the car", "unlock the car"])
            ) {
                if details?.locked == false {
                    Task { await model.send(.lock) }
                } else {
                    confirmUnlock = true
                }
            }
            ControlTile(
                title: "Charging",
                subtitle: waiting(["start charging", "stop charging"]) ? "Waiting for car…" : (charging ? (snapshot?.chargePowerKw.map { String(format: "%.1f kW", $0) } ?? "On") : (pluggedIn ? "Paused" : "Unplugged")),
                systemImage: charging ? "bolt.fill" : (pluggedIn ? "powerplug.fill" : "powerplug"),
                tint: .green,
                active: charging,
                busy: model.busy == .command(.startCharging) || model.busy == .command(.stopCharging) || waiting(["start charging", "stop charging"])
            ) {
                Task { await model.send(charging ? .stopCharging : .startCharging) }
            }
            .disabled(!pluggedIn)
            ControlTile(
                title: "Charge limit",
                subtitle: limitsText,
                systemImage: "gauge.with.dots.needle.67percent",
                tint: .teal,
                active: false,
                busy: settingLimits
            ) {
                editingLimits = true
            }
        }
        .disabled(model.busy != nil && model.busy != .refreshing)
    }

    /// Whether a command starting with one of `prefixes` is waiting for the car to confirm.
    private func waiting(_ prefixes: [String]) -> Bool {
        guard let c = model.confirming else { return false }
        return prefixes.contains { c.hasPrefix($0) }
    }

    private var settingLimits: Bool {
        if case .command(.setChargeLimits)? = model.busy { return true }
        return waiting(["set charge limits"])
    }

    private var limitsText: String {
        switch (details?.chargeLimitAC, details?.chargeLimitDC) {
        case let (ac?, dc?): return "AC \(ac)% · DC \(dc)%"
        case let (ac?, nil): return "AC \(ac)%"
        default: return "Set limits"
        }
    }

    // MARK: Climate

    private var climateSection: some View {
        Section {
            RoundStepper(
                "Temperature",
                value: Binding(get: { shownTarget }, set: { target = $0 }),
                in: AppSettings.minTargetC...AppSettings.maxTargetC,
                step: 0.5,
                tint: shownTarget >= 20 ? .orange : .cyan
            ) { Describe.temp($0) }
            if let outside = snapshot?.outsideTempC {
                LabeledContent("Outside", value: Describe.temp(outside))
            }
            Toggle(isOn: setting(\.climateDefrost)) {
                Label("Windscreen defrost", systemImage: "windshield.front.and.heat.waves")
            }
            Toggle(isOn: setting(\.climateHeatedExtras)) {
                Label("Heated wheel & mirrors", systemImage: "steeringwheel")
            }
            Toggle(isOn: setting(\.holdChargerOnClimate)) {
                Label("Keep charger off", systemImage: "powerplug")
            }
        } header: {
            Text("Climate")
        } footer: {
            Text("Keep charger off: when the car is plugged in but not charging (done, or waiting for off-peak), the app stops the charger before starting climate, so preconditioning never starts a peak-rate charge. A charge that's already running is left alone.")
        }
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } }
        )
    }

    // MARK: Vehicle

    private var vehicleSection: some View {
        Section {
            NavigationLink {
                ChargingView()
            } label: {
                LabeledContent {
                    Text(chargingModel.plan.map { "\($0.start.formatted(date: .omitted, time: .shortened))" }
                        ?? chargingModel.monthly.first.map { DisplayText.money(pence: $0.totals.costPence) } ?? "")
                } label: {
                    Label("Charging & costs", systemImage: "bolt.batteryblock")
                }
            }
            NavigationLink {
                ChargersView(near: snapshot?.parkingPosition)
            } label: {
                Label("Chargers nearby", systemImage: "ev.charger")
            }
            NavigationLink {
                EnergyView()
            } label: {
                LabeledContent {
                    Text(DisplayText.efficiency(kWhPer100km: model.energy?.kWhPer100km, miles: model.settings.useMiles) ?? "")
                } label: {
                    Label("Energy", systemImage: "chart.bar.xaxis")
                }
            }
            NavigationLink {
                BatteryHealthView()
            } label: {
                LabeledContent {
                    Text(details?.batteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? "")
                } label: {
                    Label("Battery health", systemImage: "battery.100percent.bolt")
                }
            }
            if let odometer = details?.odometerKm {
                LabeledContent {
                    Text(DisplayText.distance(km: odometer, miles: model.settings.useMiles))
                } label: {
                    Label("Odometer", systemImage: "road.lanes")
                }
            }
            if let aux = details?.auxBatteryPercent {
                LabeledContent {
                    Text("\(aux)%").foregroundStyle(aux < 60 ? .orange : .secondary)
                } label: {
                    Label("12 V battery", systemImage: "minus.plus.batteryblock")
                }
            }
            if let details {
                LabeledContent {
                    Text(details.tyreWarning == true || !details.tyreWarnings.isEmpty ? "Check pressure" : "OK")
                        .foregroundStyle(details.tyreWarning == true || !details.tyreWarnings.isEmpty ? .orange : .secondary)
                } label: {
                    Label("Tyres", systemImage: "tirepressure")
                }
                LabeledContent {
                    Text(openingsText(details))
                } label: {
                    Label("Doors & windows", systemImage: "car.side")
                }
            }
        } header: {
            Text("Vehicle")
        }
    }

    private func openingsText(_ d: VehicleDetails) -> String {
        var open = d.openDoors.count + d.openWindows.count
        if d.trunkOpen == true { open += 1 }
        if d.hoodOpen == true { open += 1 }
        return open == 0 ? "All closed" : "\(open) open"
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

// MARK: - Hero

private struct HeroCard: View {
    let snapshot: VehicleSnapshot?
    let paint: CarPaint
    let miles: Bool

    private var soc: Int? { snapshot?.socPercent }

    /// iOS battery colours: green, then yellow below 50 %, red below 20 %.
    private var tint: Color {
        guard let soc else { return .secondary }
        if soc < 20 { return .red }
        if soc < 50 { return .yellow }
        return .green
    }

    private var glow: EV6Illustration.ClimateGlow? {
        guard snapshot?.climate == .running else { return nil }
        if let target = snapshot?.targetTempC, let outside = snapshot?.outsideTempC, outside > target { return .cooling }
        return .heating
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                KiaLogo()
                    .frame(width: 58, height: 14)
                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 16)
                Text("EV6")
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(3)
                Text("GT-LINE AWD")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            CarHeroImage(
                paint: paint,
                charging: snapshot?.chargingState == .charging,
                pluggedIn: snapshot?.pluggedIn == true,
                climate: glow
            )
            .padding(.horizontal, 8)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(soc.map { "\($0)" } ?? "–")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot?.rangeKm.map { DisplayText.distance(km: Double($0), miles: miles) } ?? "–")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("range")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            BatteryBar(fraction: Double(soc ?? 0) / 100, tint: tint, limit: snapshot?.details?.chargeLimitAC)

            HStack(spacing: 8) {
                if let snapshot, let charging = DisplayText.charging(snapshot) {
                    Chip(text: charging, systemImage: snapshot.chargingState == .charging ? "bolt.fill" : "powerplug", tint: snapshot.chargingState == .charging ? .green : .secondary)
                }
                if let locked = snapshot?.details?.locked {
                    Chip(text: locked ? "Locked" : "Unlocked", systemImage: locked ? "lock.fill" : "lock.open.fill", tint: locked ? .secondary : .red)
                }
                if snapshot?.climate == .running {
                    Chip(text: "Climate on", systemImage: "fan.fill", tint: .orange)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut, value: soc)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let soc else { return "Battery unknown" }
        return "Battery \(soc) percent" + (snapshot?.rangeKm.map { ", \(DisplayText.distance(km: Double($0), miles: miles)) range" } ?? "")
    }
}

private struct BatteryBar: View {
    let fraction: Double
    let tint: Color
    /// The AC charge limit, marked on the bar.
    let limit: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                if let limit, limit < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: geo.size.width * Double(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 10)
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

// MARK: - Control tiles

/// A Control Center–style button: icon, name and state; filled with its colour when on.
private struct ControlTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let active: Bool
    let busy: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle().fill(active ? Color.white.opacity(0.25) : tint.opacity(0.15))
                        if busy {
                            ProgressView().tint(active ? .white : tint)
                        } else {
                            Image(systemName: systemImage)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(active ? .white : tint)
                                .symbolEffect(.pulse, isActive: active)
                        }
                    }
                    .frame(width: 38, height: 38)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(active ? .white : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
            )
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: active)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

// MARK: - Charge limits

private struct ChargeLimitSheet: View {
    @Environment(CarModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var ac: Int
    @State var dc: Int

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    limitRow("AC (home, public AC)", value: $ac, systemImage: "powerplug")
                    limitRow("DC (rapid chargers)", value: $dc, systemImage: "bolt.car")
                } footer: {
                    Text("Where charging stops. 80% is kinder to the battery day to day; 100% before a long trip. The car accepts steps of 10%.")
                }
            }
            .navigationTitle("Charge limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let (a, d) = (ac, dc)
                        dismiss()
                        Task { await model.send(.setChargeLimits(ac: a, dc: d)) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func limitRow(_ title: String, value: Binding<Int>, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text("\(value.wrappedValue)%").monospacedDigit().font(.headline)
            } label: {
                Label(title, systemImage: systemImage)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                in: 50...100,
                step: 10
            )
        }
        .padding(.vertical, 4)
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
        case .setupNeeded: return "Sign in with your Kia account in Settings to connect your car."
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
