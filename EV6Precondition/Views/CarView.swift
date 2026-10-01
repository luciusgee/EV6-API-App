import PreconditionKit
import SwiftUI

/// The dashboard (HANDOVER.md §6.1): the car, its controls and its health, as a native grouped list.
struct CarView: View {
    @Environment(CarModel.self) private var model
    @Environment(RulesModel.self) private var rules
    @Environment(ChargingModel.self) private var chargingModel
    @AppStorage(CarPaint.storageKey) private var paint: CarPaint = .runwayRed
    @State private var target: Double?
    /// The weather where the car's parked, when the car doesn't report an outside temperature.
    @State private var weatherC: Double?
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

                // A normal refresh has the pull-down spinner; waking the car takes long enough to explain.
                if model.busy == .refreshing && model.waking {
                    Section { RefreshingRow(waking: true, since: model.refreshStartedAt ?? .now) }
                }

                Section {
                    HeroCard(snapshot: snapshot, paint: paint, miles: model.settings.useMiles, outsideC: outsideC)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text(greeting)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .contentTransition(.opacity)
                } footer: {
                    Text(ageText)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                Section {
                    controls
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
                chargingSection
                statusSection
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: model.busy == .refreshing && model.waking)
            .safeAreaInset(edge: .bottom) {
                StatusToast(confirming: model.confirming, message: model.message)
                    .padding(.bottom, 6)
            }
            .sensoryFeedback(.success, trigger: model.message) { _, new in new?.hasPrefix("✓") == true }
            .navigationTitle("My EV6")
            .refreshable { await model.refresh() }
            // The temperature where the car is, so it's clear at a glance whether to heat or cool.
            .task(id: snapshot?.parkingPosition.map { "\($0.lat),\($0.lon)" }) {
                guard snapshot?.outsideTempC == nil, let p = snapshot?.parkingPosition else { return }
                weatherC = await AppServices.shared.container.weather.current(at: p)?.celsius
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.busy == .refreshing {
                        ProgressView()
                    } else {
                        // Tap to refresh; press and hold for a refresh straight from the car.
                        Menu {
                            Button {
                                Task { await model.refresh() }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Button {
                                Task { await model.refresh(wake: true) }
                            } label: {
                                Label("Refresh from the car (slower)", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        } primaryAction: {
                            Task { await model.refresh() }
                        }
                        .disabled(model.busy != nil)
                    }
                }
            }
            .confirmationDialog("Unlock the car?", isPresented: $confirmUnlock, titleVisibility: .visible) {
                Button("Unlock") { Task { await model.send(.unlock) } }
            } message: {
                Text("It locks itself again if no door is opened.")
            }
            .sheet(isPresented: $editingLimits) {
                ChargeLimitSheet(ac: details?.chargeLimitAC ?? 80, dc: details?.chargeLimitDC ?? 80)
            }
        }
    }

    /// "Good evening · Charging, full by 01:30": a friendly line about what the car's up to.
    /// Outside where the car is: the car's own sensor, else the weather there.
    private var outsideC: Double? { snapshot?.outsideTempC ?? weatherC }

    private var outsideText: String? { outsideC.map { "\(Int($0.rounded())) °C outside" } }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: model.now)
        let hello = hour < 5 ? "Hello" : (hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening"))
        guard let s = snapshot else { return hello }
        let mood: String
        if s.climate == .running {
            let target = s.targetTempC.map { " to \(Describe.temp($0))" } ?? ""
            mood = DisplayText.isCooling(targetC: s.targetTempC ?? 21, outsideC: outsideC) ? "Cooling down\(target)" : "Warming up\(target)"
        } else if s.chargingState == .charging {
            if let m = s.minutesToFullyCharged, m > 0 {
                mood = "Charging, done by \((s.carCapturedAt ?? s.fetchedAt).addingTimeInterval(Double(m) * 60).formatted(date: .omitted, time: .shortened))"
            } else {
                mood = "Charging"
            }
        } else if s.details?.locked == false {
            mood = "Unlocked"
        } else if s.pluggedIn == true {
            mood = "Plugged in"
        } else if let soc = s.socPercent, soc < 20 {
            mood = "Running low"
        } else {
            mood = "Parked" + (s.details?.locked == true ? " and locked" : "")
        }
        return [hello, outsideC.map { "\(Int($0.rounded())) °C" }, mood].compactMap { $0 }.joined(separator: " · ")
    }

    /// We never wake the car, so its data can be old; say how old (HANDOVER.md §3.7).
    private var ageText: String {
        guard let snapshot else { return "No data yet. Pull down to refresh." }
        let fetched = "Updated \(DisplayText.age(of: snapshot.fetchedAt, now: model.now))"
        guard let reported = snapshot.carCapturedAt, snapshot.fetchedAt.timeIntervalSince(reported) > 5 * 60 else { return fetched }
        return "\(fetched) · car last reported \(DisplayText.age(of: reported, now: model.now))"
    }

    // MARK: Controls

    private var climateOn: Bool { snapshot?.climate == .running }
    private var charging: Bool { snapshot?.chargingState == .charging }
    private var pluggedIn: Bool { snapshot?.pluggedIn == true }

    private var controls: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ControlTile(
                title: "Climate",
                subtitle: waiting(["climatise", "stop climatisation"]) ? "Waiting for car…" : (snapshot == nil ? "–" : (climateOn ? (snapshot?.targetTempC.map { "On · \(Describe.temp($0))" } ?? "On") : (outsideText.map { "Off · \($0)" } ?? "Off · \(Describe.temp(shownTarget))"))),
                systemImage: climateOn ? "fan.fill" : "fan",
                tint: .orange,
                active: climateOn,
                busy: model.busy == .starting || model.busy == .stopping || waiting(["climatise", "stop climatisation"])
            ) {
                Task { climateOn ? await model.stop() : await model.start(targetC: shownTarget) }
            }
            .disabled(waiting(["climatise", "stop climatisation"]))
            ControlTile(
                title: details?.locked == nil ? "Doors" : (details?.locked == true ? "Locked" : "Unlocked"),
                subtitle: waiting(["lock the car", "unlock the car"]) ? "Waiting for car…" : (details?.locked == nil ? "Unknown · tap to refresh" : (details?.locked == true ? "Tap to unlock" : "Tap to lock")),
                systemImage: details?.locked == false ? "lock.open.fill" : "lock.fill",
                tint: details?.locked == false ? .red : .blue,
                active: details?.locked == false,
                busy: model.busy == .command(.lock) || model.busy == .command(.unlock) || waiting(["lock the car", "unlock the car"])
            ) {
                if details?.locked == nil {
                    Task { await model.refresh() }
                } else if details?.locked == false {
                    Task { await model.send(.lock) }
                } else {
                    confirmUnlock = true
                }
            }
            .disabled(waiting(["lock the car", "unlock the car"]))
            ControlTile(
                title: "Charging",
                subtitle: waiting(["start charging", "stop charging"]) ? "Waiting for car…" : (snapshot == nil ? "–" : (charging ? (snapshot?.chargePowerKw.map { String(format: "%.1f kW", $0) } ?? "On") : (pluggedIn ? "Plugged in · tap to charge" : "Unplugged"))),
                systemImage: charging ? "bolt.fill" : (pluggedIn ? "powerplug.fill" : "powerplug"),
                tint: .green,
                active: charging,
                busy: model.busy == .command(.startCharging) || model.busy == .command(.stopCharging) || waiting(["start charging", "stop charging"])
            ) {
                Task { await model.send(charging ? .stopCharging : .startCharging) }
            }
            .disabled(!pluggedIn || waiting(["start charging", "stop charging"]))
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
        // One thing at a time: the car model ignores taps while it's busy, so say so by dimming.
        .disabled(model.busy != nil)
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
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Text(Describe.temp(shownTarget))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(shownTarget >= 20 ? .orange : .cyan)
                } label: {
                    Label("Temperature", systemImage: "thermometer.medium")
                }
                Slider(
                    value: Binding(get: { shownTarget }, set: { target = $0 }),
                    in: AppSettings.minTargetC...AppSettings.maxTargetC,
                    step: 0.5
                ) {
                    Text("Temperature")
                } minimumValueLabel: {
                    Image(systemName: "snowflake").font(.caption.weight(.semibold)).foregroundStyle(.cyan)
                } maximumValueLabel: {
                    Image(systemName: "flame.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } onEditingChanged: { editing in
                    guard !editing else { return }
                    let v = shownTarget
                    Task { await model.updateSettings { $0.defaultTargetC = v } }
                }
                .tint(shownTarget >= 20 ? .orange : .cyan)
            }
            .padding(.vertical, 4)
            if let outside = outsideC {
                LabeledContent("Outside", value: "\(Int(outside.rounded())) °C")
            }
            Toggle(isOn: setting(\.climateDefrost)) {
                Label("Windscreen defrost", systemImage: "windshield.front.and.heat.waves")
            }
            Toggle(isOn: setting(\.climateHeatedExtras)) {
                Label("Heated wheel & mirrors", systemImage: "steeringwheel")
            }
            Toggle(isOn: setting(\.holdChargerOnClimate)) {
                Label("Keep the charger off", systemImage: "powerplug")
            }
        } header: {
            Text("Climate")
        } footer: {
            Text("With the charger kept off, starting climate while plugged in won't also start a charge at peak rates.")
        }
    }

    private func setting(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } }
        )
    }

    // MARK: Charging

    private var chargingSection: some View {
        Section {
            NavigationLink {
                ChargingView()
            } label: {
                LabeledContent {
                    Text(chargingSummary)
                } label: {
                    Label("Charging & costs", systemImage: "bolt.batteryblock")
                }
            }
            NavigationLink {
                OffPeakView(current: details?.offPeak)
            } label: {
                LabeledContent {
                    Text(details?.offPeak.map { $0.text + ($0.onlyOffPeak ? " only" : "") } ?? "")
                } label: {
                    Label("Off-peak charging", systemImage: "moon.stars")
                }
            }
            NavigationLink {
                EnergyView()
            } label: {
                LabeledContent {
                    Text(DisplayText.efficiency(kWhPer100km: model.energy?.kWhPer100km, miles: model.settings.useMiles) ?? "")
                } label: {
                    Label("Energy use", systemImage: "chart.bar.xaxis")
                }
            }
            NavigationLink {
                ChargersView(near: snapshot?.parkingPosition)
            } label: {
                Label("Chargers nearby", systemImage: "ev.charger")
            }
        } header: {
            Text("Charging")
        }
    }

    /// "Smart charge 01:30" while a plan is set, else this month's spend.
    private var chargingSummary: String {
        if let plan = chargingModel.plan {
            return "Smart charge \(plan.start.formatted(date: .omitted, time: .shortened))"
        }
        return chargingModel.monthly.first.map { "\(DisplayText.money(pence: $0.totals.costPence)) this month" } ?? ""
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            NavigationLink {
                BatteryHealthView()
            } label: {
                LabeledContent {
                    Text(details?.batteryHealthPercent.map { String(format: "%.0f%%", $0) } ?? "")
                } label: {
                    Label("Battery health", systemImage: "heart.text.square")
                }
            }
            if let odometer = details?.odometerKm {
                LabeledContent {
                    Text(DisplayText.distance(km: odometer, miles: model.settings.useMiles))
                } label: {
                    Label("Odometer", systemImage: "gauge.with.needle")
                }
            }
            if let aux = details?.auxBatteryPercent {
                LabeledContent {
                    Text("\(aux)%").foregroundStyle(aux < chargingModel.settings.alerts.lowAuxPercent ? .orange : .secondary)
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
            Text("Status")
        }
    }

    private func openingsText(_ d: VehicleDetails) -> String {
        var open = d.openDoors.count + d.openWindows.count
        if d.trunkOpen == true { open += 1 }
        if d.hoodOpen == true { open += 1 }
        return open == 0 ? "All closed" : "\(open) open"
    }
}

// MARK: - Hero

private struct HeroCard: View {
    /// At least as round as iOS's list sections, which clip the card: any tighter and its corners
    /// (and the charging rim) get shaved off.
    static let cornerRadius: CGFloat = 28

    let snapshot: VehicleSnapshot?
    let paint: CarPaint
    let miles: Bool
    /// Outside where the car is (its sensor, else the weather there).
    let outsideC: Double?

    private var soc: Int? { snapshot?.socPercent }

    /// iOS battery colours: green, then yellow below 50 %, red below 20 %.
    private var tint: Color {
        guard let soc else { return .secondary }
        if soc < 20 { return .red }
        if soc < 50 { return .yellow }
        return .green
    }

    private var mood: CarMood {
        if glow == .heating { return .heating }
        if glow == .cooling { return .cooling }
        if snapshot?.chargingState == .charging { return .charging }
        return .idle
    }

    private var glow: EV6Illustration.ClimateGlow? {
        guard snapshot?.climate == .running else { return nil }
        return DisplayText.isCooling(targetC: snapshot?.targetTempC ?? 21, outsideC: outsideC) ? .cooling : .heating
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
            .background { CarStage(mood: mood).padding(.horizontal, -16) }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(soc.map { "\($0)" } ?? "–")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                if snapshot?.chargingState == .charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.green)
                        .shadow(color: .green.opacity(0.7), radius: 6)
                        .symbolEffect(.pulse)
                        .transition(.scale.combined(with: .opacity))
                }
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

            EnergyBar(fraction: Double(soc ?? 0) / 100, tint: tint, limit: snapshot?.details?.chargeLimitAC,
                      charging: snapshot?.chargingState == .charging)

            // One row when everything fits; otherwise the (long) charging chip gets its own row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    chargingChip(fixed: true)
                    otherChips
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    chargingChip(fixed: false)
                    HStack(spacing: 8) {
                        otherChips
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // A rim of the mood's colour while the car's busy doing something.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [mood.colour.opacity(mood == .idle ? 0 : 0.7), mood.colour.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.2
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.6), value: mood)
        .animation(.easeInOut, value: soc)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func chargingChip(fixed: Bool) -> some View {
        if let snapshot, let charging = DisplayText.charging(snapshot) {
            Chip(text: charging, systemImage: snapshot.chargingState == .charging ? "bolt.fill" : "powerplug",
                 tint: snapshot.chargingState == .charging ? .green : .secondary, fixed: fixed)
        }
    }

    @ViewBuilder
    private var otherChips: some View {
        if let locked = snapshot?.details?.locked {
            Chip(text: locked ? "Locked" : "Unlocked", systemImage: locked ? "lock.fill" : "lock.open.fill", tint: locked ? .secondary : .red)
        }
        if snapshot?.climate == .running {
            Chip(text: "Climate on", systemImage: "fan.fill", tint: .orange)
        }
    }

    private var accessibilityText: String {
        guard let soc else { return "Battery unknown" }
        var parts = ["Battery \(soc) percent"]
        if let r = snapshot?.rangeKm { parts.append("\(DisplayText.distance(km: Double(r), miles: miles)) range") }
        if let s = snapshot, let c = DisplayText.charging(s) { parts.append(c) }
        if let locked = snapshot?.details?.locked { parts.append(locked ? "Locked" : "Unlocked") }
        if snapshot?.climate == .running { parts.append("Climate on") }
        return parts.joined(separator: ", ")
    }
}

/// Shown while the app reads the car, so a full refresh (which can take half a minute) is obvious.
private struct RefreshingRow: View {
    let waking: Bool
    let since: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative.reversing)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(waking ? "Waking the car…" : "Refreshing…").font(.headline)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(waking ? "Can take up to 30 seconds · \(seconds) s" : "Checking with Kia · \(seconds) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .transition(.opacity)
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String
    let tint: Color
    /// Full width, never truncated; off, it may wrap onto a second line instead.
    var fixed = true

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(fixed ? 1 : 2)
            .fixedSize(horizontal: fixed, vertical: !fixed)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

// MARK: - Status

/// What just happened, floating over the bottom of the page: a spinner while the car's being asked,
/// then a tick (or a warning) that fades after a few seconds.
private struct StatusToast: View {
    let confirming: String?
    let message: String?
    @State private var shown: String?
    @State private var hideTask: Task<Void, Never>?

    private var waiting: Bool { confirming != nil }
    private var text: String? { confirming.map { "Waiting for the car · \(DisplayText.confirmed($0))" } ?? shown }
    private var good: Bool { text?.hasPrefix("✓") == true }

    var body: some View {
        Group {
            if let text {
                HStack(spacing: 10) {
                    if waiting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(good ? Color.green : .orange)
                            .symbolEffect(.bounce, value: text)
                    }
                    Text(text.replacingOccurrences(of: "✓ ", with: ""))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { shown = nil } }
            }
        }
        .animation(.spring(duration: 0.4), value: text)
        .onChange(of: message, initial: true) { _, new in show(new) }
        .onChange(of: confirming) { _, new in if new == nil { show(message) } }
    }

    private func show(_ new: String?) {
        hideTask?.cancel()
        shown = new
        guard new != nil, confirming == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation { shown = nil }
        }
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
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
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
                                .spinning(active && systemImage.hasPrefix("fan"))
                                .symbolEffect(.pulse, isActive: active && !systemImage.hasPrefix("fan"))
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
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
            )
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .animation(.spring(duration: 0.4), value: active)
        .animation(.easeInOut(duration: 0.2), value: busy)
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
                    limitRow("Home and AC posts", value: $ac, systemImage: "powerplug")
                    limitRow("Rapid chargers (DC)", value: $dc, systemImage: "bolt.car")
                } footer: {
                    Text("80% is kinder to the battery day to day. Use 100% before a long trip.")
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
                    .disabled(ac == model.snapshot?.details?.chargeLimitAC && dc == model.snapshot?.details?.chargeLimitDC)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue)%")
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
                Button("Resume automation") {
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
        case .fakeMode: return "Demo mode is on. Nothing is sent to your car."
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
