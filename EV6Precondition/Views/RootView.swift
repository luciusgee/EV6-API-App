import PreconditionKit
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            CarView()
                .tabItem { Label("Car", systemImage: "car.fill") }
            ActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
