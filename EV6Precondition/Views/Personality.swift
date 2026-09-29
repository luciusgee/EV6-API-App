import SwiftUI

// The app's bits of character: the launch sequence, the light behind the car, the energy in the
// battery bar and the feel of the buttons. All of it calms down with Reduce Motion.

// MARK: - Launch

/// The opening moment: the EV6's thin daytime running lights draw out from the middle, the car rolls
/// in under them, then the name. Tap to skip.
struct LaunchSplash: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lights = false
    @State private var car = false
    @State private var name = false
    @State private var leaving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.55, green: 0.08, blue: 0.08).opacity(car ? 0.35 : 0), .clear],
                           center: .center, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                // The "digital tiger face" light bar.
                HStack(spacing: 18) {
                    lightBar
                    lightBar
                }
                .frame(height: 6)

                Image("EV6Spin1")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 340)
                    .offset(x: car ? 0 : 90)
                    .opacity(car ? 1 : 0)
                    .blur(radius: car ? 0 : 6)

                VStack(spacing: 8) {
                    KiaLogo().frame(width: 74, height: 18)
                    Text("MY EV6")
                        .font(.system(size: 15, weight: .heavy))
                        .tracking(8)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .opacity(name ? 1 : 0)
                .offset(y: name ? 0 : 8)
            }
            .foregroundStyle(.white)
            .scaleEffect(leaving ? 1.06 : 1)
        }
        .opacity(leaving ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await play() }
        .accessibilityHidden(true)
    }

    private var lightBar: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white, Color(red: 0.75, green: 0.9, blue: 1)], startPoint: .leading, endPoint: .trailing))
            .frame(width: lights ? 120 : 0, height: 4)
            .shadow(color: .white.opacity(0.9), radius: lights ? 10 : 0)
            .shadow(color: Color(red: 0.6, green: 0.85, blue: 1).opacity(0.8), radius: lights ? 22 : 0)
    }

    private func play() async {
        if reduceMotion {
            lights = true; car = true; name = true
            try? await Task.sleep(for: .milliseconds(600))
            finish()
            return
        }
        withAnimation(.easeOut(duration: 0.45)) { lights = true }
        try? await Task.sleep(for: .milliseconds(260))
        withAnimation(.spring(duration: 0.7, bounce: 0.15)) { car = true }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.easeOut(duration: 0.4)) { name = true }
        try? await Task.sleep(for: .milliseconds(750))
        finish()
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(.easeIn(duration: 0.35)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(360))
            onFinish()
        }
    }
}

// MARK: - The stage behind the car

/// What the car's doing, for the light around it.
enum CarMood: Equatable {
    case idle, charging, heating, cooling

    var colour: Color {
        switch self {
        case .idle: return Color(red: 0.55, green: 0.1, blue: 0.1)
        case .charging: return .green
        case .heating: return .orange
        case .cooling: return .cyan
        }
    }
}

/// A pool of light under the car in the mood's colour. Charging sends sparks of energy up past the car,
/// heating breathes warm, cooling drifts cold flecks down.
struct CarStage: View {
    let mood: CarMood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if mood == .idle || reduceMotion {
            floor(pulse: 0.5)
                .animation(.easeInOut(duration: 0.8), value: mood)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    floor(pulse: 0.5 + 0.5 * sin(t * (mood == .charging ? 2.2 : 1.4)))
                    particles(t: t)
                }
            }
            .transition(.opacity)
        }
    }

    private func floor(pulse: Double) -> some View {
        let strength = mood == .idle ? 0.22 : 0.35 + 0.25 * pulse
        return GeometryReader { geo in
            Ellipse()
                .fill(RadialGradient(colors: [mood.colour.opacity(strength), mood.colour.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: geo.size.width * 0.5))
                .frame(width: geo.size.width * 1.1, height: geo.size.height * 0.55)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.72)
                .blur(radius: 18)
        }
    }

    /// Deterministic flecks, so nothing needs storing: each has its own lane, speed and phase.
    private func particles(t: Double) -> some View {
        Canvas { gc, size in
            let count = mood == .charging ? 22 : 16
            gc.addFilter(.blur(radius: 0.6))
            for i in 0..<count {
                let seed = Double(i) * 12.9898
                let lane = abs(sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let speed = 0.08 + 0.1 * abs(sin(seed * 1.7))
                let phase = abs(cos(seed * 3.1))
                var progress = (t * speed + phase).truncatingRemainder(dividingBy: 1)
                if mood == .cooling { progress = 1 - progress }
                let x = size.width * (0.12 + 0.76 * lane) + sin(t * 1.3 + seed) * (mood == .heating ? 6 : 3)
                let y = size.height * (0.95 - 0.85 * progress)
                // Fade in and out along the way.
                let alpha = sin(progress * .pi) * (mood == .charging ? 0.85 : 0.6)
                let r = mood == .charging ? 1.6 + 1.4 * abs(sin(seed)) : 1.2 + 1.8 * abs(cos(seed))
                let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                gc.fill(Path(ellipseIn: rect), with: .color(mood.colour.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Battery bar

/// The charge as a bar. While charging, light runs along the filled part towards the tip.
struct EnergyBar: View {
    let fraction: Double
    let tint: Color
    /// The AC charge limit, marked on the bar.
    let limit: Int?
    var charging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, min(1, fraction)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: filled)
                    .shadow(color: charging ? tint.opacity(0.7) : .clear, radius: 6)
                if charging && !reduceMotion && filled > 12 {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let x = (t * 0.55).truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 46)
                            .offset(x: -46 + (filled + 46) * x)
                    }
                    .frame(width: filled, alignment: .leading)
                    .clipShape(Capsule())
                    .blendMode(.plusLighter)
                }
                if let limit, limit < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2)
                        .offset(x: geo.size.width * Double(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 10)
        .animation(.spring(duration: 0.8), value: fraction)
    }
}

// MARK: - Buttons

/// Sinks a little under your finger and springs back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Turns a symbol slowly while `active`, like a fan running.
struct Spinning: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                content.rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360)))
            }
        } else {
            content
        }
    }
}

extension View {
    func spinning(_ active: Bool) -> some View { modifier(Spinning(active: active)) }
}
