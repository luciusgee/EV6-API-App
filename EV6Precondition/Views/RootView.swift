import PreconditionKit
import SwiftUI

struct RootView: View {
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
    }
}
