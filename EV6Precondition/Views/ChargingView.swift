import Charts
import PreconditionKit
import SwiftUI

/// Charging: smart charging on the cheapest prices, the tariff, and what charging costs.
struct ChargingView: View {
    @Environment(CarModel.self) private var car
    @Environment(ChargingModel.self) private var charging

    var body: some View {
        List {
            nowSection
            SmartChargeSection()
            PricesSection()
            CostsSummarySection()
            TariffSection()
            CostSettingsSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Charging & costs")
        .refreshable {
            await car.refresh()
            await charging.refreshPrices()
        }
        .task {
            charging.replan(soc: car.snapshot?.socPercent)
            if charging.pricesStale { await charging.refreshPrices() }
        }
    }

    private var nowSection: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now").font(.caption).foregroundStyle(.secondary)
                    Text(charging.currentPence.map { String(format: "%.1fp", $0) } ?? "–")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("per kWh · \(charging.settings.tariff.name)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label(plugText, systemImage: car.snapshot?.chargingState == .charging ? "bolt.fill" : "powerplug")
                        .foregroundStyle(car.snapshot?.pluggedIn == true ? .green : .secondary)
                    if let soc = car.snapshot?.socPercent {
                        Text("\(soc)%").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 4)
            if let problem = charging.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
            }
        }
    }

    private var plugText: String {
        switch car.snapshot?.chargingState {
        case .charging: return "Charging"
        case .pluggedIn: return "Plugged in"
        case .unplugged: return "Unplugged"
        case nil: return "No data"
        }
    }
}

// MARK: - Bindings

extension ChargingModel {
    /// A binding that saves each change.
    func binding<T>(_ path: WritableKeyPath<ChargingSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { value in Task { await self.update { $0[keyPath: path] = value } } }
        )
    }
}

extension ClockTime {
    /// For a DatePicker showing hours and minutes.
    var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}

// MARK: - Smart charging

private struct SmartChargeSection: View {
    @Environment(CarModel.self) private var car
    @Environment(ChargingModel.self) private var charging
    /// Set once the AC limit button's been tapped, so its result shows here.
    @State private var sentLimit = false

    private var settingLimit: Bool {
        if case .command(.setChargeLimits)? = car.busy { return true }
        return false
    }

    var body: some View {
        let smart = charging.settings.smart
        Section {
            Toggle(isOn: Binding(
                get: { smart.enabled },
                set: { on in
                    Task {
                        await charging.update { $0.smart.enabled = on }
                        charging.replan(soc: car.snapshot?.socPercent)
                        await ChargingCoordinator.shared.remindAtWindowStart()
                        ChargingCoordinator.shared.scheduleBackgroundRefresh()
                    }
                }
            )) {
                Label("Smart charging", systemImage: "bolt.badge.clock")
            }
            if smart.enabled {
                RoundStepper("Charge to", value: Binding(
                    get: { smart.targetPercent },
                    set: { v in Task { await charging.update { $0.smart.targetPercent = v }; charging.replan(soc: car.snapshot?.socPercent) } }
                ), in: 50...100, step: 10, tint: .green) { "\($0)%" }
                DatePicker("Ready by", selection: Binding(
                    get: { smart.readyBy.date },
                    set: { d in Task { await charging.update { $0.smart.readyBy = ClockTime(date: d) }; charging.replan(soc: car.snapshot?.socPercent) } }
                ), displayedComponents: .hourAndMinute)
                Picker("Home charger", selection: Binding(
                    get: { smart.chargerKW },
                    set: { v in Task { await charging.update { $0.smart.chargerKW = v }; charging.replan(soc: car.snapshot?.socPercent) } }
                )) {
                    Text("2.3 kW (3-pin plug)").tag(2.3)
                    Text("7 kW").tag(7.0)
                    Text("11 kW").tag(11.0)
                }
                planRow
                if let limit = car.snapshot?.details?.chargeLimitAC, limit != smart.targetPercent {
                    Button {
                        sentLimit = true
                        Task { await car.send(.setChargeLimits(ac: smart.targetPercent, dc: car.snapshot?.details?.chargeLimitDC ?? 80)) }
                    } label: {
                        HStack {
                            Label("Set the car's AC limit to \(smart.targetPercent)% (now \(limit)%)", systemImage: "gauge.with.dots.needle.67percent")
                            Spacer()
                            if settingLimit { ProgressView() }
                        }
                    }
                    .disabled(car.busy != nil)
                }
                if sentLimit, !settingLimit, let message = car.message {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Smart charging")
        } footer: {
            Text(smart.enabled
                 ? "Plug in as usual. The car charges in the cheapest slots and stops at your target. If the app can't start it, you'll get a notification with a Start button."
                 : "Charge at the cheapest time before you need the car.")
        }
    }

    @ViewBuilder private var planRow: some View {
        if let plan = charging.plan {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "bolt.badge.clock.fill").foregroundStyle(.green)
                    Text("\(plan.start.formatted(date: .omitted, time: .shortened))–\(plan.end.formatted(date: .omitted, time: .shortened))")
                        .font(.headline)
                    Spacer()
                    Text(DisplayText.money(pence: plan.costPence)).font(.headline).monospacedDigit()
                }
                Text(String(format: "%.1f kWh to %d%% at %.1fp/kWh on average", plan.kWh, plan.targetPercent, plan.averagePence))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if plan.savingPence >= 5 {
                    Text("\(DisplayText.money(pence: plan.savingPence)) less than charging now")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } else if car.snapshot?.socPercent == nil {
            Text("Refresh the car to plan a charge.").foregroundStyle(.secondary)
        } else {
            Text("Nothing to do: already at \(charging.settings.smart.targetPercent)% or more.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Prices

private struct PricesSection: View {
    @Environment(ChargingModel.self) private var charging

    var body: some View {
        let slots = charging.upcoming
        Section {
            if slots.isEmpty {
                if charging.loadingPrices {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading prices…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("No prices yet. Pull down to try again.").foregroundStyle(.secondary)
                }
            } else {
                Chart {
                    ForEach(slots, id: \.start) { slot in
                        BarMark(
                            x: .value("Time", slot.start, unit: .minute),
                            y: .value("p/kWh", slot.pencePerKWh),
                            width: .fixed(max(2, 300 / CGFloat(slots.count) - 1))
                        )
                        .foregroundStyle(color(slot))
                    }
                    RuleMark(x: .value("Now", charging.now)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxisLabel("p/kWh")
                .frame(height: 170)
                .padding(.vertical, 6)
                if let cheapest = slots.min(by: { $0.pencePerKWh < $1.pencePerKWh }) {
                    LabeledContent("Cheapest", value: String(format: "%.1fp at %@", cheapest.pencePerKWh, cheapest.start.formatted(date: .omitted, time: .shortened)))
                }
            }
            if charging.loadingPrices && !slots.isEmpty { ProgressView() }
        } header: {
            Text("Prices ahead")
        } footer: {
            if case .agile = charging.settings.tariff {
                Text("Tomorrow's prices arrive around 4 pm. Green is when the car will charge.")
            } else if charging.plan != nil {
                Text("Green is when the car will charge.")
            }
        }
    }

    private func color(_ slot: PriceSlot) -> Color {
        if let plan = charging.plan, slot.start >= plan.start.addingTimeInterval(-1799), slot.start < plan.end { return .green }
        if slot.pencePerKWh <= 0 { return .blue }
        if slot.pencePerKWh < 15 { return .teal }
        if slot.pencePerKWh < 25 { return .orange.opacity(0.8) }
        return .red.opacity(0.8)
    }
}

// MARK: - Costs

private struct CostsSummarySection: View {
    @Environment(CarModel.self) private var car
    @Environment(ChargingModel.self) private var charging

    var body: some View {
        Section {
            if let month = charging.monthly.first {
                LabeledContent(month.month.formatted(.dateTime.month(.wide)), value: DisplayText.money(pence: month.totals.costPence))
                LabeledContent("Energy", value: String(format: "%.0f kWh in %d charge%@", month.totals.paidKWh, month.totals.sessions, month.totals.sessions == 1 ? "" : "s"))
            } else {
                Text("Home charges are added automatically when the app sees the battery rise.").foregroundStyle(.secondary)
            }
            if let perMile = charging.perMile {
                let unit = car.settings.useMiles ? "mile" : "km"
                let scale = car.settings.useMiles ? 1 : 1 / 1.609344
                LabeledContent("Cost per \(unit)", value: String(format: "%.1fp", perMile.electric * scale))
                LabeledContent("Petrol car, per \(unit)", value: String(format: "%.1fp", perMile.petrol * scale))
            }
            NavigationLink {
                ChargeHistoryView()
            } label: {
                Label("All charges", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Costs")
        }
    }
}

struct ChargeHistoryView: View {
    @Environment(ChargingModel.self) private var charging
    @State private var adding = false

    var body: some View {
        List {
            if charging.data.sessions.isEmpty {
                ContentUnavailableView("No charges yet", systemImage: "bolt.car",
                                       description: Text("Home charges are logged automatically. Tap + to add a public one."))
            }
            ForEach(charging.monthly, id: \.month) { month in
                Section {
                    ForEach(charging.data.sessions.filter { Calendar.current.isDate($0.start, equalTo: month.month, toGranularity: .month) }) { s in
                        SessionRow(session: s)
                    }
                    .onDelete { offsets in
                        let inMonth = charging.data.sessions.filter { Calendar.current.isDate($0.start, equalTo: month.month, toGranularity: .month) }
                        for i in offsets { Task { await charging.delete(inMonth[i].id) } }
                    }
                } header: {
                    HStack {
                        Text(month.month.formatted(.dateTime.month(.wide).year()))
                        Spacer()
                        Text(DisplayText.money(pence: month.totals.costPence))
                    }
                } footer: {
                    Text(String(format: "Home %@ · Public %@ · %.0f kWh", DisplayText.money(pence: month.totals.homeCostPence), DisplayText.money(pence: month.totals.publicCostPence), month.totals.paidKWh))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Charges")
        .toolbar {
            Button {
                adding = true
            } label: {
                Label("Add a public charge", systemImage: "plus")
            }
        }
        .sheet(isPresented: $adding) { AddChargeSheet() }
    }
}

private struct SessionRow: View {
    let session: ChargeSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.atHome ? "house.fill" : "bolt.car.fill")
                .foregroundStyle(session.atHome ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.manual ? (session.note?.isEmpty == false ? session.note! : "Public charge") : "\(session.startPercent)% → \(session.endPercent)%")
                    .font(.body.weight(.medium))
                Text("\(session.start.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f kWh", session.paidKWh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DisplayText.money(pence: session.costPence)).font(.body.weight(.semibold)).monospacedDigit()
                Text(String(format: "%.1fp/kWh", session.pencePerKWh)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddChargeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChargingModel.self) private var charging
    @State private var when = Date()
    @State private var percent = 50
    @State private var costText = ""
    @State private var note = ""
    /// Read as it's typed: a number pad has no return key to commit it.
    private var pounds: Double? { Double(costText.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "£", with: "")) }
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("When", selection: $when)
                RoundStepper("Added", value: $percent, in: 5...100, step: 5) { "\($0)%" }
                LabeledContent("Cost (£)") {
                    TextField("0.00", text: $costText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Where (optional)", text: $note)
                    .submitLabel(.done)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Public charge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let cost = pounds, cost > 0 else { return }
                        saving = true
                        Task {
                            await charging.addManual(start: when, percentAdded: percent, costPounds: cost, note: note.isEmpty ? nil : note)
                            dismiss()
                        }
                    }
                    .disabled(saving || (pounds ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Tariff

private struct TariffSection: View {
    @Environment(ChargingModel.self) private var charging
    @State private var postcode = ""
    @State private var lookingUp = false

    private enum Kind: String, CaseIterable, Identifiable {
        case flat = "Standard", offPeak = "Off-peak (like EDF GoElectric)", agile = "Half-hourly prices"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch charging.settings.tariff {
        case .flat: return .flat
        case .offPeak: return .offPeak
        case .agile: return .agile
        }
    }

    var body: some View {
        Section {
            Picker("Tariff", selection: Binding(get: { kind }, set: { choose($0) })) {
                // Half-hourly prices only show for someone already on them.
                ForEach(Kind.allCases.filter { $0 != .agile || kind == .agile }) { Text($0.rawValue).tag($0) }
            }
            switch charging.settings.tariff {
            case .flat(let p):
                PenceField(title: "Price", value: p) { v in set(.flat(pencePerKWh: v)) }
            case .offPeak(let peak, let off, let from, let to):
                PenceField(title: "Off-peak price", value: off) { v in set(.offPeak(peakPence: peak, offPeakPence: v, from: from, to: to)) }
                PenceField(title: "Peak price", value: peak) { v in set(.offPeak(peakPence: v, offPeakPence: off, from: from, to: to)) }
                DatePicker("Cheap from", selection: Binding(get: { from.date }, set: { set(.offPeak(peakPence: peak, offPeakPence: off, from: ClockTime(date: $0), to: to)) }), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: Binding(get: { to.date }, set: { set(.offPeak(peakPence: peak, offPeakPence: off, from: from, to: ClockTime(date: $0))) }), displayedComponents: .hourAndMinute)
            case .agile(let region, let fallback):
                if region == "?" {
                    Text("Enter your postcode to get Agile prices for your area.").foregroundStyle(.orange)
                } else {
                    LabeledContent("Region", value: region)
                }
                HStack {
                    TextField("Postcode", text: $postcode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            guard postcode.count >= 5, !lookingUp else { return }
                            lookingUp = true
                            Task {
                                await charging.useAgile(postcode: postcode)
                                lookingUp = false
                            }
                        }
                    if lookingUp {
                        ProgressView()
                    } else {
                        Button(region == "?" ? "Look up" : "Change") {
                            lookingUp = true
                            Task {
                                await charging.useAgile(postcode: postcode)
                                lookingUp = false
                            }
                        }
                        .disabled(postcode.count < 5)
                    }
                }
                PenceField(title: "Price if Agile's unavailable", value: fallback) { v in set(.agile(region: region, fallbackPence: v)) }
            }
        } header: {
            Text("Home tariff")
        } footer: {
            if case .agile = charging.settings.tariff {
                Text("Prices come from Octopus for your area. No account needed.")
            }
        }
        .onAppear { postcode = charging.settings.postcode ?? "" }
    }

    private func set(_ tariff: Tariff) {
        Task { await charging.update { $0.tariff = tariff } }
    }

    /// The normal (non-cheap) price you've entered, carried over when you switch tariff type.
    private var standardPrice: Double {
        switch charging.settings.tariff {
        case .flat(let p): return p
        case .offPeak(let peak, _, _, _): return peak
        case .agile(_, let fallback): return fallback
        }
    }

    private func choose(_ kind: Kind) {
        guard kind != self.kind else { return }
        let price = standardPrice
        switch kind {
        case .flat: set(.flat(pencePerKWh: price))
        case .offPeak: set(.offPeak(peakPence: price, offPeakPence: 7, from: ClockTime(hour: 23, minute: 30), to: ClockTime(hour: 5, minute: 30)))
        case .agile:
            if postcode.count >= 5 {
                Task { await charging.useAgile(postcode: postcode) }
            } else {
                set(.agile(region: "?", fallbackPence: price))
            }
        }
    }
}

private struct PenceField: View {
    let title: String
    let value: Double
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 2) {
                TextField("p", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                Text("p/kWh").foregroundStyle(.secondary)
            }
        }
        .onAppear { text = String(format: "%g", value) }
    }

    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > -100, v < 200 {
            if v != value { onCommit(v) }
        } else {
            // Not a price: put back the saved one.
            text = String(format: "%g", value)
        }
    }
}

private struct CostSettingsSection: View {
    @Environment(ChargingModel.self) private var charging

    var body: some View {
        Section {
            PenceField(title: "Price", value: charging.settings.publicPencePerKWh) { v in
                Task { await charging.update { $0.publicPencePerKWh = v } }
            }
        } header: {
            Text("Public charging")
        } footer: {
            Text("Used for public charges you add. Home charges include about 10% lost in charging.")
        }
        Section {
            RoundStepper("Petrol car's economy", value: charging.binding(\.petrolMPG), in: 20...80, step: 1) { String(format: "%.0f mpg", $0) }
            RoundStepper("Petrol price", value: charging.binding(\.petrolPencePerLitre), in: 100...220, step: 1) { String(format: "%.0fp/litre", $0) }
        } header: {
            Text("Compared with petrol")
        }
    }
}
