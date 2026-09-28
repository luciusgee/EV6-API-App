import PreconditionKit
import SwiftUI

@main
struct EV6PreconditionApp: App {
    @State private var model: CarModel
    private let notifier: LocalNotifier

    init() {
        let notifier = LocalNotifier()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let container = AppContainer(
            directory: support.appendingPathComponent("EV6Precondition", isDirectory: true),
            credentials: KeychainCredentialsStore(),
            sessions: KeychainSessionStore(account: "kia-session"),
            // Fake-car mode gets its own slot so it never overwrites a real, possibly rotated, token.
            fakeSessions: KeychainSessionStore(account: "kia-session-fake"),
            notifier: notifier
        )
        let model = CarModel(container: container)
        notifier.onStop = {
            await model.stop()
        }
        self.notifier = notifier
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    notifier.register()
                    await model.load()
                }
        }
    }
}
