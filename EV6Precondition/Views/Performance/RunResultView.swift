import Charts
import PreconditionKit
import SwiftUI

/// One run in full: the time, the numbers around it, splits and the speed and power trace.
struct RunResultView: View {
    @Environment(Preferences.self) private var prefs
    @Environment(RunStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let run: RunResult

    private var miles: Bool { prefs.useMiles }
    private var isBest: Bool { store.best(run.type)?.id == run.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RunCard(run: run, miles: miles, best: isBest)
                stats
                if !run.splits.isEmpty { splits }
                if run.trace.count > 2 { charts }
                notes
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle(run.type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let image = shareImage {
                    ShareLink(item: image, preview: SharePreview(run.type.title, image: image))
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @MainActor
    private var shareImage: Image? {
        let renderer = ImageRenderer(content: RunCard(run: run, miles: miles, best: isBest).frame(width: 390).padding(20).background(Color.black).environment(\.colorScheme, .dark))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            switch run.type.category {
            case .distance:
                tile("Trap speed", DisplayText.speed(kmh: run.endKmh, miles: miles), "speedometer")
            case .braking:
                tile("Stopping distance", DisplayText.shortDistance(metres: run.metres, miles: miles), "ruler")
                if let g = run.peakDecelG { tile("Peak deceleration", String(format: "%.2f g", g), "arrow.down.to.line") }
            default:
                tile("Distance", DisplayText.shortDistance(metres: run.metres, miles: miles), "ruler")
            }
            if let kw = run.peakPowerKW, run.type.category != .braking {
                tile("Peak power", String(format: "%.0f kW · %.0f bhp", kw, kw * 1.341), "bolt.fill")
            }
            if run.type.category != .braking {
                tile("Average g", averageG.map { String(format: "%.2f g", $0) } ?? "–", "gauge.with.dots.needle.67percent")
            }
            if let soc = run.socPercent { tile("Battery at start", String(format: "%.0f%%", soc), "battery.75percent") }
            if let c = run.batteryC { tile("Battery temperature", String(format: "%.0f °C", c), "thermometer.medium") }
            tile("Readings", String(format: "%.1f a second", run.readingsPerSecond), "dot.radiowaves.left.and.right")
        }
    }

    private var averageG: Double? {
        guard let first = run.trace.first, run.seconds > 0 else { return nil }
        return (run.endKmh - first.kmh) / 3.6 / run.seconds / 9.80665
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var splitList: [RunSplit] {
        run.splits.filter { split in
            switch split.kind {
            case .distance: return true
            case .speedMph: return miles
            case .speedKmh: return !miles
            }
        }
    }

    private var splits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)
            VStack(spacing: 0) {
                ForEach(splitList) { split in
                    HStack {
                        Text(split.label).fontWeight(.medium)
                        Spacer()
                        if split.kind == .distance {
                            Text(DisplayText.speed(kmh: split.kmh, miles: miles)).foregroundStyle(.secondary)
                        }
                        Text(DisplayText.seconds(split.seconds))
                            .fontWeight(.semibold)
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    if split.id != splitList.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(.headline)
            Chart(run.trace, id: \.seconds) { p in
                AreaMark(x: .value("Seconds", p.seconds), y: .value("Speed", miles ? p.kmh / DisplayText.kmPerMile : p.kmh))
                    .foregroundStyle(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Seconds", p.seconds), y: .value("Speed", miles ? p.kmh / DisplayText.kmPerMile : p.kmh))
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
            }
            .chartXAxisLabel("seconds")
            .chartYAxisLabel(miles ? "mph" : "km/h")
            .frame(height: 180)
            if run.trace.contains(where: { $0.powerKW != nil }) {
                Text("Battery power").font(.headline).padding(.top, 8)
                Chart(run.trace.filter { $0.powerKW != nil }, id: \.seconds) { p in
                    LineMark(x: .value("Seconds", p.seconds), y: .value("kW", p.powerKW ?? 0))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                }
                .chartXAxisLabel("seconds")
                .chartYAxisLabel("kW")
                .frame(height: 150)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var notes: some View {
        var parts = ["Timed from the car's speed readings over OBD, interpolated between readings."]
        if run.rollout { parts.append("Timed from 1 ft of movement, as drag strips do.") }
        if run.motionLaunch { parts.append("The launch was marked by the phone's motion sensor.") }
        return Text(parts.joined(separator: " "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The headline card: run, time, date, car. Also what gets shared as an image.
struct RunCard: View {
    let run: RunResult
    let miles: Bool
    let best: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(run.type.title.uppercased()).font(.caption.weight(.heavy)).tracking(2)
                Spacer()
                if best {
                    Label("Personal best", systemImage: "trophy.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(.white.opacity(0.8))
            Text(DisplayText.seconds(run.seconds))
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.white)
            HStack {
                Text(subtitle)
                Spacer()
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Color(red: 0.55, green: 0.05, blue: 0.08), Color(red: 0.12, green: 0.02, blue: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var subtitle: String {
        var parts: [String] = []
        if let car = run.car { parts.append(car) }
        switch run.type.category {
        case .distance: parts.append("trap " + DisplayText.speed(kmh: run.endKmh, miles: miles))
        case .braking: parts.append(DisplayText.shortDistance(metres: run.metres, miles: miles))
        default: if let kw = run.peakPowerKW { parts.append(String(format: "%.0f kW peak", kw)) }
        }
        return parts.joined(separator: " · ")
    }
}
