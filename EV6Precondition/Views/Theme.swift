import SwiftUI

extension String {
    /// "climatise to 21.0 °C" → "Climatise to 21.0 °C".
    var capitalizingFirst: String { prefix(1).uppercased() + String(dropFirst()) }
}

/// A stepper with round, filled − and + buttons: iOS's own is nearly invisible on dark grouped rows.
struct RoundStepper<V: Strideable>: View {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    var tint: Color = .accentColor
    let format: (V) -> String

    init(_ title: String, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride, tint: Color = .accentColor, format: @escaping (V) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.format = format
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            HStack(spacing: 8) {
                button("minus", enabled: value > range.lowerBound) { move(by: -1) }
                button("plus", enabled: value < range.upperBound) { move(by: 1) }
            }
        }
        .sensoryFeedback(.selection, trigger: format(value))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            move(by: direction == .increment ? 1 : -1)
        }
    }

    private func move(by steps: Int) {
        let next = value.advanced(by: step * V.Stride(exactly: steps)!)
        withAnimation(.snappy) { value = min(max(next, range.lowerBound), range.upperBound) }
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(enabled ? Color.white : Color.secondary)
                .background(enabled ? tint.opacity(0.85) : Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
    }
}
