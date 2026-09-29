import SwiftUI

/// Kia's logo (from kia.com), tinted to the text colour so it works in light and dark mode.
struct KiaLogo: View {
    var body: some View {
        Image("KiaLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .accessibilityLabel("Kia")
    }
}
