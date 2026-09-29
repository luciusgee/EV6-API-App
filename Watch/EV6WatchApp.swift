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
            VStack(spacing: 6) {
                ChargeRing(glance: g)
                if let plan = g.plan {
                    Label(plan, systemImage: g.charging ? "bolt.fill" : (g.pluggedIn ? "clock.fill" : "powerplug"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(g.pluggedIn ? Color.green : .secondary)
                        .multilineTextAlignment(.center)
                }
                (Text("Updated ") + Text(g.carReportedAt ?? g.fetchedAt, style: .relative) + Text(" ago"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 6) {
                Image("WatchCar").resizable().scaledToFit()
                Text("Open My EV6 on your iPhone and sign in to Kia.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        let g = link.glance
        return VStack(spacing: 8) {
            Button {
                link.send(g?.climateOn == true ? .climateStop : .climateStart)
            } label: {
                buttonLabel(g?.climateOn == true ? "Stop Climate" : "Precondition",
                            g?.climateOn == true ? "fan.slash.fill" : "fan.fill",
                            busy: link.sending == .climateStart || link.sending == .climateStop)
                    .font(.headline)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.orange)
            .disabled(link.sending != nil)
            if let next = g?.next {
                Text("Next: \(next)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

/// The charge as a ring round the face, with the car and the numbers inside.
struct ChargeRing: View {
    let glance: CarGlance

    private var fraction: Double { Double(glance.socPercent ?? 0) / 100 }
    private var tint: Color { (glance.socPercent ?? 0) < 20 ? .orange : .green }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 7)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: [tint.opacity(0.6), tint], center: .center, startAngle: .zero, endAngle: .degrees(360 * fraction)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(glance.climateOn ? "Climate on" : "Climate off")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(glance.climateOn ? Color.orange : .secondary)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(glance.socPercent.map(String.init) ?? "–")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.headline).foregroundStyle(.secondary)
                    if glance.charging { Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.green) }
                }
                Text([glance.rangeText, glance.pluggedIn ? "plugged in" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image("WatchCar").resizable().scaledToFit().frame(maxHeight: 34).padding(.top, 2)
            }
            .padding(14)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 2)
    }
}
