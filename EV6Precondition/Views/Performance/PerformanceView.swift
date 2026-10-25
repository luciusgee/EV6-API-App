import PreconditionKit
import SwiftUI

/// The timing pad: pick a run, arm it, go. Big numbers you can read from the driver's seat.
struct PerformanceView: View {
    @Environment(OBDService.self) private var obd
    @Environment(Preferences.self) private var prefs
    @Environment(RunStore.self) private var store
    @AppStorage("runType") private var typeRaw = RunType.zeroTo60mph.rawValue
    @AppStorage("runRollout") private var rollout = false
    @AppStorage("runMotion") private var useMotion = true
    @State private var showing: RunResult?
    @State private var showingAdapters = false
    @State private var confirmTrack = false

    private var type: RunType { RunType(rawValue: typeRaw) ?? .zeroTo60mph }
    private var miles: Bool { prefs.useMiles }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RunTypePicker(selection: Binding(get: { type }, set: { typeRaw = $0.rawValue }))
                        .disabled(obd.run != nil)
                    RunPad(type: type, miles: miles, armed: obd.run != nil)
                    controls
                    TimingQuality()
                    bests
                    NavigationLink {
                        ProLock(feature: "The lap timer") { LapTimerView() }
                    } label: {
                        ToolRow(title: "Lap timer", detail: "GPS laps with a start/finish line you set", systemImage: "flag.pattern.checkered.2.crossed", tint: .orange)
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        RunHistoryView()
                    } label: {
                        ToolRow(title: "All runs", detail: "\(store.runs.count) saved", systemImage: "list.number", tint: .blue)
                    }
                    .buttonStyle(.plain)
                    Text("For closed roads and tracks only. Obey the law and drive within your limits; times come from the car's own speed readings and are for fun, not certification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Performance")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionButton(showingAdapters: $showingAdapters)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("1 ft rollout", isOn: $rollout)
                        Toggle("Motion sensor launch", isOn: $useMotion)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .disabled(obd.run != nil)
                }
            }
            .sheet(isPresented: $showingAdapters) { AdapterPicker(link: obd.link) }
            .alert("Closed roads only", isPresented: $confirmTrack) {
                Button("I understand") {
                    prefs.acceptedTrackUse = true
                    arm()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use performance timing only on closed roads, tracks and drag strips, never on public roads. Mount your phone and don't touch it while driving.")
            }
            .sheet(item: $showing) { run in
                NavigationStack { RunResultView(run: run) }
            }
        }
        .liveSensors(["speed", "power", "socBMS", "battMax"], screen: "performance")
        .onChange(of: finished) { _, result in
            guard let result else { return }
            store.add(result)
            obd.motion.stop()
            obd.demoDrive(for: nil)
            showing = result
        }
        .onChange(of: running) { _, now in
            // Ready for the next one if the launch came to nothing.
            if !now { obd.motion.rearm() }
        }
    }

    private var finished: RunResult? {
        if case .finished(let r)? = obd.run?.state { return r }
        return nil
    }

    private var running: Bool {
        if case .running? = obd.run?.state { return true }
        return false
    }

    @ViewBuilder
    private var controls: some View {
        if obd.run == nil || finished != nil {
            Button {
                arm()
            } label: {
                Label(finished == nil ? "Arm" : "Go again", systemImage: "flag.checkered")
                    .font(.title3.weight(.heavy))
                    .tracking(2)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
            .disabled(obd.carState != .connected)
            .sensoryFeedback(.impact(weight: .heavy), trigger: obd.run == nil)
        } else {
            Button(role: .cancel) {
                cancel()
            } label: {
                Text("Cancel").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.white)
        }
        if obd.carState != .connected {
            Text(obd.adapterConnected ? "Waiting for the car to answer. Switch it on." : "Connect your adapter, or try the demo car in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func arm() {
        guard prefs.acceptedTrackUse else {
            confirmTrack = true
            return
        }
        var timer = RunTimer(type: type, rollout: rollout)
        timer.note(soc: obd.latest["socBMS"], batteryC: obd.latest["battMax"], car: prefs.model.fullName)
        obd.run = timer
        if useMotion && type.standingStart { obd.motion.start() }
        obd.demoDrive(for: type)
    }

    private func cancel() {
        obd.run = nil
        obd.motion.stop()
        obd.demoDrive(for: nil)
    }

    @ViewBuilder
    private var bests: some View {
        let list = RunType.allCases.compactMap { store.best($0) }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Personal bests").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(list) { run in
                        Button {
                            showing = run
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.type.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(DisplayText.seconds(run.seconds))
                                    .font(.system(.title2, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                if run.type.category == .distance {
                                    Text("at " + DisplayText.speed(kmh: run.endKmh, miles: miles)).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(run.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The runs, by category, as chips.
private struct RunTypePicker: View {
    @Binding var selection: RunType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RunType.Category.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(RunType.allCases.filter { $0.category == category }) { type in
                                Button {
                                    selection = type
                                } label: {
                                    Text(type.title)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .foregroundStyle(selection == type ? Color.black : Color.white)
                                        .background(selection == type ? Color.red : Color.white.opacity(0.09), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .sensoryFeedback(.selection, trigger: selection)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The dial: live speed round the ring with the target marked, the clock in the middle.
private struct RunPad: View {
    @Environment(OBDService.self) private var obd
    let type: RunType
    let miles: Bool
    let armed: Bool

    private var state: RunTimer.State? { obd.run?.state }
    private var kmh: Double { obd.latest["speed"] ?? 0 }

    /// The top of the dial, km/h.
    private var scale: Double {
        switch type.spec {
        case .accelerate(_, let to): return max(to * 1.15, 60)
        case .distance(let m): return m > 500 ? 260 : 200
        case .brake(let from): return from * 1.3
        }
    }

    private var target: Double? {
        switch type.spec {
        case .accelerate(_, let to): return to
        case .brake(let from): return from
        case .distance: return nil
        }
    }

    private var tint: Color {
        switch state {
        case .waiting?: return .orange
        case .armed?: return .green
        case .running?: return .red
        case .finished?: return .white
        case nil: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                dial
                VStack(spacing: 4) {
                    clock
                    Text(status)
                        .font(.subheadline.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Text(DisplayText.speed(kmh: kmh, miles: miles))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .frame(height: 300)
            if let run = obd.run, case .running = run.state, case .distance(let total) = type.spec, let m = run.trace.last?.metres {
                ProgressView(value: min(m / total, 1)) {
                    HStack {
                        Text(DisplayText.shortDistance(metres: m, miles: miles))
                        Spacer()
                        Text(DisplayText.shortDistance(metres: total, miles: miles))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .tint(.red)
            } else {
                Text(armed ? type.instructions : "Pick a run and tap Arm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 34)
            }
        }
        .padding(18)
        .background(
            RadialGradient(colors: [tint.opacity(0.22), Color.white.opacity(0.03)], center: .center, startRadius: 20, endRadius: 260),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .animation(.easeOut(duration: 0.25), value: tint)
        .sensoryFeedback(.success, trigger: isFinished)
        .sensoryFeedback(.impact(weight: .heavy), trigger: isRunning)
    }

    private var isFinished: Bool {
        if case .finished? = state { return true }
        return false
    }

    private var isRunning: Bool {
        if case .running? = state { return true }
        return false
    }

    private var status: String {
        switch state {
        case .waiting(let why)?: return why
        case .armed?: return type.standingStart ? "Ready — launch!" : (type.category == .braking ? "Ready — brake!" : "Ready — floor it!")
        case .running?: return "Timing"
        case .finished?: return type.title
        case nil: return type.title
        }
    }

    @ViewBuilder
    private var clock: some View {
        switch state {
        case .running(let since)?:
            TimelineView(.animation) { context in
                bigTime(max(0, context.date.timeIntervalSince(since)))
            }
        case .finished(let r)?:
            bigTime(r.seconds)
        default:
            bigTime(0).opacity(0.35)
        }
    }

    private func bigTime(_ s: Double) -> some View {
        Text(String(format: s >= 100 ? "%.1f" : "%.2f", s))
            .font(.system(size: 84, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(.white)
    }

    private var dial: some View {
        let from = 0.14, span = 0.72
        let fraction = min(max(kmh / scale, 0), 1)
        return ZStack {
            Circle()
                .trim(from: from, to: from + span)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: from, to: from + span * fraction)
                .stroke(
                    AngularGradient(colors: [.orange, .red, .pink], center: .center, startAngle: .degrees(140), endAngle: .degrees(400)),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.2), value: fraction)
            if let target {
                let angle = Angle.degrees(90 + 360 * (from + span * min(target / scale, 1)))
                Capsule()
                    .fill(Color.white)
                    .frame(width: 4, height: 24)
                    .offset(y: -138)
                    .rotationEffect(angle + .degrees(90))
            }
        }
        .frame(width: 276, height: 276)
    }
}

/// How finely the car's readings can time a run.
struct TimingQuality: View {
    @Environment(OBDService.self) private var obd

    private var rate: Double { obd.samplesPerSecond }

    private var label: String {
        if !obd.live { return "Not reading" }
        if rate >= 8 { return "Excellent" }
        if rate >= 5 { return "Good" }
        return rate >= 3 ? "Fair" : "Low"
    }

    private var tint: Color {
        if !obd.live { return .gray }
        if rate >= 8 { return .green }
        if rate >= 5 { return .mint }
        return rate >= 3 ? .yellow : .orange
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Timing precision: \(label)").font(.subheadline.weight(.semibold))
                Text(obd.live ? String(format: "%.1f speed readings a second, interpolated between readings", rate) : "Readings start once the car is connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A row that leads somewhere.
struct ToolRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Every saved run, filterable by type.
struct RunHistoryView: View {
    @Environment(RunStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @State private var filter: RunType?

    var body: some View {
        List {
            Section {
                Picker("Run", selection: $filter) {
                    Text("All").tag(RunType?.none)
                    ForEach(RunType.allCases) { Text($0.title).tag(RunType?.some($0)) }
                }
            }
            Section {
                let list = store.runs(filter)
                if list.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
                ForEach(list) { run in
                    NavigationLink {
                        RunResultView(run: run)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.type.title).fontWeight(.semibold)
                                Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.best(run.type)?.id == run.id {
                                Image(systemName: "trophy.fill").foregroundStyle(.yellow)
                            }
                            Text(DisplayText.seconds(run.seconds))
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .monospacedDigit()
                        }
                    }
                }
                .onDelete { offsets in
                    let list = store.runs(filter)
                    store.delete(Set(offsets.map { list[$0].id }))
                }
            }
        }
        .navigationTitle("All runs")
    }
}
