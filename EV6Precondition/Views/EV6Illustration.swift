import SwiftUI

/// Kia's EV6 GT-Line paint options, for the picture on the dashboard.
enum CarPaint: String, CaseIterable, Identifiable {
    case snowWhitePearl, glacier, steelGrey, moonscape, gravityGrey, interstellarGrey, auroraBlackPearl, runwayRed, yachtBlue

    var id: String { rawValue }

    var name: String {
        switch self {
        case .snowWhitePearl: return "Snow White Pearl"
        case .glacier: return "Glacier"
        case .steelGrey: return "Steel Grey"
        case .moonscape: return "Moonscape Matte"
        case .gravityGrey: return "Gravity Grey"
        case .interstellarGrey: return "Interstellar Grey"
        case .auroraBlackPearl: return "Aurora Black Pearl"
        case .runwayRed: return "Runway Red"
        case .yachtBlue: return "Yacht Blue"
        }
    }

    /// sRGB, 0–1.
    var rgb: (Double, Double, Double) {
        switch self {
        case .snowWhitePearl: return (0.93, 0.94, 0.95)
        case .glacier: return (0.79, 0.83, 0.84)
        case .steelGrey: return (0.47, 0.50, 0.53)
        case .moonscape: return (0.55, 0.56, 0.54)
        case .gravityGrey: return (0.30, 0.32, 0.34)
        case .interstellarGrey: return (0.23, 0.25, 0.27)
        case .auroraBlackPearl: return (0.10, 0.11, 0.13)
        case .runwayRed: return (0.64, 0.08, 0.14)
        case .yachtBlue: return (0.12, 0.22, 0.37)
        }
    }

    var isMatte: Bool { self == .moonscape }

    func shade(_ amount: Double) -> Color {
        let (r, g, b) = rgb
        func mix(_ c: Double) -> Double { amount >= 0 ? c + (1 - c) * amount : c * (1 + amount) }
        return Color(red: mix(r), green: mix(g), blue: mix(b))
    }

    var swatch: Color { shade(0) }

    static let storageKey = "carPaint"
}

/// A 2022 EV6 GT-Line in profile, drawn from its real proportions (4.70 m long, 20-inch wheels).
/// Charging makes the charge port pulse; running climate warms (or cools) the cabin glass.
struct EV6Illustration: View {
    var paint: CarPaint
    var charging = false
    var pluggedIn = false
    /// Nil when climate is off.
    var climate: ClimateGlow?

    enum ClimateGlow { case heating, cooling }

    var body: some View {
        if charging || climate != nil {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                canvas(pulse: 0.5 + 0.5 * sin(t * 2.4))
            }
        } else {
            canvas(pulse: 0)
        }
    }

    private func canvas(pulse: Double) -> some View {
        Canvas { ctx, size in
            EV6Drawing.draw(in: &ctx, size: size, paint: paint, charging: charging, pluggedIn: pluggedIn, climate: climate, pulse: pulse)
        }
        .aspectRatio(EV6Geometry.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

enum EV6Drawing {
    static func draw(
        in ctx: inout GraphicsContext, size: CGSize, paint: CarPaint, charging: Bool, pluggedIn: Bool,
        climate: EV6Illustration.ClimateGlow?, pulse: Double
    ) {
        let map = EV6Geometry.Mapping(size: size)
        let dark = Color(red: 0.09, green: 0.10, blue: 0.12)
        let body = map.path(EV6Geometry.body)
        let bodyTop = map.point(0, 1.6)
        let bodyBottom = map.point(0, 0.3)

        // Ground shadow.
        let shadowRect = CGRect(x: map.point(0.1, 0).x, y: map.point(0, 0.05).y, width: map.scale * 4.5, height: map.scale * 0.1)
        ctx.fill(Path(ellipseIn: shadowRect), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.35), .black.opacity(0)]),
            center: CGPoint(x: shadowRect.midX, y: shadowRect.midY), startRadius: 0, endRadius: shadowRect.width / 2
        ))

        // Paint, lit from above.
        ctx.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: paint.shade(paint.isMatte ? 0.12 : 0.35), location: 0),
                .init(color: paint.shade(0.05), location: 0.35),
                .init(color: paint.shade(-0.05), location: 0.55),
                .init(color: paint.shade(-0.35), location: 1),
            ]),
            startPoint: bodyTop, endPoint: bodyBottom
        ))
        // A long reflection along the shoulder.
        if !paint.isMatte {
            var shine = ctx
            shine.clip(to: body)
            let band = map.path([.m(0.2, 1.02), .c(1.4, 1.02, 3.0, 0.98, 4.6, 0.82), .l(4.6, 0.76), .c(3.0, 0.9, 1.4, 0.95, 0.2, 0.95), .z])
            shine.fill(band, with: .color(.white.opacity(0.18)))
        }
        ctx.stroke(body, with: .color(.black.opacity(0.35)), lineWidth: max(0.5, map.scale * 0.008))

        // Glass, tinted by the climate.
        let glass = map.path(EV6Geometry.glass)
        ctx.fill(glass, with: .linearGradient(
            Gradient(colors: [Color(red: 0.20, green: 0.25, blue: 0.33), Color(red: 0.07, green: 0.08, blue: 0.11)]),
            startPoint: map.point(0, 1.5), endPoint: map.point(0, 1.1)
        ))
        if let climate {
            let tint: Color = climate == .heating ? Color(red: 1.0, green: 0.55, blue: 0.2) : Color(red: 0.35, green: 0.75, blue: 1.0)
            ctx.fill(glass, with: .radialGradient(
                Gradient(colors: [tint.opacity(0.35 + 0.25 * pulse), tint.opacity(0.05)]),
                center: map.point(2.0, 1.25), startRadius: 0, endRadius: map.scale * 1.4
            ))
        }
        // Sky reflection across the glass.
        var glare = ctx
        glare.clip(to: glass)
        glare.fill(map.path([.m(2.9, 1.5), .l(3.2, 1.5), .l(2.5, 1.0), .l(2.2, 1.0), .z]), with: .color(.white.opacity(0.10)))
        glare.fill(map.path([.m(1.5, 1.5), .l(1.62, 1.5), .l(1.0, 1.0), .l(0.88, 1.0), .z]), with: .color(.white.opacity(0.07)))

        let w = map.scale
        ctx.stroke(map.path(EV6Geometry.pillar), with: .color(dark), lineWidth: w * 0.05)
        ctx.stroke(map.path(EV6Geometry.belt), with: .color(Color(white: 0.86)), style: StrokeStyle(lineWidth: w * 0.025, lineCap: .round))
        ctx.stroke(map.path(EV6Geometry.crease), with: .color(.black.opacity(0.22)), style: StrokeStyle(lineWidth: w * 0.012, lineCap: .round))
        ctx.stroke(map.path(EV6Geometry.crease).offsetBy(dx: 0, dy: -w * 0.012), with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: w * 0.008, lineCap: .round))
        ctx.stroke(map.path(EV6Geometry.sill), with: .color(dark), lineWidth: w * 0.1)
        ctx.stroke(map.path(EV6Geometry.cladding), with: .color(dark), lineWidth: w * 0.07)
        ctx.fill(map.path(EV6Geometry.mirror), with: .color(dark))
        ctx.stroke(map.path(EV6Geometry.intake), with: .color(dark), style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
        ctx.stroke(map.path(EV6Geometry.handles), with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: w * 0.018, lineCap: .round))

        // Lights: the thin daytime running light and the full-width tail light.
        let head = map.path(EV6Geometry.head)
        ctx.stroke(head, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round))
        var bloom = ctx
        bloom.addFilter(.blur(radius: w * 0.04))
        bloom.stroke(head, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: w * 0.05, lineCap: .round))
        ctx.stroke(map.path(EV6Geometry.tail), with: .color(Color(red: 0.86, green: 0.1, blue: 0.2)), style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round))

        // Charge port: outlined, green and breathing while charging.
        let port = map.path(EV6Geometry.port)
        if charging || pluggedIn {
            let green = Color(red: 0.2, green: 0.9, blue: 0.45)
            var glow = ctx
            glow.addFilter(.blur(radius: w * 0.06))
            glow.fill(port, with: .color(green.opacity(charging ? 0.4 + 0.5 * pulse : 0.35)))
            ctx.fill(port, with: .color(green.opacity(charging ? 0.7 : 0.45)))
        }
        ctx.stroke(port, with: .color(.black.opacity(0.3)), lineWidth: max(0.5, w * 0.006))

        for x in [0.88, 3.78] { drawWheel(in: &ctx, centre: map.point(x, 0.37), radius: w * 0.37) }
    }

    /// 20-inch GT-Line alloy: five split spokes, dark with machined faces.
    static func drawWheel(in ctx: inout GraphicsContext, centre: CGPoint, radius r: CGFloat) {
        let tyre = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(tyre, with: .color(Color(white: 0.08)))
        let rimR = r * 0.72
        let rim = Path(ellipseIn: CGRect(x: centre.x - rimR, y: centre.y - rimR, width: 2 * rimR, height: 2 * rimR))
        ctx.fill(rim, with: .radialGradient(
            Gradient(colors: [Color(white: 0.28), Color(white: 0.16)]), center: centre, startRadius: 0, endRadius: rimR
        ))
        ctx.stroke(rim, with: .color(Color(white: 0.55)), lineWidth: r * 0.04)
        for i in 0..<5 {
            for side in [-1.0, 1.0] {
                let a = Double(i) * 2 * .pi / 5 - .pi / 2 + side * 0.13
                var spoke = Path()
                spoke.move(to: CGPoint(x: centre.x + cos(a) * r * 0.16, y: centre.y + sin(a) * r * 0.16))
                spoke.addLine(to: CGPoint(x: centre.x + cos(a + side * 0.05) * rimR * 0.95, y: centre.y + sin(a + side * 0.05) * rimR * 0.95))
                ctx.stroke(spoke, with: .color(Color(white: 0.78)), style: StrokeStyle(lineWidth: r * 0.07, lineCap: .round))
            }
        }
        let hubR = r * 0.14
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - hubR, y: centre.y - hubR, width: 2 * hubR, height: 2 * hubR)), with: .color(Color(white: 0.2)))
        ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - hubR, y: centre.y - hubR, width: 2 * hubR, height: 2 * hubR)), with: .color(Color(white: 0.7)), lineWidth: r * 0.03)
    }
}

/// The outline in metres, rear at x = 0, ground at y = 0, facing right.
enum EV6Geometry {
    enum Cmd {
        case m(Double, Double)
        case l(Double, Double)
        case c(Double, Double, Double, Double, Double, Double)
        case z
    }

    static let length = 4.70
    static let height = 1.60
    /// A little room around the car for the shadow and the lights' glow.
    static let margin = 0.08
    static var aspect: CGFloat { (length + 2 * margin) / (height + 2 * margin) }

    struct Mapping {
        let scale: CGFloat
        let origin: CGPoint

        init(size: CGSize) {
            let w = EV6Geometry.length + 2 * EV6Geometry.margin
            let h = EV6Geometry.height + 2 * EV6Geometry.margin
            scale = min(size.width / w, size.height / h)
            origin = CGPoint(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2)
        }

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: origin.x + (x + EV6Geometry.margin) * scale,
                y: origin.y + (EV6Geometry.height + EV6Geometry.margin - y) * scale
            )
        }

        func path(_ cmds: [Cmd]) -> Path {
            var p = Path()
            for cmd in cmds {
                switch cmd {
                case .m(let x, let y): p.move(to: point(x, y))
                case .l(let x, let y): p.addLine(to: point(x, y))
                case .c(let x1, let y1, let x2, let y2, let x, let y):
                    p.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
                case .z: p.closeSubpath()
                }
            }
            return p
        }
    }

    static let body: [Cmd] = [
        .m(0.14, 0.34), .l(0.05, 0.44), .c(0.02, 0.6, 0.01, 0.8, 0.03, 0.93), .l(0, 1), .l(0.2, 1.08),
        .c(0.6, 1.26, 1.1, 1.47, 1.8, 1.54), .c(2.2, 1.57, 2.55, 1.55, 2.75, 1.48),
        .c(3.02, 1.34, 3.25, 1.16, 3.48, 1.06), .c(3.9, 0.99, 4.3, 0.92, 4.55, 0.83),
        .c(4.66, 0.79, 4.7, 0.7, 4.7, 0.6), .c(4.7, 0.46, 4.66, 0.36, 4.58, 0.3), .l(4.25, 0.3),
        .c(4.25, 0.927, 3.31, 0.927, 3.31, 0.3), .l(1.35, 0.3), .c(1.35, 0.927, 0.41, 0.927, 0.41, 0.3), .l(0.3, 0.32),
        .z
    ]
    static let glass: [Cmd] = [
        .m(3.28, 1.1), .c(3.08, 1.22, 2.86, 1.39, 2.64, 1.46), .c(2.2, 1.51, 1.6, 1.5, 1.2, 1.42),
        .c(1, 1.37, 0.86, 1.3, 0.76, 1.24), .c(1.3, 1.17, 2.4, 1.11, 3.28, 1.1), .z
    ]
    static let belt: [Cmd] = [
        .m(3.28, 1.1), .c(2.4, 1.11, 1.3, 1.17, 0.76, 1.24), .c(0.64, 1.27, 0.72, 1.36, 1, 1.405)
    ]
    static let crease: [Cmd] = [
        .m(3.2, 0.5), .c(2.6, 0.46, 1.95, 0.52, 1.4, 0.7)
    ]
    static let cladding: [Cmd] = [
        .m(4.25, 0.3), .c(4.25, 0.927, 3.31, 0.927, 3.31, 0.3), .m(1.35, 0.3), .c(1.35, 0.927, 0.41, 0.927, 0.41, 0.3)
    ]
    static let sill: [Cmd] = [
        .m(3.31, 0.35), .l(1.35, 0.35)
    ]
    static let pillar: [Cmd] = [
        .m(2.28, 1.12), .l(2.34, 1.49)
    ]
    static let head: [Cmd] = [
        .m(4.38, 0.87), .c(4.52, 0.84, 4.62, 0.79, 4.67, 0.73)
    ]
    static let tail: [Cmd] = [
        .m(0.02, 0.97), .l(0.2, 1.05), .c(0.32, 1.1, 0.42, 1.16, 0.52, 1.22)
    ]
    static let mirror: [Cmd] = [
        .m(3.12, 1.12), .c(3.16, 1.2, 3.3, 1.21, 3.36, 1.16), .c(3.36, 1.11, 3.25, 1.08, 3.12, 1.12), .z
    ]
    static let port: [Cmd] = [
        .m(0.34, 0.92), .l(0.56, 0.92), .l(0.56, 1.02), .l(0.36, 1.02), .z
    ]
    static let intake: [Cmd] = [
        .m(4.66, 0.4), .c(4.6, 0.37, 4.5, 0.36, 4.38, 0.37)
    ]
    static let handles: [Cmd] = [
        .m(2.72, 1.01), .l(2.92, 1.005), .m(1.62, 1.03), .l(1.82, 1.025)
    ]
}

#Preview {
    VStack(spacing: 24) {
        EV6Illustration(paint: .runwayRed, charging: true, pluggedIn: true, climate: .heating)
        EV6Illustration(paint: .snowWhitePearl)
        EV6Illustration(paint: .auroraBlackPearl, climate: .cooling)
    }
    .padding()
}
