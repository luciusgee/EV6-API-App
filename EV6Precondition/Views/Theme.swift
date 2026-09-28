import SwiftUI

/// Kia colours from the Android app (`BrandColors.kt`).
enum Brand {
    static let midnight = Color(red: 0x05 / 255, green: 0x14 / 255, blue: 0x1F / 255)
    static let midnightLight = Color(red: 0x1D / 255, green: 0x32 / 255, blue: 0x42 / 255)
    static let cyan = Color(red: 0x5C / 255, green: 0xE1 / 255, blue: 0xE6 / 255)
    static let onCyan = Color(red: 0x03 / 255, green: 0x23 / 255, blue: 0x29 / 255)
    static let amber = Color(red: 0xF2 / 255, green: 0xB3 / 255, blue: 0x3D / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// A small rounded label, e.g. "Charging · 7.2 kW".
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Brand.cyan
    var foreground: Color = Brand.onCyan

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(tint, in: Capsule())
    }
}

extension String {
    /// "climatise to 21.0 °C" → "Climatise to 21.0 °C".
    var capitalizingFirst: String { prefix(1).uppercased() + String(dropFirst()) }
}
