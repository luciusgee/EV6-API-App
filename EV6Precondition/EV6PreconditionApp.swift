import PreconditionKit
import SwiftUI

@main
struct EV6PreconditionApp: App {
    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.car)
                .environment(services.rules)
                .environment(services.obd)
                .task {
                    await services.prepare()
                }
        }
    }
}
