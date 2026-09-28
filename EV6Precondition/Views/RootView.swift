import PreconditionKit
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            CarView()
                .tabItem { Label("Car", systemImage: "car.fill") }
            RulesView()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
