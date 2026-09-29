import SwiftUI
import WidgetKit

@main
struct EV6WidgetBundle: WidgetBundle {
    var body: some Widget {
        EV6StatusWidget()
        EV6LockScreenWidget()
        EV6LiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            PreconditionControl()
            StopClimateControl()
            LockControl()
            RefreshControl()
        }
    }
}

// MARK: - Timeline

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: CarGlance?
}

/// Reads what the app last saw. The app reloads the widgets whenever that changes, so the timeline
/// only needs to come back now and then to keep "updated … ago" honest.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let saved = GlanceKeychain.load()
        completion(GlanceEntry(date: .now, glance: saved ?? (context.isPreview ? CarGlance.preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let entry = GlanceEntry(date: .now, glance: GlanceKeychain.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Home Screen

struct EV6StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6Status", provider: GlanceProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("EV6")
        .description("Charge, range, locks and climate, with quick buttons.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.14, blue: 0.16), Color(red: 0.05, green: 0.05, blue: 0.06)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        if let glance = entry.glance {
            switch family {
            case .systemMedium: medium(glance)
            default: small(glance)
            }
        } else {
            VStack(spacing: 6) {
                Image("WidgetCar").resizable().scaledToFit()
                Text("Open EV6 to sign in").font(.caption).foregroundStyle(.secondary)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private func small(_ g: CarGlance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image("KiaLogo").renderingMode(.template).resizable().scaledToFit().frame(height: 9)
                Spacer()
                StatusIcons(glance: g)
            }
            Image("WidgetCar").resizable().scaledToFit().padding(.vertical, 2)
            Spacer(minLength: 0)
            Percent(glance: g, size: 30)
            Text(g.rangeText ?? "–").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            ChargeBar(glance: g).padding(.top, 3)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .widgetURL(URL(string: "ev6://open"))
    }

    private func medium(_ g: CarGlance) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image("KiaLogo").renderingMode(.template).resizable().scaledToFit().frame(height: 9)
                    Text("EV6").font(.caption.weight(.heavy)).tracking(1.5)
                }
                Spacer(minLength: 0)
                Percent(glance: g, size: 36)
                Text(g.rangeText ?? "–").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                ChargeBar(glance: g).padding(.vertical, 4)
                Text(g.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Updated(glance: g)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Image("WidgetCar").resizable().scaledToFit()
                HStack(spacing: 8) {
                    if g.climateOn {
                        ActionButton(action: .climateStop, symbol: "fan.slash", tint: .orange)
                    } else {
                        ActionButton(action: .climateStart, symbol: "fan", tint: .orange)
                    }
                    ActionButton(action: .lock, symbol: "lock.fill", tint: .blue)
                    ActionButton(action: .refresh, symbol: "arrow.clockwise", tint: .gray)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .widgetURL(URL(string: "ev6://open"))
    }
}

struct Percent: View {
    let glance: CarGlance
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(glance.socPercent.map(String.init) ?? "–")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("%").font(.system(size: size * 0.45, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            if glance.charging {
                Image(systemName: "bolt.fill").font(.system(size: size * 0.45)).foregroundStyle(.green)
            }
        }
    }
}

struct ChargeBar: View {
    let glance: CarGlance

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(glance.socPercent ?? 0) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(fraction < 0.2 ? Color.orange : Color.green).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
    }
}

struct StatusIcons: View {
    let glance: CarGlance

    var body: some View {
        HStack(spacing: 4) {
            if glance.climateOn { Image(systemName: "fan.fill").foregroundStyle(.orange) }
            if glance.charging {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
            } else if glance.pluggedIn {
                Image(systemName: "powerplug.fill").foregroundStyle(.green)
            }
            if let locked = glance.locked {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill").foregroundStyle(locked ? Color.secondary : Color.orange)
            }
        }
        .font(.caption2)
    }
}

struct Updated: View {
    let glance: CarGlance

    var body: some View {
        if glance.busy {
            Text("Updating…").font(.caption2).foregroundStyle(.secondary)
        } else {
            (Text("Updated ") + Text(glance.carReportedAt ?? glance.fetchedAt, style: .relative) + Text(" ago"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Sends the command straight from the widget: the app runs it in the background and the widget
/// updates once the car confirms.
struct ActionButton: View {
    let action: CarAction
    let symbol: String
    let tint: Color

    var body: some View {
        Button(intent: CarCommandIntent(action)) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.25), in: Circle())
                .foregroundStyle(tint == .gray ? .white : tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen

struct EV6LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6LockScreen", provider: GlanceProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("EV6 charge")
        .description("Your EV6's charge on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        let g = entry.glance
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(g?.socPercent ?? 0), in: 0...100) {
                Image(systemName: g?.charging == true ? "bolt.fill" : "car.fill")
            } currentValueLabel: {
                Text(g?.socPercent.map(String.init) ?? "–").monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        case .accessoryInline:
            if let g {
                Label("EV6 \(g.socPercent.map { "\($0)%" } ?? "–") · \(g.rangeText ?? "–")", systemImage: g.charging ? "bolt.car.fill" : "car.fill")
            } else {
                Label("EV6", systemImage: "car.fill")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: g?.charging == true ? "bolt.car.fill" : "car.fill")
                    Text("EV6").fontWeight(.bold)
                    Text(g?.socPercent.map { "\($0)%" } ?? "–").monospacedDigit()
                }
                .font(.headline)
                .widgetAccentable()
                if let g {
                    Text(g.rangeText.map { "\($0) range" } ?? "–")
                    Text(g.summary).lineLimit(1)
                } else {
                    Text("Open EV6 to sign in")
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
