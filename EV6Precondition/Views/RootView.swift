import PreconditionKit
import SwiftUI

struct RootView: View {
    @State private var asks = AskCoordinator.shared
    @State private var tour = Tour.shared
    @State private var inbox = CommuteInbox.shared
    /// The newest What's new you've seen (0 before the guide existed).
    @AppStorage("guideSeenRelease") private var seenRelease = 0
    @State private var whatsNew = false
    /// The launch animation, once per cold start.
    @State private var splash = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CarModel.self) private var car

    var body: some View {
        TabView(selection: $tour.tab) {
            CarView()
                .tabItem { Label("Car", systemImage: "car.fill") }
                .tag(AppTab.car)
            TripsView()
                .tabItem { Label("Trips", systemImage: "map.fill") }
                .tag(AppTab.trips)
            RulesView()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.rules)
            ScannerView()
                .tabItem { Label("Scanner", systemImage: "stethoscope") }
                .tag(AppTab.scanner)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .overlay {
            if splash {
                LaunchSplash { splash = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) {
            TourCard()
                .padding(.bottom, 58)
                .animation(.spring(duration: 0.35), value: tour.current?.id)
        }
        // On its own view: two alerts on one view don't both work.
        .background {
            Color.clear.alert("Add these rules?", isPresented: Binding(get: { inbox.rules != nil }, set: { if !$0 { inbox.rules = nil } })) {
            Button("Add") {
                if let text = inbox.rules {
                    Task {
                        await AppServices.shared.rules.importText(text)
                        tour.tab = .rules
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inbox.rules.map { RuleJSON.import($0).rules.map(\.name).joined(separator: ", ") } ?? "")
        }
        }
        .sheet(isPresented: Binding(get: { inbox.pending != nil }, set: { if !$0 { inbox.pending = nil } })) {
            if let list = inbox.pending { CommuteImportView(list: list) }
        }
        // A commute notification tapped, or the quick traffic check.
        .sheet(isPresented: Binding(get: { inbox.open != nil }, set: { if !$0 { inbox.open = nil } })) {
            if let id = inbox.open {
                NavigationStack {
                    CommuteDetailView(id: id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { inbox.open = nil } }
                        }
                }
            }
        }
        .sheet(item: $tour.showing) { screen in
            GuideScreenSheet(screen: screen)
        }
        .sheet(isPresented: $whatsNew) {
            WhatsNewSheet(firstTime: Guide.seenBefore == 0) { seenRelease = Guide.latest }
                .interactiveDismissDisabled(false)
                .onDisappear { seenRelease = Guide.latest }
        }
        .task {
            // A problem notification that belongs in Settings (like a rejected sign-in) opens it.
            AppServices.shared.notifier.onOpenSettings = { tour.tab = .settings }
            if AppServices.shared.notifier.openSettingsPending {
                AppServices.shared.notifier.openSettingsPending = false
                tour.tab = .settings
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Opened mid-charge: get fresh figures from the car (no 12 V cost while it's charging),
            // at most every 10 minutes.
            guard phase == .active, let s = car.snapshot, s.chargingState == .charging,
                  Date().timeIntervalSince(s.fetchedAt) > 10 * 60 else { return }
            Task { await car.refresh(wake: true) }
        }
        .task {
            // After an update with something new (or the first time), offer the guide once.
            guard seenRelease < Guide.latest else { return }
            Guide.seenBefore = seenRelease
            // After the launch animation, and not over anything else that's asking for attention.
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            while asks.pending != nil || inbox.rules != nil || inbox.pending != nil || inbox.open != nil || tour.showing != nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            whatsNew = true
        }
        // An "ask first" question tapped open from its notification.
        .alert(asks.pending.map(AskPlanner.title) ?? "", isPresented: Binding(
            get: { asks.pending != nil },
            set: { if !$0 { asks.pending = nil } }
        ), presenting: asks.pending) { rule in
            Button(rule.action.isStop ? "Stop now" : "Start now") { Task { await asks.run(rule) } }
            Button("In 15 min") { Task { await asks.answer(rule.id, .later) } }
            Button("Not today", role: .cancel) {}
        } message: { _ in
            if let outside = car.snapshot?.outsideTempC {
                Text("It's about \(Describe.temp(outside)) out.")
            }
        }
    }
}
