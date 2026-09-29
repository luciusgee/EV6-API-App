import SwiftUI

/// The Kia wordmark (2021 design), drawn as strokes so it stays sharp and follows light/dark mode.
struct KiaLogo: View {
    var body: some View {
        Color.clear
            .modifier(StrokeScale())
            .aspectRatio(4.2 / 1.2, contentMode: .fit)
            .accessibilityLabel("Kia")
    }
}

/// Scales the stroke with the logo's height.
private struct StrokeScale: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            KiaWordmark()
                .stroke(.primary, style: StrokeStyle(lineWidth: geo.size.height * 0.13 / 1.2, lineCap: .butt, lineJoin: .miter))
        }
    }
}

/// Unit geometry: 4.2 × 1.2 with a 0.1 margin; strokes are 0.13 wide.
struct KiaWordmark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / 4.2, rect.height / 1.2)
        let ox = rect.minX + (rect.width - 4.2 * s) / 2 + 0.1 * s
        let oy = rect.minY + (rect.height - 1.2 * s) / 2 + 0.1 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        // K: the upright…
        path.move(to: p(0.07, 0))
        path.addLine(to: p(0.07, 1))
        // …its arm running down into the I.
        path.move(to: p(0.32, 0))
        path.addLine(to: p(1.30, 1))
        path.addLine(to: p(1.30, 0))
        // A without a crossbar.
        path.move(to: p(1.75, 1))
        path.addLine(to: p(2.72, 0))
        path.addLine(to: p(3.69, 1))
        return path
    }
}
