import SwiftUI
import UIKit

/// Kia's studio renders of the 2022 EV6 GT-Line in Runway Red (Kia Canada's configurator): 36 frames,
/// 10° apart, turning the car a full circle. Frame 1 is the front three-quarter with the nose to the
/// left; dragging right brings the nose round towards you.
struct CarSpin: View {
    static let frames = 36
    /// Front three-quarter, like the photo in the Kia app.
    static let front = 1
    /// Rear three-quarter.
    static let rear = 27

    var rest = CarSpin.front
    var interactive = true
    @State private var frame: Int?
    @State private var dragStart: Int?

    private var shown: Int { frame ?? rest }

    var body: some View {
        Image("EV6Spin\(shown)")
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 210)
            .contentShape(Rectangle())
            // Alongside the page's scrolling: only sideways movement turns the car.
            .simultaneousGesture(drag, including: interactive ? .all : .subviews)
            .onTapGesture(count: 2) { if interactive { Task { await settle() } } }
            .sensoryFeedback(.selection, trigger: shown) { _, _ in frame != nil && shown % 3 == 0 }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = dragStart ?? shown
                dragStart = start
                // About 12 points of drag per 10° step.
                frame = Self.wrap(start + Int((value.translation.width / 12).rounded()))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Turns back to the resting angle the short way round, a frame at a time.
    private func settle() async {
        guard var current = frame else { return }
        let forward = Self.wrap(rest - current)
        let step = forward <= Self.frames / 2 ? 1 : -1
        while current != rest {
            current = Self.wrap(current + step)
            frame = current
            try? await Task.sleep(for: .milliseconds(20))
        }
        frame = nil
    }

    static func wrap(_ n: Int) -> Int { ((n - 1) % frames + frames) % frames + 1 }
}

/// Kia's render of your car, with charging and climate badges.
struct CarHeroImage: View {
    var rest = CarSpin.front
    var interactive = true
    let paint: CarPaint
    var charging = false
    var pluggedIn = false
    var climate: EV6Illustration.ClimateGlow?

    var body: some View {
        Group {
            if UIImage(named: "EV6Spin\(rest)") != nil {
                CarSpin(rest: rest, interactive: interactive)
            } else {
                EV6Illustration(paint: paint, charging: charging, pluggedIn: pluggedIn, climate: climate)
            }
        }
        .overlay(alignment: .topTrailing) {
            if charging || climate != nil {
                HStack(spacing: 6) {
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    if let climate { Image(systemName: climate == .heating ? "heat.waves" : "snowflake").foregroundStyle(climate == .heating ? .orange : .cyan) }
                }
                .font(.subheadline.weight(.semibold))
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .symbolEffect(.pulse)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Your EV6")
        .accessibilityHint(interactive ? "Drag to turn the car round." : "")
    }
}
