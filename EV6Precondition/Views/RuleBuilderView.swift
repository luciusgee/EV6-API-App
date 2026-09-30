import PreconditionKit
import SwiftUI

/// Making a rule in four short steps (when, what, only if, check), with the rule read back in plain
/// words at every step so there's no guessing what it will do.
struct RuleBuilderView: View {
    @Environment(RulesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var b = RuleBuilder()
    @State private var step = 0
    @State private var name = ""
    @State private var nameEdited = false
    @State private var saving = false
    @State private var problems: [String] = []
    @State private var confirmDiscard = false

    private let titles = ["When should it run?", "What should the car do?", "Only if…", "Check and save"]

    private func placeName(_ id: String) -> String { model.placeName(id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    summary
                }
                switch step {
                case 0: whenStep
                case 1: doStep
                case 2: onlyIfStep
                default: saveStep
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(.snappy, value: step)
            .navigationTitle(titles[step])
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmDiscard = true }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(titles[step]).font(.headline)
                        Text("Step \(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .confirmationDialog("Discard this rule?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep going", role: .cancel) {}
            }
            .onAppear {
                if b.placeId == nil { b.placeId = model.places.first?.id }
                name = b.shortName(placeName: placeName)
            }
            .onChange(of: b) { _, _ in
                problems = []
                if !nameEdited { name = b.shortName(placeName: placeName) }
            }
        }
    }

    // MARK: The rule so far

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: b.doing))
                .font(.title2)
                .foregroundStyle(tint(for: b.doing))
                .frame(width: 32)
            Text(b.sentence(placeName: placeName))
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your rule: \(b.sentence(placeName: placeName))")
    }

    // MARK: Step 1: when

    @ViewBuilder
    private var whenStep: some View {
        Section {
            option("At a set time", detail: "On the days you pick", icon: "clock", selected: b.when == .time) { b.when = .time }
            option("When I leave a place", detail: "Like leaving work", icon: "figure.walk.departure", selected: b.when == .leave) { b.when = .leave }
            option("When I'm on my way to a place", detail: "A few km before you get there", icon: "location.north.line", selected: b.when == .approach) { b.when = .approach }
            option("When I get to a place", detail: "Like getting home", icon: "house", selected: b.when == .arrive) { b.when = .arrive }
            option("When I walk up to the car", detail: "Your phone gets close to it", icon: "figure.walk", selected: b.when == .nearCar) { b.when = .nearCar }
        }
        switch b.when {
        case .time:
            Section {
                TimePicker(title: "Time", time: $b.time)
                Picker("Days", selection: dayPreset) {
                    Text("Weekdays").tag(0)
                    Text("Every day").tag(1)
                    Text("Weekends").tag(2)
                    Text("Pick").tag(3)
                }
                .pickerStyle(.segmented)
                DaysPicker(days: $b.days)
            } footer: {
                Text("Set-time rules run from a Shortcuts automation: after saving, tap Set up schedule automations on the Rules page.")
            }
        case .leave, .arrive, .approach:
            Section {
                if model.places.isEmpty {
                    Text("Add a place like Home or Work first.").foregroundStyle(.secondary)
                } else {
                    PlacePicker(selection: Binding(get: { b.placeId ?? "" }, set: { b.placeId = $0 }), places: model.places)
                }
                NavigationLink { PlacesView() } label: { Label(model.places.isEmpty ? "Add a place" : "Edit places", systemImage: "mappin.and.ellipse") }
                if b.when == .approach {
                    RoundStepper("How far away", value: $b.approachKm, in: 1...30, step: 1) { "\(Int($0)) km" }
                }
            }
        case .nearCar:
            EmptyView()
        }
    }

    private var dayPreset: Binding<Int> {
        Binding(
            get: {
                switch b.days {
                case Weekday.weekdays: return 0
                case Weekday.everyDay: return 1
                case Weekday.weekend: return 2
                default: return 3
                }
            },
            set: { v in
                switch v {
                case 0: b.days = Weekday.weekdays
                case 1: b.days = Weekday.everyDay
                case 2: b.days = Weekday.weekend
                default: break
                }
            }
        )
    }

    // MARK: Step 2: what

    @ViewBuilder
    private var doStep: some View {
        Section {
            option("Warm it up", detail: "Heat the cabin", icon: "flame.fill", selected: b.doing == .warm, tint: .orange) { b.doing = .warm }
            option("Cool it down", detail: "Air conditioning", icon: "snowflake", selected: b.doing == .cool, tint: .cyan) { b.doing = .cool }
            option("Turn the climate off", detail: "If it's running", icon: "power", selected: b.doing == .stop, tint: Color.secondary) { b.doing = .stop }
        }
        switch b.doing {
        case .warm:
            Section {
                RoundStepper("Temperature", value: $b.warmC, in: RuleValidator.minTargetC...RuleValidator.maxTargetC, step: 0.5, tint: .orange) { tempText($0) }
                Toggle(isOn: $b.heatedExtras) {
                    Label("Heated steering wheel, mirrors and rear window", systemImage: "steeringwheel")
                }
                Toggle(isOn: $b.defrost) {
                    Label("Defrost the windscreen", systemImage: "windshield.front.and.heat.waves")
                }
            }
        case .cool:
            Section {
                RoundStepper("Temperature", value: $b.coolC, in: RuleValidator.minTargetC...RuleValidator.maxTargetC, step: 0.5, tint: .cyan) { tempText($0) }
            }
        case .stop:
            EmptyView()
        }
    }

    // MARK: Step 3: only if

    @ViewBuilder
    private var onlyIfStep: some View {
        if b.doing != .stop {
            Section {
                Toggle(b.doing == .warm ? "Only when it's cold" : "Only when it's hot", isOn: $b.onlyInWeather)
                if b.onlyInWeather {
                    if b.doing == .warm {
                        RoundStepper("Colder than", value: $b.coldBelowC, in: -10...25, step: 1, tint: .orange) { tempText($0) }
                    } else {
                        RoundStepper("Warmer than", value: $b.hotAboveC, in: 10...40, step: 1, tint: .cyan) { tempText($0) }
                    }
                }
            } footer: {
                Text(b.when == .time
                     ? "Uses the weather forecast for \(b.time.description) where the car is."
                     : "Uses the temperature where the car is.")
            }
        }
        Section {
            Toggle("Only if it's plugged in", isOn: $b.onlyIfPluggedIn)
            Toggle("Only if there's enough charge", isOn: Binding(get: { b.minBattery != nil }, set: { b.minBattery = $0 ? 30 : nil }))
            if let minBattery = b.minBattery {
                RoundStepper("At least", value: Binding(get: { minBattery }, set: { b.minBattery = $0 }), in: 10...90, step: 5, tint: .green) { "\($0)%" }
            }
        } footer: {
            Text("Leave these off and it runs every time.")
        }
    }

    // MARK: Step 4: check and save

    @ViewBuilder
    private var saveStep: some View {
        Section {
            TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                .submitLabel(.done)
        } header: {
            Text("Name")
        }
        Section {
            Toggle("Ask me first", isOn: $b.askFirst)
        } footer: {
            Text(b.askFirst
                 ? "You'll get a notification with Start, In 15 min and Not today, instead of it just happening."
                 : "It'll just happen, and you'll get a notification saying so.")
        }
        if !problems.isEmpty {
            Section("Fix before saving") {
                ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red) }
            }
        }
    }

    // MARK: Buttons

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button {
                    step -= 1
                } label: {
                    Text("Back").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                if step < 3 { step += 1 } else { save() }
            } label: {
                HStack {
                    if saving { ProgressView().tint(Color.onAccent) }
                    Text(step < 3 ? "Next" : "Save rule")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color.onAccent)
            .disabled(!canContinue || saving)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canContinue: Bool {
        switch step {
        case 0:
            if b.when == .time { return !b.days.isEmpty }
            if b.needsPlace { return b.placeId.map { id in model.places.contains { $0.id == id } } ?? false }
            return true
        default:
            return true
        }
    }

    private func save() {
        let rule = b.build(name: name, placeName: placeName)
        saving = true
        Task {
            problems = await model.save(rule)
            saving = false
            if problems.isEmpty { dismiss() }
        }
    }

    // MARK: Pieces

    private func option(_ title: String, detail: String, icon: String, selected: Bool, tint: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(selected ? tint : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? tint : Color(.tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tempText(_ c: Double) -> String {
        c == c.rounded() ? "\(Int(c)) °C" : String(format: "%.1f °C", c)
    }

    private func icon(for doing: RuleBuilder.Doing) -> String {
        switch doing {
        case .warm: return "flame.fill"
        case .cool: return "snowflake"
        case .stop: return "power"
        }
    }

    private func tint(for doing: RuleBuilder.Doing) -> Color {
        switch doing {
        case .warm: return .orange
        case .cool: return .cyan
        case .stop: return .secondary
        }
    }
}
