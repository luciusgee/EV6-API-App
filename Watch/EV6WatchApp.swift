import SwiftUI
import WatchConnectivity
import WidgetKit

@main
struct EV6WatchApp: App {
    @State private var link = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            WatchCarView()
                .environment(link)
        }
    }
}

/// Talks to the EV6 app on the iPhone: receives the car's state and asks it to send commands. The
/// Watch never talks to Kia itself, so it needs no sign-in and shares the phone's request budget.
@MainActor
@Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    private(set) var glance: CarGlance?
    private(set) var sending: GlanceCommand?
    var result: String?

    private static let savedKey = "glance"

    override private init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.savedKey) {
            glance = try? JSONDecoder().decode(CarGlance.self, from: data)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    fileprivate func received(_ data: Data?) {
        guard let data, let new = try? JSONDecoder().decode(CarGlance.self, from: data) else { return }
        guard new != glance else { return }
        glance = new
        UserDefaults.standard.set(data, forKey: Self.savedKey)
        // The complications read the same thing from the Keychain.
        GlanceKeychain.save(new)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func send(_ command: GlanceCommand) {
        guard sending == nil else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            result = "Can't reach your iPhone."
            return
        }
        sending = command
        result = nil
        session.sendMessage(["command": command.rawValue]) { reply in
            let message = reply["message"] as? String
            let data = reply["glance"] as? Data
            Task { @MainActor in
                let link = PhoneLink.shared
                link.received(data)
                link.result = message
                link.sending = nil
            }
        } errorHandler: { error in
            let text = (error as NSError).code == WCError.notReachable.rawValue
                ? "Your iPhone isn't nearby."
                : "Couldn't reach your iPhone."
            Task { @MainActor in
                let link = PhoneLink.shared
                link.result = text
                link.sending = nil
            }
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext["glance"] as? Data
        Task { @MainActor in PhoneLink.shared.received(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["glance"] as? Data
        Task { @MainActor in PhoneLink.shared.received(data) }
    }
}

// MARK: - Views

struct WatchCarView: View {
    @Environment(PhoneLink.self) private var link
    @State private var confirmUnlock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    header
                    if let result = link.result {
                        Text(result)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    controls
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("EV6")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        link.send(.refresh)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(link.sending != nil)
                }
            }
        }
        .confirmationDialog("Unlock the car?", isPresented: $confirmUnlock) {
            Button("Unlock", role: .destructive) { link.send(.unlock) }
        }
    }

    @ViewBuilder private var header: some View {
        if let g = link.glance {
            VStack(spacing: 2) {
                Image("WatchCar").resizable().scaledToFit()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(g.socPercent.map(String.init) ?? "–")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    if g.charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                }
                Text(g.rangeText ?? "–").font(.headline).foregroundStyle(.secondary)
                Gauge(value: Double(g.socPercent ?? 0), in: 0...100) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint((g.socPercent ?? 0) < 20 ? .orange : .green)
                Text(g.summary).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                (Text("Updated ") + Text(g.carReportedAt ?? g.fetchedAt, style: .relative) + Text(" ago"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 6) {
                Image("WatchCar").resizable().scaledToFit()
                Text("Open EV6 on your iPhone and sign in to Kia.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        let g = link.glance
        return VStack(spacing: 8) {
            if g?.climateOn == true {
                action(.climateStop, "Stop Climate", "fan.slash", .orange)
            } else {
                action(.climateStart, "Start Climate", "fan.fill", .orange)
            }
            HStack(spacing: 8) {
                action(.lock, "Lock", "lock.fill", .blue)
                Button {
                    confirmUnlock = true
                } label: {
                    buttonLabel("Unlock", "lock.open.fill", busy: link.sending == .unlock)
                }
                .tint(.blue)
                .disabled(link.sending != nil)
            }
            if g?.pluggedIn == true {
                if g?.charging == true {
                    action(.chargeStop, "Stop Charging", "bolt.slash.fill", .green)
                } else {
                    action(.chargeStart, "Start Charging", "bolt.fill", .green)
                }
            }
        }
    }

    private func action(_ command: GlanceCommand, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Button {
            link.send(command)
        } label: {
            buttonLabel(title, symbol, busy: link.sending == command)
        }
        .tint(tint)
        .disabled(link.sending != nil)
    }

    private func buttonLabel(_ title: String, _ symbol: String, busy: Bool) -> some View {
        HStack {
            if busy {
                ProgressView().frame(width: 18, height: 18)
            } else {
                Image(systemName: symbol)
            }
            Text(title).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
