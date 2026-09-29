import PreconditionKit
import SwiftUI

/// The car's off-peak charging window: plug in any time and it waits until the window to charge.
struct OffPeakView: View {
    @Environment(CarModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var only: Bool
    @State private var pin = ""

    init(current: OffPeakWindow?) {
        let window = current ?? OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))
        _start = State(initialValue: Self.date(window.start))
        _end = State(initialValue: Self.date(window.end))
        _only = State(initialValue: window.onlyOffPeak)
    }

    var body: some View {
        Form {
            Section {
                DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                Toggle("Only charge in this window", isOn: $only)
            } footer: {
                Text(only
                    ? "The car won't charge outside these hours, even when a departure needs it."
                    : "The car charges in these hours when it can, and outside them if a departure needs more.")
            }
            if !model.hasPin {
                Section {
                    SecureField("Kia Connect PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                } footer: {
                    Text("Kia asks for your 4-digit PIN to change the schedule. It's kept in your iPhone's Keychain.")
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Send to car")
                        Spacer()
                        if model.busy != nil { ProgressView() }
                    }
                }
                .disabled(model.busy != nil || (!model.hasPin && pin.count < 4) || window == model.snapshot?.details?.offPeak)
            } footer: {
                if let current = model.snapshot?.details?.offPeak {
                    Text("The car has \(current.text)\(current.onlyOffPeak ? ", off-peak only" : ""). Your departure times stay as they are.")
                }
            }
        }
        .navigationTitle("Off-peak charging")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var window: OffPeakWindow {
        OffPeakWindow(start: Self.clock(start), end: Self.clock(end), onlyOffPeak: only)
    }

    private func save() async {
        if !model.hasPin {
            await model.saveCredentials(pin: pin)
        }
        await model.send(.setOffPeak(window))
        dismiss()
    }

    private static func date(_ t: ClockTime) -> Date {
        Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
    }

    private static func clock(_ d: Date) -> ClockTime {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}
