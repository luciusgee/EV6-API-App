import PreconditionKit
import SwiftUI

/// Edits one rule: trigger, conditions, action, with live validation and "Test now" (HANDOVER.md §6.2).
struct RuleEditorView: View {
    @Environment(RulesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Rule
    @State private var result: Evaluation?
    @State private var confirmDiscard = false
    let isNew: Bool
    /// The rule as it was opened, to tell whether there's anything to lose on Cancel.
    private let original: Rule

    init(rule: Rule, isNew: Bool) {
        _draft = State(initialValue: rule)
        self.original = rule
        self.isNew = isNew
    }

    private var changed: Bool { isNew || draft != original }

    private var problems: [String] { model.problems(draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                TriggerSection(trigger: $draft.trigger, places: model.places)
                ConditionsSection(conditions: $draft.conditions, places: model.places)
                ActionSection(action: $draft.action)
                Section {
                    Toggle("Ask me first", isOn: $draft.askFirst)
                } footer: {
                    Text(draft.askFirst
                         ? "You'll get a notification with Start climate, In 15 min and Not today. Hold it to see the buttons."
                         : "Runs by itself when the rule's conditions are met.")
                }
                Section {
                    RoundStepper("Priority", value: $draft.priority, in: -10...10, step: 1) { _ in "\(draft.priority)" }
                    RoundStepper("Cooldown", value: $draft.cooldownMinutes, in: 0...720, step: 15) { _ in "\(draft.cooldownMinutes) min" }
                    Toggle("Run if a condition can't be checked", isOn: $draft.proceedIfUnknown)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Priority decides which rule wins if two run at once. Cooldown stops a rule running again too soon.")
                }
                if !problems.isEmpty {
                    Section("Fix before saving") {
                        ForEach(problems, id: \.self) { problem in
                            Text(problem).foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    Button {
                        Task { result = await model.testNow(draft) }
                    } label: {
                        HStack {
                            Label("Test now", systemImage: "play.circle")
                            Spacer()
                            if model.testing { ProgressView() }
                        }
                    }
                    .disabled(model.testing)
                } footer: {
                    Text("Evaluates the rule as if its trigger just happened, reading the car if needed. It never sends a command.")
                }
                if let result {
                    TestResultSection(evaluation: result)
                }
                if !isNew {
                    Section {
                        Button("Delete rule", role: .destructive) {
                            let id = draft.id
                            Task {
                                await model.delete(id: id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(changed)
            .navigationTitle(isNew ? "New rule" : "Edit rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if changed { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let rule = draft
                        Task {
                            if await model.save(rule).isEmpty { dismiss() }
                        }
                    }
                    .disabled(!problems.isEmpty)
                }
            }
            .confirmationDialog(isNew ? "Discard this rule?" : "Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }
}

// MARK: - Trigger

private enum TriggerKind: String, CaseIterable, Identifiable {
    case leave = "Leave a place"
    case arrive = "Arrive at a place"
    case approaching = "Approaching a place"
    case schedule = "At a time"
    case nearCar = "Near the car"
    var id: String { rawValue }

    init(_ t: Trigger) {
        switch t {
        case .geofenceExit: self = .leave
        case .geofenceEnter: self = .arrive
        case .approaching: self = .approaching
        case .schedule: self = .schedule
        case .nearCar: self = .nearCar
        }
    }
}

private struct TriggerSection: View {
    @Environment(CarModel.self) private var car
    private var miles: Bool { car.settings.useMiles }
    @Binding var trigger: Trigger
    let places: [Place]

    private var kind: Binding<TriggerKind> {
        Binding(
            get: { TriggerKind(trigger) },
            set: { k in
                let place = trigger.placeId ?? places.first?.id ?? ""
                switch k {
                case .leave: trigger = .geofenceExit(placeId: place)
                case .arrive: trigger = .geofenceEnter(placeId: place)
                case .approaching: trigger = .approaching(placeId: place, km: 5)
                case .schedule: trigger = .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 30))
                case .nearCar: trigger = .nearCar(meters: 300)
                }
            }
        )
    }

    private var place: Binding<String> {
        Binding(
            get: { trigger.placeId ?? "" },
            set: { id in
                switch trigger {
                case .geofenceExit: trigger = .geofenceExit(placeId: id)
                case .geofenceEnter: trigger = .geofenceEnter(placeId: id)
                case .approaching(_, let km): trigger = .approaching(placeId: id, km: km)
                case .schedule, .nearCar: break
                }
            }
        )
    }

    @ViewBuilder private var addPlaceLink: some View {
        if places.isEmpty {
            NavigationLink {
                PlacesView()
            } label: {
                Label("Add a place", systemImage: "plus")
            }
        }
    }

    var body: some View {
        Section {
            Picker("When", selection: kind) {
                ForEach(TriggerKind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch trigger {
            case .geofenceExit, .geofenceEnter:
                PlacePicker(selection: place, places: places)
                addPlaceLink
            case .approaching(let id, let km):
                PlacePicker(selection: place, places: places)
                addPlaceLink
                RoundStepper("Within", value: Binding(get: { km }, set: { trigger = .approaching(placeId: id, km: $0) }), in: 0.5...100, step: 0.5) { _ in DisplayText.distance(km: km, miles: miles) }
            case .schedule(let days, let time):
                DaysPicker(days: Binding(get: { days }, set: { trigger = .schedule(days: $0, time: time) }))
                TimePicker(title: "Time", time: Binding(get: { time }, set: { trigger = .schedule(days: days, time: $0) }))
            case .nearCar(let m):
                RoundStepper("Within", value: Binding(get: { m }, set: { trigger = .nearCar(meters: $0) }), in: RuleValidator.minCarRadiusM...RuleValidator.maxCarRadiusM, step: 50) { _ in Describe.distance(m) }
            }
        } header: {
            Text("Trigger")
        } footer: {
            if case .schedule = trigger {
                Text("With Ask me first on, nothing else is needed. Otherwise schedule rules run from a Shortcuts automation (see Rules).")
            }
        }
    }
}

// MARK: - Conditions

private struct ConditionsSection: View {
    @Binding var conditions: [Condition]
    let places: [Place]
    /// One stable id per condition, so deleting a row never shifts another row's edits.
    @State private var ids: [UUID] = []

    private func syncIDs() {
        if ids.count != conditions.count { ids = conditions.map { _ in UUID() } }
    }

    private func defaultCondition(_ n: Int) -> Condition {
        switch n {
        case 0: return .timeWindow(start: TimeOfDay(16, 0), end: TimeOfDay(19, 0))
        case 1: return .daysOfWeek(Weekday.weekdays)
        case 2: return .tempBelow(celsius: 5, source: .bestAvailable)
        case 3: return .tempAbove(celsius: 24, source: .weatherAtCar)
        case 4: return .tempOutside(low: 16, high: 21, source: .bestAvailable)
        case 5: return .socAtLeast(percent: 50)
        case 6: return .pluggedIn(expected: true)
        case 7: return .carAtPlace(placeId: places.first?.id ?? "")
        default: return .phoneNearCar(meters: 1500)
        }
    }

    private let addTitles = [
        "Time window", "Days of the week", "Colder than", "Warmer than", "Outside a temperature range",
        "Charge at least", "Plugged in", "Car at a place", "Phone near the car",
    ]

    var body: some View {
        Section {
            if conditions.isEmpty {
                Text("No conditions: runs every time it's triggered.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(zip(ids, conditions.indices)), id: \.0) { pair in
                ConditionRow(
                    condition: Binding(
                        get: { pair.1 < conditions.count ? conditions[pair.1] : .pluggedIn(expected: true) },
                        set: { if pair.1 < conditions.count { conditions[pair.1] = $0 } }
                    ),
                    places: places
                )
            }
            .onDelete { offsets in
                syncIDs()
                ids.remove(atOffsets: offsets)
                conditions.remove(atOffsets: offsets)
            }
            Menu {
                ForEach(addTitles.indices, id: \.self) { n in
                    Button(addTitles[n]) {
                        syncIDs()
                        ids.append(UUID())
                        conditions.append(defaultCondition(n))
                    }
                }
            } label: {
                Label("Add condition", systemImage: "plus.circle")
            }
        } header: {
            Text("Only if all of these")
        } footer: {
            Text("Swipe left to remove a condition. Your minimum charge in Settings always applies.")
        }
        .onAppear(perform: syncIDs)
        .onChange(of: conditions.count) { _, _ in syncIDs() }
    }
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    let places: [Place]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Describe.condition(condition) { id in places.first { $0.id == id }?.name ?? id }.capitalizingFirst)
                .font(.subheadline.weight(.semibold))
            editor
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var editor: some View {
        switch condition {
        case .timeWindow(let start, let end):
            TimePicker(title: "From", time: Binding(get: { start }, set: { condition = .timeWindow(start: $0, end: end) }))
            TimePicker(title: "Until", time: Binding(get: { end }, set: { condition = .timeWindow(start: start, end: $0) }))
        case .daysOfWeek(let days):
            DaysPicker(days: Binding(get: { days }, set: { condition = .daysOfWeek($0) }))
        case .tempBelow(let t, let s):
            TempStepper(title: "Below", value: Binding(get: { t }, set: { condition = .tempBelow(celsius: $0, source: s) }))
            SourcePicker(source: Binding(get: { s }, set: { condition = .tempBelow(celsius: t, source: $0) }))
        case .tempAbove(let t, let s):
            TempStepper(title: "Above", value: Binding(get: { t }, set: { condition = .tempAbove(celsius: $0, source: s) }))
            SourcePicker(source: Binding(get: { s }, set: { condition = .tempAbove(celsius: t, source: $0) }))
        case .tempOutside(let low, let high, let s):
            TempStepper(title: "Below", value: Binding(get: { low }, set: { condition = .tempOutside(low: $0, high: high, source: s) }))
            TempStepper(title: "or above", value: Binding(get: { high }, set: { condition = .tempOutside(low: low, high: $0, source: s) }))
            SourcePicker(source: Binding(get: { s }, set: { condition = .tempOutside(low: low, high: high, source: $0) }))
        case .socAtLeast(let p):
            RoundStepper("At least", value: Binding(get: { p }, set: { condition = .socAtLeast(percent: $0) }), in: 0...100, step: 5) { _ in "\(p)%" }
        case .pluggedIn(let expected):
            Toggle("Plugged in", isOn: Binding(get: { expected }, set: { condition = .pluggedIn(expected: $0) }))
        case .carAtPlace:
            PlacePicker(
                selection: Binding(
                    get: { if case .carAtPlace(let id) = condition { return id } else { return "" } },
                    set: { condition = .carAtPlace(placeId: $0) }
                ),
                places: places
            )
        case .phoneNearCar(let m):
            RoundStepper("Within", value: Binding(get: { m }, set: { condition = .phoneNearCar(meters: $0) }), in: RuleValidator.minPhoneDistanceM...RuleValidator.maxPhoneDistanceM, step: 50) { _ in Describe.distance(m) }
        }
    }
}

private struct TempStepper: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        RoundStepper(title, value: $value, in: -40...50, step: 0.5) { _ in Describe.temp(value) }
    }
}

private struct SourcePicker: View {
    @Binding var source: TempSource

    private enum Kind: String, CaseIterable, Identifiable {
        case best = "Best available"
        case car = "Car sensor"
        case weather = "Weather at the car"
        case forecast = "Forecast at a time"
        var id: String { rawValue }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch source {
                case .bestAvailable, .cabinBle: return .best
                case .carOutside: return .car
                case .weatherAtCar: return .weather
                case .forecastAt: return .forecast
                }
            },
            set: { k in
                switch k {
                case .best: source = .bestAvailable
                case .car: source = .carOutside
                case .weather: source = .weatherAtCar
                case .forecast: source = .forecastAt(TimeOfDay(7, 40))
                }
            }
        )
    }

    var body: some View {
        Picker("Temperature from", selection: kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        if case .forecastAt(let t) = source {
            TimePicker(title: "Forecast for", time: Binding(get: { t }, set: { source = .forecastAt($0) }))
        }
    }
}

// MARK: - Action

private struct ActionSection: View {
    @Binding var action: RuleAction

    private var isStart: Binding<Bool> {
        Binding(
            get: { if case .startClimate = action { return true } else { return false } },
            set: { start in action = start ? .startClimate(targetC: 21) : .stopClimate }
        )
    }

    var body: some View {
        Section("Then") {
            Picker("Action", selection: isStart) {
                Text("Start climate").tag(true)
                Text("Stop climate").tag(false)
            }
            .pickerStyle(.segmented)
            if case .startClimate(let target) = action {
                RoundStepper("Target", value: Binding(get: { target }, set: { action = .startClimate(targetC: $0) }), in: RuleValidator.minTargetC...RuleValidator.maxTargetC, step: 0.5) { _ in Describe.temp(target) }
            }
        }
    }
}

// MARK: - Test result

private struct TestResultSection: View {
    let evaluation: Evaluation

    var body: some View {
        Section("Test result") {
            if let skip = evaluation.globalSkip {
                Label("Would skip: \(skip.capitalizingFirst)", systemImage: "pause.circle")
            }
            ForEach(Array(evaluation.verdicts.enumerated()), id: \.offset) { _, verdict in
                Label(verdict.fired ? "Would run" : "Would skip", systemImage: verdict.fired ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(verdict.fired ? Color.green : Color.red)
                Text(verdict.reason.capitalizingFirst).font(.subheadline)
                ForEach(Array(verdict.checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(check.result))
                            .foregroundStyle(color(check.result))
                        Text("\(check.name): \(check.detail)").font(.caption)
                    }
                }
            }
        }
    }

    private func icon(_ t: Tri) -> String {
        switch t {
        case .pass: return "checkmark"
        case .fail: return "xmark"
        case .unknown: return "questionmark"
        }
    }

    private func color(_ t: Tri) -> Color {
        switch t {
        case .pass: return .green
        case .fail: return .red
        case .unknown: return .orange
        }
    }
}

// MARK: - Shared pickers

struct PlacePicker: View {
    @Binding var selection: String
    let places: [Place]

    var body: some View {
        Picker("Place", selection: $selection) {
            if !places.contains(where: { $0.id == selection }) {
                Text(places.isEmpty ? "No places yet" : "Choose…").tag(selection)
            }
            ForEach(places) { Text($0.name).tag($0.id) }
        }
    }
}

struct DaysPicker: View {
    @Binding var days: Set<Weekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(String(day.shortName.prefix(2)))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.shortName)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct TimePicker: View {
    let title: String
    @Binding var time: TimeOfDay

    private var date: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                time = TimeOfDay(c.hour ?? 0, c.minute ?? 0)
            }
        )
    }

    var body: some View {
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
    }
}
