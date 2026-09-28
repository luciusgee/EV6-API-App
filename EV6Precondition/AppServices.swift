import Foundation
import PreconditionKit

/// One set of services for the app and its App Intents (Shortcuts and Siri run in the app's process).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let notifier: LocalNotifier
    let container: AppContainer
    let car: CarModel
    let rules: RulesModel
    private var prepared = false

    private init() {
        let notifier = LocalNotifier()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let container = AppContainer(
            directory: support.appendingPathComponent("EV6Precondition", isDirectory: true),
            credentials: KeychainCredentialsStore(),
            sessions: KeychainSessionStore(account: "kia-session"),
            // Fake-car mode gets its own slot so it never overwrites a real, possibly rotated, token.
            fakeSessions: KeychainSessionStore(account: "kia-session-fake"),
            notifier: notifier,
            phone: LocationPhoneLocator()
        )
        let car = CarModel(container: container)
        self.notifier = notifier
        self.container = container
        self.car = car
        self.rules = RulesModel(container: container)
        notifier.onStop = {
            await car.stop()
        }
    }

    /// Loads settings and state once; safe to call from every entry point.
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        notifier.register()
        await car.load()
        await rules.load()
    }
}
