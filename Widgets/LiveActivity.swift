import ActivityKit
import SwiftUI
import WidgetKit

/// Climate and charging on the Lock Screen and in the Dynamic Island.
struct EV6LiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CarActivityAttributes.self) { context in
            LiveActivityBanner(kind: context.attributes.kind, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let kind = context.attributes.kind
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.socPercent.map { "\($0)%" } ?? "–").monospacedDigit()
                    } icon: {
                        Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                    }
                    .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: state)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(kind.tint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.title).font(.headline)
                        HStack {
                            if let detail = state.detail { Text(detail) }
                            Spacer()
                            if let range = state.rangeText { Text(range) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ActivityProgress(kind: kind, state: state)
                    }
                }
            } compactLeading: {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
            } compactTrailing: {
                if kind == .charging {
                    Text(state.socPercent.map { "\($0)%" } ?? "–").monospacedDigit().foregroundStyle(kind.tint)
                } else {
                    Countdown(state: state).frame(maxWidth: 44).foregroundStyle(kind.tint)
                }
            } minimal: {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
            }
            .keylineTint(kind.tint)
        }
    }
}

extension CarActivityAttributes.Kind {
    var symbol: String { self == .climate ? "fan.fill" : "bolt.fill" }
    var tint: Color { self == .climate ? .orange : .green }
}

struct LiveActivityBanner: View {
    let kind: CarActivityAttributes.Kind
    let state: CarActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                    Text(state.title).font(.headline)
                }
                HStack(spacing: 8) {
                    if let soc = state.socPercent {
                        Text("\(soc)%").monospacedDigit()
                    }
                    if let range = state.rangeText { Text(range) }
                    if let detail = state.detail { Text(detail) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ActivityProgress(kind: kind, state: state)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Countdown(state: state)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(kind.tint)
                Text(kind == .climate ? "left" : "to go").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }
}

struct Countdown: View {
    let state: CarActivityAttributes.ContentState

    var body: some View {
        if let end = state.endsAt, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text("–")
        }
    }
}

struct ActivityProgress: View {
    let kind: CarActivityAttributes.Kind
    let state: CarActivityAttributes.ContentState

    var body: some View {
        if kind == .charging {
            ProgressView(value: Double(state.socPercent ?? 0), total: 100).tint(kind.tint)
        } else if let end = state.endsAt, end > state.startedAt {
            ProgressView(timerInterval: state.startedAt...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(kind.tint)
        }
    }
}
