import PreconditionKit
import SwiftUI
import UniformTypeIdentifiers

/// The rules list (HANDOVER.md §6.2): on/off, a one-line description and the last result.
struct RulesView: View {
    @Environment(RulesModel.self) private var model
    @Environment(CarModel.self) private var car
    @State private var editing: EditorItem?
    @State private var showImporter = false
    @State private var showScheduleHelp = false
    @State private var composing = false
    @AppStorage("dismissedSuggestions") private var dismissed = ""

    private var suggestions: [Suggestion] {
        let hidden = Set(dismissed.split(separator: ",").map(String.init))
        return model.suggestions.filter { !hidden.contains($0.id) }
    }

    struct EditorItem: Identifiable {
        let rule: Rule
        let isNew: Bool
        var id: String { rule.id }
    }

    private var hasScheduleRules: Bool {
        model.rules.contains { if case .schedule = $0.trigger { return true } else { return false } }
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = model.message {
                    Section {
                        Text(message).font(.footnote)
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion) {
                                Task {
                                    if let rule = await model.apply(suggestion) {
                                        editing = EditorItem(rule: rule, isNew: true)
                                    } else {
                                        await car.load()
                                    }
                                }
                            } dismiss: {
                                dismissed += (dismissed.isEmpty ? "" : ",") + suggestion.id
                            }
                        }
                    } header: {
                        Label("Suggested for you", systemImage: "sparkles")
                    }
                }
                if model.rules.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No rules yet").font(.headline)
                            Text("Tap ✨ and describe what you want, like “weekdays at 7:30 heat to 22 if it's below 5”, or tap + for a template.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section {
                        ForEach(model.rules) { rule in
                            RuleRow(rule: rule) {
                                editing = EditorItem(rule: rule, isNew: false)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { model.rules[$0].id }
                            Task { for id in ids { await model.delete(id: id) } }
                        }
                    }
                }
                if hasScheduleRules {
                    Section {
                        Button {
                            showScheduleHelp = true
                        } label: {
                            Label("Set up schedule automations", systemImage: "calendar.badge.clock")
                        }
                    } footer: {
                        Text("iOS can't wake an app at an exact time, so schedule rules run from a Shortcuts automation.")
                    }
                }
                Section {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        LabeledContent {
                            Text(model.places.isEmpty ? "None yet" : "\(model.places.count)")
                        } label: {
                            Label("Places", systemImage: "mappin.and.ellipse")
                        }
                    }
                } footer: {
                    if model.places.isEmpty {
                        Text("Add Home and Work to start climate when you leave or arrive.")
                    }
                }
            }
            .navigationTitle("Rules")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ShareLink(item: model.exportText(), preview: SharePreview("EV6 rules backup")) {
                            Label("Export rules", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import rules", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        composing = true
                    } label: {
                        Label("Describe a rule", systemImage: "sparkles")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Templates") {
                            ForEach(Templates.all, id: \.title) { template in
                                Button(template.title) {
                                    editing = EditorItem(rule: model.newRule(from: template), isNew: true)
                                }
                            }
                        }
                        Button("Blank rule") {
                            editing = EditorItem(rule: model.blankRule(), isNew: true)
                        }
                    } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { item in
                RuleEditorView(rule: item.rule, isNew: item.isNew)
            }
            .sheet(isPresented: $composing) {
                ComposeRuleView { rule in
                    composing = false
                    // Let the sheet close before the editor opens.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        editing = EditorItem(rule: rule, isNew: true)
                    }
                }
            }
            .sheet(isPresented: $showScheduleHelp) {
                ScheduleHelpView()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    model.message = "Couldn't read that file."
                    return
                }
                Task { await model.importText(text) }
            }
            .refreshable { await model.load() }
            .task {
                await model.load()
                let usesPhone = model.rules.contains { rule in
                    rule.enabled && rule.conditions.contains { if case .phoneNearCar = $0 { return true } else { return false } }
                }
                if usesPhone { LocationAccess.shared.requestIfNeeded() }
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(suggestion.title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: suggestion.systemImage).foregroundStyle(.purple)
            }
            Text(suggestion.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                if suggestion.fix != nil {
                    Button(buttonTitle, action: accept)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                Button("Not now", action: dismiss)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var buttonTitle: String {
        switch suggestion.fix {
        case .addRule?: return "Review Rule"
        case .holdCharger?: return "Turn On"
        case nil: return "OK"
        }
    }
}

private struct RuleRow: View {
    @Environment(RulesModel.self) private var model
    let rule: Rule
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name).font(.headline)
                Text(model.describe(rule))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let last = model.lastResults[rule.id] {
                    Text("\(last.decision.capitalizingFirst) \(DisplayText.age(of: last.at, now: Date())): \(last.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)

            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { on in Task { await model.setEnabled(rule.id, on) } }
            ))
            .labelsHidden()
        }
        .opacity(rule.enabled ? 1 : 0.6)
    }
}

/// How to run schedule rules on time with Shortcuts.
private struct ScheduleHelpView: View {
    @Environment(RulesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?

    private var times: [TimeOfDay] {
        let all = model.rules.compactMap { rule -> TimeOfDay? in
            if rule.enabled, case .schedule(_, let t) = rule.trigger { return t }
            return nil
        }
        return Array(Set(all)).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("For each time below, add one automation in the Shortcuts app:")
                    Label("Shortcuts › Automation › + (New Automation)", systemImage: "1.circle")
                    Label("Time of Day: set the time; choose Run Immediately", systemImage: "2.circle")
                    Label("Add the action “Run scheduled rules” (EV6 Precondition)", systemImage: "3.circle")
                } footer: {
                    Text("The app checks the rule's days and conditions itself, so a daily automation is fine. Each rule runs at most once a day, even if the automation runs twice.")
                }
                Section("Times to add") {
                    if times.isEmpty {
                        Text("No enabled schedule rules.").foregroundStyle(.secondary)
                    }
                    ForEach(times, id: \.self) { t in
                        Text(Describe.time(t)).font(.body.monospacedDigit())
                    }
                }
                if let next = model.nextCheck {
                    Section {
                        LabeledContent("Next scheduled check") {
                            Text(next.at, format: .dateTime.weekday().hour().minute())
                        }
                    }
                }
                Section {
                    Button("Run scheduled rules now") {
                        Task {
                            let outcomes = await model.runDueSchedules()
                            result = RunScheduledRulesIntent.summary(outcomes)
                        }
                    }
                    if let result {
                        Text(result).font(.footnote)
                    }
                } footer: {
                    Text("Only rules due within the last 10 minutes (or the next 2) run.")
                }
            }
            .navigationTitle("Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
