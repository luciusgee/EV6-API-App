import PreconditionKit
import SwiftUI

/// Everything else: the scanner's other tools, the car, the connection and the app.
struct MoreView: View {
    @Environment(OBDService.self) private var obd
    @Environment(Store.self) private var store
    @Bindable var prefs: Preferences
    @State private var showingAdapters = false
    @State private var whatsNew = false
    @State private var showingPro = false

    var body: some View {
        NavigationStack {
            List {
                if Store.paywallEnabled && !store.isPro {
                    Section {
                        Button { showingPro = true } label: {
                            Label("Unlock \(AppInfo.name) Pro", systemImage: "bolt.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Tools") {
                    if prefs.platform == .egmp {
                        NavigationLink { ChargingView() } label: { Label("Charging", systemImage: "bolt.car") }
                    }
                    NavigationLink { LiveDataView() } label: { Label("Live data & graphs", systemImage: "waveform.path.ecg") }
                    NavigationLink { AllSensorsView() } label: { Label("All sensors", systemImage: "list.bullet.rectangle") }
                    NavigationLink { ModulesView() } label: { Label("Modules & VIN", systemImage: "cpu") }
                    NavigationLink { TripView() } label: { Label("Trip computer", systemImage: "road.lanes") }
                    NavigationLink { RecordingsView() } label: { Label("Recordings", systemImage: "record.circle") }
                }

                Section {
                    NavigationLink {
                        CarPicker(prefs: prefs)
                    } label: {
                        LabeledContent("Car", value: prefs.model.fullName)
                    }
                    if !prefs.model.packs.isEmpty {
                        Picker("Battery", selection: $prefs.packKWh) {
                            Text("Detect").tag(Double?.none)
                            ForEach(prefs.model.packs) { Text($0.label).tag(Double?.some($0.kWh)) }
                        }
                    }
                    Toggle("Detect the car when connecting", isOn: $prefs.autoDetect)
                    Toggle("Miles", isOn: $prefs.useMiles)
                    if let vin = prefs.vin {
                        LabeledContent("VIN") { Text(vin).font(.footnote.monospaced()).textSelection(.enabled) }
                    }
                } header: {
                    Text("Your car")
                } footer: {
                    Text("The battery's size sets its capacity in the battery report. Detect works it out from the number of cells and the model year.")
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
                    Text("Works with Bluetooth LE and Wi-Fi ELM327 adapters such as the Veepeak OBDCheck BLE, OBDLink CX and vLinker. The demo car is a simulated EV6, for trying everything without one.")
                }

                Section("About") {
                    Button("What's new") { whatsNew = true }
                    if Store.paywallEnabled {
                        Button("Restore purchase") { Task { await store.restore() } }
                    }
                    NavigationLink("Privacy") { InfoPage(title: "Privacy", text: AboutText.privacy) }
                    NavigationLink("Safety and disclaimer") { InfoPage(title: "Safety", text: AboutText.disclaimer) }
                    NavigationLink("Acknowledgements") { InfoPage(title: "Acknowledgements", text: AboutText.acknowledgements) }
                    LabeledContent("Version", value: AppInfo.version)
                }

                Section {
                } footer: {
                    Text("\(AppInfo.name) isn't made by, endorsed by or affiliated with Kia, Hyundai, Genesis or any other car maker. Car names are used only to say which cars it works with.")
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
            .sheet(isPresented: $whatsNew) { WhatsNewSheet() }
            .sheet(isPresented: $showingPro) { ProSheet() }
        }
    }
}

/// Every car the app knows, by maker.
struct CarPicker: View {
    @Bindable var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    var onPick: (() -> Void)?

    var body: some View {
        List {
            ForEach(["Kia", "Hyundai", "Genesis"], id: \.self) { make in
                Section(make) {
                    ForEach(Vehicles.models(make: make)) { row($0, name: $0.name) }
                }
            }
            Section {
                row(Vehicles.generic, name: "Any other car")
            } footer: {
                Text("Any petrol, diesel or hybrid car from 2001 (EU) or 1996 (US) on, and many EVs: speed, engine data, emission trouble codes and performance timing. Battery reports need one of the cars above.")
            }
        }
        .navigationTitle("Your car")
    }

    private func row(_ model: VehicleModel, name: String) -> some View {
        Button {
            prefs.modelId = model.id
            prefs.packKWh = nil
            if let onPick { onPick() } else { dismiss() }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if prefs.modelId == model.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

struct InfoPage: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AboutText {
    static let privacy = """
    \(AppInfo.name) collects nothing. There are no accounts, no analytics, no tracking and no adverts.

    Everything the app reads from your car (live data, battery reports, runs, laps, charges and recordings) is stored only on this iPhone, and goes nowhere unless you share it yourself.

    Bluetooth is used only to talk to your OBD adapter. Location is used only by the lap timer, while it's open, to see when you cross your start/finish line. Motion is used only to feel the moment the car pulls away during a timed run.

    Purchases are handled by Apple; the app never sees your payment details.
    """

    static let disclaimer = """
    Performance timing is for closed roads, tracks and drag strips only. Never use it on public roads. Obey the law, drive within your limits and the car's, and don't look at the phone while driving: mount it, and let the run finish by itself.

    \(AppInfo.name) reads data your car shares over its OBD port. Readings, battery reports and times are estimates for information only. They aren't a manufacturer's diagnosis, an official battery health certificate or certified timing. For a decision that matters (buying or selling a car, a warranty claim, a repair), ask a dealer.

    Clearing trouble codes doesn't fix anything; a real fault comes back. Leave the adapter unplugged when you're not using it, as some adapters draw power from the 12 V battery.

    The app reads data and clears codes; it never changes the car's settings or software.
    """

    static let acknowledgements = """
    Battery and vehicle data decoding for E-GMP cars is based on the Open Vehicle Monitoring System (OVMS) Hyundai Ioniq 5 / Kia EV6 vehicle module.

    Copyright (c) 2022–2026 Michael Geddes and the Open Vehicles contributors.

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    Standard OBD-II parameters follow SAE J1979 / ISO 15031.
    """
}
