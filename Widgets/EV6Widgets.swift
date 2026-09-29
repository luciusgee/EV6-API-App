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
        let glance = GlanceKeychain.load()
        var entries = [GlanceEntry(date: .now, glance: glance)]
        // Another entry when the data turns stale, so the widget says how old it is.
        if let glance {
            let staleAt = glance.reportedAt.addingTimeInterval(CarGlance.staleAfter + 60)
            if staleAt > .now { entries.append(GlanceEntry(date: staleAt, glance: glance)) }
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Home Screen

struct EV6StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6Status", provider: GlanceProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("My EV6")
        .description("Charge, range, locks and climate, with a climate button.")
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
                Text("Open My EV6 to sign in").font(.caption).foregroundStyle(.secondary)
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
            if g.busy || g.isStale(at: entry.date) {
                Updated(glance: g, now: entry.date).padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .widgetURL(URL(string: "ev6://open"))
    }

    private func medium(_ g: CarGlance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image("KiaLogo").renderingMode(.template).resizable().scaledToFit().frame(height: 9)
                        Text("EV6").font(.caption.weight(.heavy)).tracking(1.5)
                        StatusIcons(glance: g)
                    }
                    Percent(glance: g, size: 34)
                    // The plan line below already says whether it's plugged in.
                    Text([g.rangeText, g.plan != nil ? nil : (g.pluggedIn ? (g.charging ? "charging" : "plugged in") : "not plugged in")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image("WidgetCar").resizable().scaledToFit().frame(maxHeight: 62)
            }
            ChargeBar(glance: g).padding(.vertical, 6)
            if let plan = g.plan {
                Label(plan, systemImage: g.charging ? "bolt.fill" : (g.pluggedIn ? "clock.fill" : "powerplug"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(g.pluggedIn ? Color.green : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            HStack(alignment: .center, spacing: 8) {
                // How old the data is matters more than the next rule once it's stale.
                if let next = g.next, !g.busy, !g.isStale(at: entry.date) {
                    Text("Next: \(next)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Updated(glance: g, now: entry.date)
                }
                Spacer(minLength: 0)
                ClimatePill(glance: g)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .widgetURL(URL(string: "ev6://open"))
    }
}

/// The one big button: start climate, or stop it while it runs.
struct ClimatePill: View {
    let glance: CarGlance

    var body: some View {
        if glance.busy {
            // A command is already going: no second tap until it settles.
            pill(glance.waitingForCar == true ? "Sending…" : "Updating…", "hourglass", filled: false)
        } else {
            Button(intent: CarCommandIntent(glance.climateOn ? .climateStop : .climateStart)) {
                pill(glance.climateOn ? "Stop" : "Start climate", glance.climateOn ? "fan.slash.fill" : "fan.fill", filled: !glance.climateOn)
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(_ title: String, _ symbol: String, filled: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(filled ? 1 : 0.3), in: Capsule())
            .foregroundStyle(filled ? Color.black : .orange)
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
            // Charging shows as a bolt by the percentage instead.
            if glance.pluggedIn && !glance.charging {
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
    let now: Date

    var body: some View {
        Text(glance.busy ? glance.busyText : glance.updatedText(now: now))
            .font(.caption2)
            .foregroundStyle(!glance.busy && glance.isStale(at: now) ? Color.orange : .secondary)
            .lineLimit(1)
    }
}

// MARK: - Lock Screen

struct EV6LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6LockScreen", provider: GlanceProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Charge")
        .description("Your EV6's charge and range on the Lock Screen.")
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
                Label("My EV6", systemImage: "car.fill")
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
                    if g.isStale(at: entry.date) {
                        Text(g.updatedText(now: entry.date)).lineLimit(1)
                    } else {
                        Text(g.rangeText.map { "\($0) range" } ?? "–")
                    }
                    Text(g.plan ?? g.summary).lineLimit(1)
                } else {
                    Text("Open My EV6 to sign in")
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
