import PreconditionKit
import SwiftUI

struct RootView: View {
    @State private var asks = AskCoordinator.shared

    var body: some View {
        TabView {
            CarView()
                .tabItem { Label("Car", systemImage: "car.fill") }
            RulesView()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            ScannerView()
                .tabItem { Label("Scanner", systemImage: "stethoscope") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        // An "ask first" question tapped open from its notification.
        .alert(asks.pending.map(AskPlanner.title) ?? "", isPresented: Binding(
            get: { asks.pending != nil },
            set: { if !$0 { asks.pending = nil } }
        ), presenting: asks.pending) { rule in
            Button("Start now") { Task { await asks.run(rule) } }
            Button("In 15 min") { Task { await asks.answer(rule.id, .later) } }
            Button("Not today", role: .cancel) {}
        }
    }
}
