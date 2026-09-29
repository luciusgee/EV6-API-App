import PreconditionKit
import SwiftUI

/// Live gauges while you drive or charge.
struct DashboardView: View {
    @Environment(OBDService.self) private var obd
    @Environment(CarModel.self) private var car

    static let gauges = ["socBMS", "battMax", "cabin", "outside", "cellSpread", "obdVoltage", "voltage", "rpmRear", "accelerator", "maxCharge"]
    private var ids: [String] { ["speed", "power", "gear"] + Self.gauges }
    private var miles: Bool { car.settings.useMiles }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                NotConnectedHint()
                hero
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Self.gauges.compactMap(EV6Sensors.sensor)) { sensor in
                        RingGauge(sensor: sensor, value: obd.latest[sensor.id], miles: miles)
                    }
                }
                if obd.live {
                    Text(String(format: "%.1f readings a second", obd.samplesPerSecond))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .liveSensors(ids, screen: "dashboard")
    }

    private var hero: some View {
        let speed = obd.latest["speed"]
        let power = obd.latest["power"]
        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(speed.map { String(format: "%.0f", miles ? $0 / DisplayText.kmPerMile : $0) } ?? "–")
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(miles ? "mph" : "km/h").font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(obd.latest["gear"].map(EV6Sensors.gearName) ?? "–")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .frame(width: 70, height: 70)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            PowerBar(kW: power)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: speed)
    }
}

/// Battery power: blue to the right while driving, green to the left while regenerating or charging.
struct PowerBar: View {
    let kW: Double?
    static let maxDrive = 240.0
    static let maxRegen = 150.0

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let mid = geo.size.width * Self.maxRegen / (Self.maxRegen + Self.maxDrive)
                let p = kW ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemFill))
                    if p >= 0 {
                        Capsule().fill(Color.blue.gradient)
                            .frame(width: (geo.size.width - mid) * min(p / Self.maxDrive, 1))
                            .offset(x: mid)
                    } else {
                        Capsule().fill(Color.green.gradient)
                            .frame(width: mid * min(-p / Self.maxRegen, 1))
                            .offset(x: mid - mid * min(-p / Self.maxRegen, 1))
                    }
                    Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 2).offset(x: mid - 1)
                }
            }
            .frame(height: 12)
            HStack {
                Text("Regen").foregroundStyle(.green)
                Spacer()
                Text(kW.map { String(format: "%.1f kW", $0) } ?? "– kW")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Spacer()
                Text("Power").foregroundStyle(.blue)
            }
            .font(.caption)
        }
        .animation(.easeOut(duration: 0.2), value: kW)
    }
}

struct RingGauge: View {
    let sensor: Sensor
    let value: Double?
    let miles: Bool

    private var fraction: Double {
        guard let value else { return 0 }
        let r = sensor.range
        return min(max((value - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
    }

    private var tint: Color {
        switch sensor.group {
        case .battery: return .mint
        case .cells: return .purple
        case .climate: return .orange
        case .drive: return .blue
        case .standard: return .gray
        default: return .teal
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(Color(.systemFill), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.12, to: 0.12 + 0.76 * fraction)
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Text(sensor.display(value, miles: miles))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
            }
            .frame(width: 104, height: 104)
            Text(sensor.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement(children: .combine)
    }
}
