import ActivityKit
import SwiftUI
import WidgetKit

/// Climate and charging on the Lock Screen and in the Dynamic Island.
struct EV6LiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CarActivityAttributes.self) { context in
            LiveActivityBanner(kind: context.attributes.kind, state: context.state, isStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(Color(red: 0.07, green: 0.07, blue: 0.08))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let kind = context.attributes.kind
            let state = context.state
            let stale = context.isStale
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
                    LabelledCountdown(kind: kind, state: state, isStale: stale)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ActivityText.title(kind, state, isStale: stale)).font(.headline).lineLimit(1)
                        HStack {
                            if let detail = ActivityText.detail(kind, state, isStale: stale) { Text(detail).lineLimit(1) }
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
                    Countdown(state: state, isStale: stale).frame(maxWidth: 44).foregroundStyle(kind.tint)
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

/// The words, allowing for an activity the app hasn't been able to update: a climate run that has
/// timed out, or a charge not read for a while.
enum ActivityText {
    static func climateEnded(_ state: CarActivityAttributes.ContentState, isStale: Bool) -> Bool {
        isStale || (state.endsAt.map { $0 <= .now } ?? false)
    }

    static func title(_ kind: CarActivityAttributes.Kind, _ state: CarActivityAttributes.ContentState, isStale: Bool) -> String {
        if kind == .climate && climateEnded(state, isStale: isStale) { return "Climate finished" }
        return state.title
    }

    static func detail(_ kind: CarActivityAttributes.Kind, _ state: CarActivityAttributes.ContentState, isStale: Bool) -> String? {
        if kind == .climate {
            return climateEnded(state, isStale: isStale) ? nil : state.detail
        }
        let time = state.updatedAt?.formatted(date: .omitted, time: .shortened)
        if isStale { return time.map { "Not updated since \($0)" } ?? "Not updated recently" }
        return [state.detail, time.map { "as of \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct LiveActivityBanner: View {
    let kind: CarActivityAttributes.Kind
    let state: CarActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(ActivityText.title(kind, state, isStale: isStale)).lineLimit(1)
                } icon: {
                    Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                }
                .font(.headline)
                Spacer(minLength: 8)
                LabelledCountdown(kind: kind, state: state, isStale: isStale)
                    .font(.title2.weight(.semibold))
                    .frame(width: 100, alignment: .trailing)
            }
            ActivityProgress(kind: kind, state: state)
            HStack {
                Text([state.socPercent.map { "\($0)%" }, state.rangeText].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let detail = ActivityText.detail(kind, state, isStale: isStale) {
                    Text(detail).lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}

/// The countdown with what it counts to underneath.
struct LabelledCountdown: View {
    let kind: CarActivityAttributes.Kind
    let state: CarActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Countdown(state: state, isStale: isStale)
                .foregroundStyle(kind.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if Countdown.running(state, isStale: isStale) {
                Text(kind == .charging ? "until full" : "left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Countdown: View {
    let state: CarActivityAttributes.ContentState
    let isStale: Bool

    static func running(_ state: CarActivityAttributes.ContentState, isStale: Bool) -> Bool {
        guard let end = state.endsAt else { return false }
        return end > .now && !isStale
    }

    var body: some View {
        if let end = state.endsAt, Self.running(state, isStale: isStale) {
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
