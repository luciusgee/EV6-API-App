import PreconditionKit
import SwiftUI

@main
struct EV6PreconditionApp: App {
    private let services = AppServices.shared

    init() {
        KeyboardDoneBar.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.obd)
                .environment(services.prefs)
                .environment(services.battery)
                .environment(services.runs)
                .environment(services.charges)
                .environment(services.store)
                .task { await services.prepare() }
                .preferredColorScheme(.dark)
        }
    }
}
