import SwiftUI
import WidgetKit

/// Watch face complications: charge and range, from what the iPhone app last sent the Watch.
@main
struct EV6Complications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6Complication", provider: Provider()) { entry in
            ComplicationView(glance: entry.glance, date: entry.date)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("My EV6")
        .description("Your EV6's charge and range.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let glance: CarGlance?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, glance: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, glance: GlanceKeychain.load() ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let glance = GlanceKeychain.load()
        var entries = [Entry(date: .now, glance: glance)]
        // Another entry when the data turns stale, so the face says how old it is.
        if let glance {
            let staleAt = glance.reportedAt.addingTimeInterval(CarGlance.staleAfter + 60)
            if staleAt > .now { entries.append(Entry(date: staleAt, glance: glance)) }
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let glance: CarGlance?
    let date: Date

    private var soc: Int { glance?.socPercent ?? 0 }
    private var socText: String { glance?.socPercent.map(String.init) ?? "–" }
    private var symbol: String { glance?.charging == true ? "bolt.fill" : "car.fill" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(soc), in: 0...100) {
                Image(systemName: symbol)
            } currentValueLabel: {
                Text(socText).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetLabel {
                    Gauge(value: Double(soc), in: 0...100) {
                        Text("EV6")
                    } currentValueLabel: {
                        Text("\(socText)%")
                    }
                    .tint(soc < 20 ? .orange : .green)
                }
        case .accessoryInline:
            if let glance {
                Label("EV6 \(socText)% · \(glance.rangeText ?? "–")", systemImage: symbol)
            } else {
                Label("My EV6", systemImage: "car.fill")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text(glance == nil ? "My EV6" : "EV6 \(socText)%").fontWeight(.semibold).monospacedDigit()
                }
                .widgetAccentable()
                if let glance {
                    if glance.isStale(at: date) {
                        Text(glance.updatedText(now: date)).lineLimit(1)
                    } else {
                        Text(glance.rangeText.map { "\($0) range" } ?? "–")
                    }
                    Text(glance.plan ?? glance.summary).lineLimit(1)
                } else {
                    Text("Open My EV6 on iPhone").lineLimit(2)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
