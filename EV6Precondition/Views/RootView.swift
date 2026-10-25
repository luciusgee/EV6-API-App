import PreconditionKit
import SwiftUI

struct RootView: View {
    @Environment(Preferences.self) private var prefs
    /// The newest What's new you've seen.
    @AppStorage("whatsNewSeen") private var seen = 0
    @State private var whatsNew = false
    /// The launch animation, once per cold start.
    @State private var splash = true

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Car", systemImage: "car.fill") }
            PerformanceView()
                .tabItem { Label("Performance", systemImage: "stopwatch.fill") }
            NavigationStack { BatteryHealthView() }
                .tabItem { Label("Battery", systemImage: "battery.100percent.bolt") }
            NavigationStack { TroubleCodesView() }
                .tabItem { Label("Codes", systemImage: "exclamationmark.triangle.fill") }
            MoreView(prefs: prefs)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
        .tint(.red)
        .overlay {
            if splash {
                LaunchSplash { splash = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $whatsNew, onDismiss: { seen = WhatsNew.latest }) {
            WhatsNewSheet()
        }
        .fullScreenCover(isPresented: Binding(get: { !splash && !prefs.onboarded }, set: { _ in })) {
            OnboardingView(prefs: prefs)
                .onDisappear { seen = WhatsNew.latest }
        }
        .task {
            guard seen < WhatsNew.latest, prefs.onboarded else { return }
            try? await Task.sleep(for: .seconds(2.6))
            whatsNew = true
        }
    }
}
