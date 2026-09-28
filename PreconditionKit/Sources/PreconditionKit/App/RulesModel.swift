import Foundation
import Observation

/// Behind the Rules screens (HANDOVER.md §6.2): the list, the editor, "Test now", import and export.
@MainActor
@Observable
public final class RulesModel {
    public private(set) var rules: [Rule] = []
    public private(set) var places: [Place] = []
    /// The latest log entry per rule, for "last result" in the list.
    public private(set) var lastResults: [String: LogEntry] = [:]
    public private(set) var nextCheck: ScheduledCheck?
    public private(set) var testing = false
    /// A one-line result to show, e.g. after an import.
    public var message: String?

    private let container: AppContainer

    public nonisolated init(container: AppContainer) {
        self.container = container
    }

    public func load() async {
        let bundle = await container.rules.bundle()
        rules = bundle.rules.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        places = bundle.places.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var latest: [String: LogEntry] = [:]
        for e in await container.stores.log.entries() {
            if let id = e.ruleId { latest[id] = e }
        }
        lastResults = latest
        nextCheck = await container.engine.nextScheduledCheck()
    }

    public func placeName(_ id: String) -> String {
        places.first { $0.id == id }?.name ?? id
    }

    public func describe(_ rule: Rule) -> String {
        Describe.rule(rule) { self.placeName($0) }
    }

    public func problems(_ draft: Rule) -> [String] {
        RuleValidator.validate(draft, placeIds: Set(places.map(\.id)))
    }

    // MARK: Editing

    /// A new rule from a template, pointed at the place whose name matches the hint (else the first place).
    public func newRule(from template: Templates.Template) -> Rule {
        let place = places.first { $0.name.localizedCaseInsensitiveCompare(template.placeHint) == .orderedSame } ?? places.first
        return template.build(place?.id ?? "")
    }

    public func blankRule() -> Rule {
        Rule(
            id: Templates.newId(),
            name: "",
            trigger: places.first.map { .geofenceExit(placeId: $0.id) } ?? .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 30)),
            conditions: [],
            action: .startClimate(targetC: 21)
        )
    }

    /// Saves the rule if it's valid; returns the problems otherwise.
    @discardableResult
    public func save(_ draft: Rule) async -> [String] {
        var rule = draft
        rule.name = rule.name.trimmingCharacters(in: .whitespaces)
        let problems = self.problems(rule)
        guard problems.isEmpty else { return problems }
        await container.rules.save(rule)
        await load()
        return []
    }

    public func delete(id: String) async {
        await container.rules.deleteRule(id: id)
        await load()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.enabled = enabled
        await container.rules.save(rule)
        await load()
    }

    /// "Test now": evaluates the draft as if its trigger just happened, reading the car on the manual
    /// budget, and never sends a command.
    public func testNow(_ draft: Rule) async -> Evaluation {
        testing = true
        defer { testing = false }
        let result = await container.engine.dryRun(draft)
        await load()
        return result
    }

    // MARK: Backup

    public func exportText() -> String {
        RuleJSON.export(places: places, rules: rules)
    }

    /// Imports what's valid (same ids are replaced) and reports the rest.
    @discardableResult
    public func importText(_ text: String) async -> ImportResult {
        let result = RuleJSON.import(text, existingPlaceIds: Set(places.map(\.id)))
        await container.rules.merge(result)
        await load()
        var summary = "Imported \(result.rules.count) rule\(result.rules.count == 1 ? "" : "s") and \(result.places.count) place\(result.places.count == 1 ? "" : "s")."
        if !result.ok {
            summary += " Skipped \(result.issues.count): " + result.issues.map(\.description).joined(separator: "; ")
        }
        message = summary
        await container.stores.log.append(LogEntry(at: container.time.now(), kind: .info, decision: "import", reason: summary))
        return result
    }

    /// For the Shortcuts automation and its "Run now" test in the app.
    public func runDueSchedules() async -> [EngineOutcome] {
        let outcomes = await container.engine.runDueSchedules()
        await load()
        return outcomes
    }
}
