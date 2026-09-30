import PreconditionKit
import UIKit

/// Commutes checking themselves: iOS wakes the app when you drive away from a commute's start, the
/// traffic is checked in the seconds it allows, and a notification says which way to go.
@MainActor
enum CommuteCoordinator {
    static func leftStart(_ id: UUID) async {
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "commute") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        defer { if task != .invalid { app.endBackgroundTask(task) } }
        let services = AppServices.shared
        await services.prepare()
        guard let commute = services.commute.commutes.first(where: { $0.id == id }), commute.auto.whenLeaving else { return }
        let advice = await services.commute.check(id)
        let arrival = advice?.arrival.map { "Arrive \($0.formatted(date: .omitted, time: .shortened))" }
        await services.notifier.commute(
            id,
            title: [commute.name, arrival].compactMap { $0 }.joined(separator: " · "),
            text: (advice?.headline ?? "Couldn't check the traffic.") + " Tap to send your ETA."
        )
    }
}
