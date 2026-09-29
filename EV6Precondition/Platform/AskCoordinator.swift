import Foundation
import Observation
import PreconditionKit

/// "Ask first" rules: books their questions with iOS a week ahead (dropping days the forecast rules
/// out), and carries out the answer: start now, ask again in 15 minutes, or not today.
@MainActor
@Observable
final class AskCoordinator {
    static let shared = AskCoordinator()

    /// A question opened from its notification, for the app to show.
    var pending: Rule?

    /// Rebooks the coming week's questions. Cheap: runs whenever the app does.
    func rebook() async {
        let services = AppServices.shared
        let rules = services.rules.rules
        let clock = LocalClock(timeZone: .current)
        let slots = AskPlanner.upcoming(rules, after: Date(), days: 7, clock: clock)
        let spot = services.car.snapshot?.parkingPosition ?? services.rules.places.first?.centre
        var asks: [(id: String, ruleId: String, title: String, text: String, at: Date)] = []
        for slot in slots {
            guard let rule = rules.first(where: { $0.id == slot.ruleId }) else { continue }
            // The forecast is only worth asking for within a few days.
            var forecast: Double?
            if let spot, slot.at.timeIntervalSinceNow < 4 * 86400 {
                forecast = await services.container.weather.forecast(at: spot, time: slot.at)?.celsius
            }
            if AskPlanner.forecastRulesOut(rule, forecastC: forecast) { continue }
            asks.append((slot.id, rule.id, AskPlanner.title(rule), AskPlanner.text(rule, outsideC: forecast), slot.at))
        }
        await services.notifier.rebook(asks)
    }

    func answer(_ ruleId: String, _ answer: LocalNotifier.AskAnswer) async {
        let services = AppServices.shared
        await services.prepare()
        guard let rule = services.rules.rules.first(where: { $0.id == ruleId }) else { return }
        switch answer {
        case .start:
            await run(rule)
        case .later:
            await services.notifier.book(
                id: "\(LocalNotifier.askPrefix)\(rule.id)-later", ruleId: rule.id,
                title: AskPlanner.title(rule), text: AskPlanner.text(rule, outsideC: nil),
                at: Date().addingTimeInterval(15 * 60)
            )
        case .skip:
            break
        case .opened:
            pending = rule
        }
    }

    /// Carries out the rule's action as if tapped in the app (the minimum-charge guard still applies).
    func run(_ rule: Rule) async {
        let car = AppServices.shared.car
        switch rule.action {
        case .startClimate(let target): await car.start(targetC: target)
        case .stopClimate: await car.stop()
        }
    }
}
