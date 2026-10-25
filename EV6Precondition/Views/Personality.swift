import SwiftUI

// The app's bits of character. All of it calms down with Reduce Motion.

/// The opening moment: the gauge from the app icon sweeps round, the bolt lights, then the name.
/// Tap to skip.
struct LaunchSplash: View {
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0
    @State private var bolt = false
    @State private var name = false
    @State private var leaving = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.2), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 34) {
                ZStack {
                    GaugeArc(fraction: 1)
                        .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    GaugeArc(fraction: sweep)
                        .stroke(
                            AngularGradient(colors: [.red, .orange, .orange], center: .center, startAngle: .degrees(135), endAngle: .degrees(405)),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round)
                        )
                        .shadow(color: .orange.opacity(0.7), radius: 16)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(bolt ? 0.8 : 0), radius: 14)
                        .scaleEffect(bolt ? 1 : 0.6)
                        .opacity(bolt ? 1 : 0)
                }
                .frame(width: 190, height: 190)
                Text(AppInfo.name.uppercased())
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(9)
                    .foregroundStyle(.white.opacity(0.9))
                    .opacity(name ? 1 : 0)
                    .offset(y: name ? 0 : 8)
            }
            .scaleEffect(leaving ? 1.06 : 1)
        }
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await play() }
        .accessibilityHidden(true)
    }

    private func play() async {
        if reduceMotion {
            sweep = 0.78; bolt = true; name = true
            try? await Task.sleep(for: .milliseconds(600))
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 0.8)) { sweep = 0.78 }
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.spring(duration: 0.45, bounce: 0.4)) { bolt = true }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeOut(duration: 0.4)) { name = true }
        try? await Task.sleep(for: .milliseconds(700))
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

/// A 270° gauge arc, open at the bottom, filled to `fraction`.
struct GaugeArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r, startAngle: .degrees(135), endAngle: .degrees(135 + 270 * min(max(fraction, 0), 1)), clockwise: false)
        return p
    }
}
