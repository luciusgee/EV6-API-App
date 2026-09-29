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
                .environment(services.charging)
                .environment(services.presence)
                .environment(services.commute)
                .environment(services.trips)
                .task {
                    await services.prepare()
                }
                // Widget buttons: ev6://command/climateStart and friends.
                .onOpenURL { url in
                    // ev6://commutes?d=… adds commutes, after asking.
                    if let list = CommuteImport.parse(url) {
                        CommuteInbox.shared.pending = list
                        return
                    }
                    guard let command = GlanceCommand(url: url) else { return }
                    Task { _ = await GlanceSync.shared.perform(command) }
                }
        }
    }
}
