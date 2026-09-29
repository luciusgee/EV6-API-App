import SwiftUI
import WidgetKit

/// Watch face complications: charge and range, from what the iPhone app last sent the Watch.
@main
struct EV6Complications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EV6Complication", provider: Provider()) { entry in
            ComplicationView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("EV6")
        .description("Your EV6's charge.")
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
        completion(Timeline(entries: [Entry(date: .now, glance: GlanceKeychain.load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let glance: CarGlance?

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
            Label("EV6 \(socText)% · \(glance?.rangeText ?? "–")", systemImage: symbol)
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text("EV6 \(socText)%").fontWeight(.semibold).monospacedDigit()
                }
                .widgetAccentable()
                Text(glance?.rangeText.map { "\($0) range" } ?? "–")
                Text(glance?.summary ?? "Open EV6 on your iPhone").lineLimit(1)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
