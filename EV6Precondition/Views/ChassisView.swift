import PreconditionKit
import SwiftUI

/// The car from above, drawn from what it reports: the battery pack's modules filling with charge (or
/// shaded by cell balance after a battery read), tyre pressures at each wheel, and energy flowing to
/// the motors, back from them under regen, or in from the charger. Original artwork, no badges.
struct ChassisView: View {
    var socPercent: Double?
    /// Battery power, kW: positive driving, negative regen or charging.
    var powerKW: Double?
    var charging = false
    var tyrePsi: [Double?] = []
    /// Module deviations from the pack's average, mV, from the last battery read.
    var modules: [Double] = []
    var electric = true
    var tint: Color = .red

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var flowing: Bool { abs(powerKW ?? 0) > 1 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !flowing)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(&ctx, size: size, phase: phase)
            }
        }
        .aspectRatio(0.62, contentMode: .fit)
        .overlay { labels }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let socPercent { parts.append(String(format: "Battery %.0f percent", socPercent)) }
        if charging { parts.append("charging") }
        else if flowing, let powerKW {
            parts.append(String(format: powerKW > 0 ? "drawing %.0f kilowatts" : "regenerating %.0f kilowatts", abs(powerKW)))
        }
        for (i, name) in ["front left", "front right", "rear left", "rear right"].enumerated() {
            guard tyrePsi.indices.contains(i), let psi = tyrePsi[i] else { continue }
            parts.append("\(name) tyre " + String(format: "%.1f psi", psi) + (psi < 33 ? ", low" : ""))
        }
        return parts.isEmpty ? "Your car" : parts.joined(separator: ", ")
    }

    // MARK: Drawing

    private func carRect(_ size: CGSize) -> CGRect {
        let w = size.width * 0.62, h = size.height * 0.94
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, phase: Double) {
        let car = carRect(size)
        let shell = Path(roundedRect: car, cornerSize: CGSize(width: car.width * 0.42, height: car.width * 0.5), style: .continuous)

        // Wheels, under the body.
        for (i, rect) in wheels(car).enumerated() {
            let psi = tyrePsi.indices.contains(i) ? tyrePsi[i] : nil
            let low = (psi ?? 99) < 33
            ctx.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.35), with: .color(low ? .orange : Color(white: 0.22)))
        }

        // Body and glass.
        ctx.fill(shell, with: .linearGradient(Gradient(colors: [Color(white: 0.17), Color(white: 0.09)]), startPoint: car.origin, endPoint: CGPoint(x: car.maxX, y: car.maxY)))
        ctx.stroke(shell, with: .color(.white.opacity(0.18)), lineWidth: 1.2)
        let screen = CGRect(x: car.minX + car.width * 0.12, y: car.minY + car.height * 0.2, width: car.width * 0.76, height: car.height * 0.13)
        ctx.fill(Path(roundedRect: screen, cornerRadius: car.width * 0.12), with: .color(.white.opacity(0.06)))
        let rear = CGRect(x: car.minX + car.width * 0.16, y: car.minY + car.height * 0.8, width: car.width * 0.68, height: car.height * 0.07)
        ctx.fill(Path(roundedRect: rear, cornerRadius: car.width * 0.1), with: .color(.white.opacity(0.06)))
        // Lights.
        for (y, color) in [(car.minY + car.height * 0.02, Color.white), (car.maxY - car.height * 0.025, Color.red)] {
            var light = Path()
            light.move(to: CGPoint(x: car.minX + car.width * 0.22, y: y))
            light.addLine(to: CGPoint(x: car.maxX - car.width * 0.22, y: y))
            ctx.stroke(light, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        guard electric else {
            // An engine bay, for cars read with standard OBD-II.
            let bay = CGRect(x: car.minX + car.width * 0.22, y: car.minY + car.height * 0.06, width: car.width * 0.56, height: car.height * 0.12)
            ctx.stroke(Path(roundedRect: bay, cornerRadius: 6), with: .color(tint.opacity(0.7)), lineWidth: 1.5)
            return
        }

        // The pack: modules in a grid, filled to the charge from the back.
        let pack = packRect(car)
        let cols = 4, rows = 8
        let gap = pack.width * 0.025
        let mw = (pack.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let mh = (pack.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let filled = Int(((socPercent ?? 0) / 100 * Double(rows * cols)).rounded())
        for r in 0..<rows {
            for c in 0..<cols {
                let n = r * cols + c
                let rect = CGRect(x: pack.minX + CGFloat(c) * (mw + gap), y: pack.minY + CGFloat(r) * (mh + gap), width: mw, height: mh)
                let fromBack = (rows - 1 - r) * cols + c
                let color: Color
                if modules.count >= rows * cols {
                    let dev = modules[n]
                    color = dev < -15 ? .orange : dev < -6 ? .yellow : dev > 6 ? .cyan : .mint
                } else {
                    color = fromBack < filled ? (charging ? .green : .mint) : Color(white: 0.25)
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color.opacity(fromBack < filled || !modules.isEmpty ? 0.85 : 0.6)))
            }
        }

        // Motors.
        let front = CGPoint(x: car.midX, y: car.minY + car.height * 0.15)
        let back = CGPoint(x: car.midX, y: car.minY + car.height * 0.86)
        for m in [front, back] {
            let r = car.width * 0.09
            let glow = flowing && !charging ? 0.9 : 0.25
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - r, y: m.y - r, width: r * 2, height: r * 2)), with: .color(tint.opacity(glow * 0.35)))
            ctx.stroke(Path(ellipseIn: CGRect(x: m.x - r, y: m.y - r, width: r * 2, height: r * 2)), with: .color(tint.opacity(glow)), lineWidth: 1.5)
        }

        // Energy flowing along the floor.
        guard flowing else { return }
        let p = powerKW ?? 0
        let speed = min(abs(p) / 60, 3) + 0.4
        let dash = StrokeStyle(lineWidth: 3, lineCap: .round, dash: [4, 10], dashPhase: CGFloat(-phase * 40 * speed * (p > 0 ? 1 : -1)))
        let color: Color = charging ? .green : (p > 0 ? .orange : .green)
        if charging {
            // From the charge port, rear right.
            var line = Path()
            line.move(to: CGPoint(x: car.maxX + 2, y: car.minY + car.height * 0.78))
            line.addLine(to: CGPoint(x: pack.maxX, y: pack.maxY - pack.height * 0.1))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [4, 10], dashPhase: CGFloat(phase * 40 * speed)))
        } else {
            for (from, to) in [(CGPoint(x: car.midX, y: pack.minY), front), (CGPoint(x: car.midX, y: pack.maxY), back)] {
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                ctx.stroke(line, with: .color(color), style: dash)
            }
        }
    }

    private func packRect(_ car: CGRect) -> CGRect {
        CGRect(x: car.minX + car.width * 0.14, y: car.minY + car.height * 0.36, width: car.width * 0.72, height: car.height * 0.42)
    }

    private func wheels(_ car: CGRect) -> [CGRect] {
        let w = car.width * 0.17, h = car.height * 0.15
        let xs = [car.minX - w * 0.45, car.maxX - w * 0.55]
        let ys = [car.minY + car.height * 0.1, car.minY + car.height * 0.72]
        // Front left, front right, rear left, rear right.
        return [CGRect(x: xs[0], y: ys[0], width: w, height: h), CGRect(x: xs[1], y: ys[0], width: w, height: h),
                CGRect(x: xs[0], y: ys[1], width: w, height: h), CGRect(x: xs[1], y: ys[1], width: w, height: h)]
    }

    // MARK: Labels

    private var labels: some View {
        GeometryReader { geo in
            let car = carRect(geo.size)
            let wheels = wheels(car)
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    if tyrePsi.indices.contains(i), let psi = tyrePsi[i] {
                        // The glyph marks a low tyre without relying on colour.
                        Text(psi < 33 ? String(format: "! %.1f", psi) : String(format: "%.1f", psi))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(psi < 33 ? .orange : .secondary)
                            .position(x: i % 2 == 0 ? wheels[i].minX - 18 : wheels[i].maxX + 18, y: wheels[i].midY)
                    }
                }
                if electric, let socPercent {
                    let pack = packRect(car)
                    Text(String(format: "%.0f%%", socPercent))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .position(x: pack.midX, y: pack.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
