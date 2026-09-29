import PreconditionKit
import SwiftUI

extension GuideScreen: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// The running tour: which step, which tab, and whether a screen is open for "Show me".
@MainActor
@Observable
final class Tour {
    static let shared = Tour()

    var tab: AppTab = .car
    private(set) var steps: [GuideStep] = []
    private(set) var title = ""
    private(set) var index = 0
    var showing: GuideScreen?

    var isActive: Bool { !steps.isEmpty }
    var current: GuideStep? { steps.indices.contains(index) ? steps[index] : nil }

    func start(_ steps: [GuideStep], title: String) {
        guard !steps.isEmpty else { return }
        self.steps = steps
        self.title = title
        go(to: 0)
    }

    func next() {
        if index + 1 < steps.count { go(to: index + 1) } else { end() }
    }

    func back() {
        if index > 0 { go(to: index - 1) }
    }

    func end() {
        steps = []
        showing = nil
    }

    private func go(to i: Int) {
        index = i
        withAnimation { tab = steps[i].tab }
    }
}

/// The card that floats above the tabs during a tour.
struct TourCard: View {
    @State private var tour = Tour.shared

    var body: some View {
        if let step = tour.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(tour.title) · \(tour.index + 1) of \(tour.steps.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        tour.end()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("End the tour")
                }
                Label {
                    Text(step.title).font(.headline)
                } icon: {
                    Image(systemName: step.symbol).foregroundStyle(.tint)
                }
                ScrollView {
                    Text(step.body).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back") { tour.back() }
                        .disabled(tour.index == 0)
                    Spacer()
                    if let screen = step.screen {
                        Button("Show me") { tour.showing = screen }
                            .buttonStyle(.bordered)
                    }
                    Button(tour.index + 1 == tour.steps.count ? "Done" : "Next") { tour.next() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.tint.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(step.id)
        }
    }
}

/// A screen opened by "Show me", with the way back to the tour.
struct GuideScreenSheet: View {
    let screen: GuideScreen
    @Environment(CarModel.self) private var car

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back to tour") { Tour.shared.showing = nil }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .charging: ChargingView()
        case .offPeak: OffPeakView(current: car.snapshot?.details?.offPeak)
        case .chargers: ChargersView(near: car.snapshot?.parkingPosition)
        case .energy: EnergyView()
        case .batteryHealth: BatteryHealthView()
        case .planTrip: RoutePlannerView()
        case .foodChains: FoodChainsView()
        case .trafficAhead: TrafficAheadView()
        case .commute: CommuteView()
        case .timeAtPlaces: TimeAtPlacesView()
        case .places: PlacesView()
        case .alerts: AlertsSettingsView()
        case .activity: ActivityView()
        }
    }
}

/// Every update's new things, newest first, each with a tour.
struct WhatsNewView: View {
    var releases: [GuideRelease] = Guide.releases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(releases) { release in
                Section {
                    ForEach(release.steps) { step in
                        StepRow(step: step)
                    }
                    Button {
                        dismiss()
                        Tour.shared.start(release.steps, title: "What's new")
                    } label: {
                        Label("Tour these", systemImage: "play.circle.fill")
                    }
                } header: {
                    Text(release.title)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What's new")
    }
}

struct StepRow: View {
    let step: GuideStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.symbol).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.body.weight(.medium))
                Text(step.body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Shown once after an update (or on first run): what's new, or the whole tour.
struct WhatsNewSheet: View {
    let firstTime: Bool
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(firstTime ? "Here's a guide to the app" : "New in this update")
                            .font(.title2.weight(.bold))
                        Text(firstTime
                             ? "A quick tour moves around the app and shows what each part does. You can run it again, or just one part of it, from Settings › Guide."
                             : "Take the short tour, or read it below. Settings › Guide has this and the full tour whenever you want them.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button {
                        finish()
                        Tour.shared.start(firstTime ? Guide.allSteps : Guide.unseenSteps, title: firstTime ? "Tour" : "What's new")
                    } label: {
                        Label(firstTime ? "Take the tour" : "Show me what's new", systemImage: "play.circle.fill")
                            .font(.headline)
                    }
                }
                ForEach(firstTime ? [] : Guide.unseenReleases) { release in
                    Section(release.title) {
                        ForEach(release.steps) { StepRow(step: $0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(firstTime ? "Welcome" : "What's new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { finish() }
                }
            }
        }
    }

    private func finish() {
        onDone()
        dismiss()
    }
}

extension Guide {
    /// Set by the app when the sheet opens, so the list doesn't change under it.
    @MainActor static var seenBefore = 0
    @MainActor static var unseenReleases: [GuideRelease] { unseen(since: seenBefore) }
    @MainActor static var unseenSteps: [GuideStep] {
        var seen = Set<String>()
        return unseenReleases.reversed().flatMap(\.steps).filter { seen.insert($0.id).inserted }
    }
}

/// Settings › Guide.
struct GuideSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                WhatsNewView()
            } label: {
                Label("What's new", systemImage: "sparkles")
            }
            Button {
                Tour.shared.start(Guide.allSteps, title: "Tour")
            } label: {
                Label("Take the full tour", systemImage: "play.circle")
            }
            NavigationLink {
                List {
                    ForEach(Guide.sections) { section in
                        Button {
                            Tour.shared.start(section.steps, title: section.title)
                        } label: {
                            LabeledContent {
                                Text("\(section.steps.count)")
                            } label: {
                                Label(section.title, systemImage: section.symbol)
                            }
                        }
                    }
                }
                .navigationTitle("Tour one part")
            } label: {
                Label("Tour one part", systemImage: "list.bullet")
            }
        } header: {
            Text("Guide")
        } footer: {
            Text("What's new appears after every update. The tour moves around the app and opens each screen with Show me.")
        }
    }
}
