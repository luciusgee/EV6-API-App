import UIKit

/// The one owner of the idle timer: the screen stays on while anything holds it.
@MainActor
enum ScreenAwake {
    private static var reasons: Set<String> = []

    static func hold(_ reason: String) {
        reasons.insert(reason)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release(_ reason: String) {
        reasons.remove(reason)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
