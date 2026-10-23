import PreconditionKit
import SwiftUI

/// Everything else: the scanner's other tools, and settings.
struct MoreView: View {
    @Environment(OBDService.self) private var obd
    @Bindable var prefs: Preferences
    @State private var showingAdapters = false
    @State private var whatsNew = false

    var body: some View {
        NavigationStack {
            List {
                Section("Scanner") {
                    NavigationLink { LiveDataView() } label: { Label("Live data & graphs", systemImage: "waveform.path.ecg") }
                    NavigationLink { AllSensorsView() } label: { Label("All sensors", systemImage: "list.bullet.rectangle") }
                    NavigationLink { ModulesView() } label: { Label("Modules & VIN", systemImage: "cpu") }
                    NavigationLink { TripView() } label: { Label("Trip computer", systemImage: "road.lanes") }
                    NavigationLink { RecordingsView() } label: { Label("Recordings", systemImage: "record.circle") }
                }

                Section("Your car") {
                    Picker("Car", selection: $prefs.car) {
                        ForEach(CarKind.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Miles", isOn: $prefs.useMiles)
                }

                Section {
                    LabeledContent("Adapter", value: obd.adapterText)
                    LabeledContent("Car", value: obd.carText)
                    if let version = obd.adapterVersion {
                        LabeledContent("Adapter version", value: version)
                    }
                    Button("Choose adapter…") { showingAdapters = true }
                    if obd.link.hasRemembered {
                        Button("Forget \(obd.link.rememberedName ?? "adapter")", role: .destructive) { obd.link.forgetAdapter() }
                    }
                    if obd.demo == nil {
                        Button("Use the demo car") { obd.startDemo() }
                    } else {
                        Button("Stop the demo car", role: .destructive) { obd.disconnect() }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Works with Bluetooth LE and Wi-Fi ELM327 adapters such as the Veepeak OBDCheck BLE, OBDLink CX and vLinker. The demo car is a simulated EV6, for trying everything out without one.")
                }

                Section {
                    Button("What's new") { whatsNew = true }
                    LabeledContent("Version", value: AppInfo.version)
                } footer: {
                    Text("\(AppInfo.name) reads data your car shares over its OBD port. It isn't made by, or affiliated with, Kia, Hyundai or Genesis. Readings are for information only: they aren't a manufacturer's diagnosis.")
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
            .sheet(isPresented: $whatsNew) { WhatsNewSheet() }
        }
    }
}
