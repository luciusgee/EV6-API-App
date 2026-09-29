import PreconditionKit
import SwiftUI

/// Reads trouble codes from every module, explains them, and clears them.
struct TroubleCodesView: View {
    @Environment(OBDService.self) private var obd
    @State private var modules: [ECU] = []
    @State private var codes: [UInt16: [TroubleCode]] = [:]
    @State private var emission: [TroubleCode] = []
    @State private var progress: (Int, Int)?
    @State private var scanned = false
    @State private var error: String?
    @State private var confirmClear: ECU?
    @State private var confirmClearAll = false
    @State private var detail: TroubleCode?

    private var total: Int { codes.values.reduce(0) { $0 + $1.count } + emission.count }

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label(scanned ? "Scan Again" : "Scan All Modules", systemImage: "magnifyingglass")
                        Spacer()
                        if progress != nil { ProgressView() }
                    }
                }
                .disabled(obd.carState != .connected || progress != nil)
                if let progress {
                    ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1))) {
                        Text("Checking module \(progress.0) of \(progress.1)").font(.caption)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.orange).font(.footnote)
                }
            } footer: {
                if scanned && progress == nil {
                    Text(total == 0
                        ? "No trouble codes in \(modules.count) modules."
                        : "\(total) code\(total == 1 ? "" : "s") in \(modules.count) modules.")
                } else {
                    Text("Asks each module for its stored, pending and active codes. Takes about 20 seconds with the car switched on.")
                }
            }

            if !emission.isEmpty {
                Section("Emission codes (OBD-II)") {
                    ForEach(emission) { code in CodeRow(code: code) { detail = code } }
                }
            }

            ForEach(modules) { ecu in
                let list = codes[ecu.header] ?? []
                Section {
                    if list.isEmpty {
                        Label("No codes", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(list) { code in CodeRow(code: code) { detail = code } }
                } header: {
                    HStack {
                        Text(ecu.name)
                        Spacer()
                        if !list.isEmpty {
                            Button("Clear") { confirmClear = ecu }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Trouble Codes")
        .toolbar {
            if total > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear All", role: .destructive) { confirmClearAll = true }
                }
            }
        }
        .confirmationDialog(
            "Clear codes in \(confirmClear?.name ?? "")?",
            isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } }),
            titleVisibility: .visible
        ) {
            Button("Clear Codes", role: .destructive) {
                if let ecu = confirmClear { Task { await clear([ecu]) } }
            }
        } message: {
            Text("Clearing doesn't fix anything: a real fault comes straight back. Note the codes first.")
        }
        .confirmationDialog("Clear all trouble codes?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All Codes", role: .destructive) {
                Task { await clear(modules.filter { !(codes[$0.header] ?? []).isEmpty }, emission: !emission.isEmpty) }
            }
        } message: {
            Text("Clearing doesn't fix anything: a real fault comes straight back. The car must be switched on, and not driving.")
        }
        .sheet(item: $detail) { code in
            CodeDetail(code: code)
        }
    }

    private func scan() async {
        guard let elm = obd.elm else { return }
        let diag = Diagnostics(elm: elm)
        error = nil
        progress = (0, ECU.egmp.count)
        defer { progress = nil }
        do {
            modules = try await diag.scan { i, n in await MainActor.run { progress = (i, n) } }
            var found: [UInt16: [TroubleCode]] = [:]
            for ecu in modules {
                found[ecu.header] = (try? await diag.troubleCodes(ecu)) ?? []
            }
            codes = found
            emission = (try? await diag.emissionCodes()) ?? []
            scanned = true
        } catch {
            self.error = (error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription
        }
    }

    private func clear(_ ecus: [ECU], emission clearEmission: Bool = false) async {
        guard let elm = obd.elm else { return }
        let diag = Diagnostics(elm: elm)
        var failed: [String] = []
        for ecu in ecus {
            do {
                try await diag.clear(ecu)
                codes[ecu.header] = (try? await diag.troubleCodes(ecu)) ?? []
            } catch {
                failed.append(ecu.name)
            }
        }
        if clearEmission {
            try? await diag.clearEmissionCodes()
            emission = (try? await diag.emissionCodes()) ?? []
        }
        error = failed.isEmpty ? nil : "Couldn't clear: \(failed.joined(separator: ", ")). Some modules only clear with the car in ready mode."
    }
}

private struct CodeRow: View {
    let code: TroubleCode
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: code.isActive ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code.isActive ? .red : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(code.displayCode).font(.body.monospaced().weight(.semibold))
                    Text(code.meaning ?? "\(code.system) fault (manufacturer-specific)")
                        .font(.subheadline)
                    Text(code.stateText.capitalizingFirst)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct CodeDetail: View {
    @Environment(OBDService.self) private var obd
    @Environment(\.dismiss) private var dismiss
    let code: TroubleCode
    @State private var snapshot: [UInt8]?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Code", value: code.displayCode)
                    LabeledContent("System", value: code.system)
                    LabeledContent("Module", value: ECU.named(code.ecuHeader).name)
                    LabeledContent("Status", value: code.stateText.capitalizingFirst)
                    if let meaning = code.meaning {
                        Text(meaning)
                    }
                } footer: {
                    Text("Codes starting P1, C1, B1 and U1–U3 are Kia/Hyundai's own; a dealer or Car Scanner Pro has the full descriptions. Search \"EV6 \(code.code)\" for owners' experiences.")
                }
                if !code.raw.isEmpty {
                    Section {
                        if let snapshot {
                            Text(snapshot.isEmpty ? "No snapshot stored." : ISOTP.hex(snapshot))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Button {
                                Task { await load() }
                            } label: {
                                HStack {
                                    Text("Read Snapshot Data")
                                    Spacer()
                                    if loading { ProgressView() }
                                }
                            }
                        }
                    } header: {
                        Text("Freeze frame")
                    } footer: {
                        Text("What the module recorded when the fault happened. The layout is Kia's own, so it's shown as raw bytes.")
                    }
                }
            }
            .navigationTitle(code.displayCode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let elm = obd.elm else { return }
        loading = true
        snapshot = (try? await Diagnostics(elm: elm).snapshot(code)) ?? []
        loading = false
    }
}

/// VIN, the modules fitted, what each reports about itself, and the standard PIDs the car supports.
struct ModulesView: View {
    @Environment(OBDService.self) private var obd
    @State private var vin: String?
    @State private var modules: [ECU] = []
    @State private var identities: [UInt16: ECUIdentity] = [:]
    @State private var pids: [UInt8] = []
    @State private var progress: (Int, Int)?
    @State private var done = false

    var body: some View {
        List {
            NotConnectedHint()
            Section {
                Button {
                    Task { await read() }
                } label: {
                    HStack {
                        Label(done ? "Read Again" : "Read Modules", systemImage: "cpu")
                        Spacer()
                        if progress != nil { ProgressView() }
                    }
                }
                .disabled(obd.carState != .connected || progress != nil)
                if let progress {
                    ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1)))
                }
                if let adapter = obd.adapterVersion {
                    LabeledContent("Adapter", value: adapter)
                }
                if let vin {
                    LabeledContent("VIN") { Text(vin).font(.body.monospaced()).textSelection(.enabled) }
                }
            }
            if !modules.isEmpty {
                Section("\(modules.count) modules answered") {
                    ForEach(modules) { ecu in
                        DisclosureGroup {
                            let fields = identities[ecu.header]?.fields ?? []
                            if fields.isEmpty {
                                Text("No identifiers reported").foregroundStyle(.secondary)
                            }
                            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                                LabeledContent(field.0) {
                                    Text(field.1).font(.footnote.monospaced()).textSelection(.enabled)
                                }
                            }
                        } label: {
                            LabeledContent(ecu.name, value: ecu.address)
                        }
                    }
                }
            }
            if !pids.isEmpty {
                Section {
                    Text(pids.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.footnote.monospaced())
                } header: {
                    Text("Standard OBD-II PIDs supported")
                } footer: {
                    Text("EVs support only a few of the standard petrol-car values; the EV6's real data is in its own module identifiers, which All Sensors reads.")
                }
            }
        }
        .navigationTitle("Modules & VIN")
    }

    private func read() async {
        guard let elm = obd.elm else { return }
        let diag = Diagnostics(elm: elm)
        progress = (0, ECU.egmp.count)
        defer { progress = nil }
        vin = await diag.vin()
        modules = (try? await diag.scan { i, n in await MainActor.run { progress = (i, n) } }) ?? []
        for (i, ecu) in modules.enumerated() {
            progress = (i + 1, modules.count)
            identities[ecu.header] = await diag.identity(ecu)
            if vin == nil, let v = identities[ecu.header]?.fields.first(where: { $0.0 == "VIN" })?.1 { vin = v }
        }
        pids = await diag.supportedPIDs().filter { $0 % 0x20 != 0 }.sorted()
        done = true
    }
}
