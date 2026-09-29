import PreconditionKit
import SwiftUI

/// Hours at your places (work, say) by day, for timesheets, from your phone's location.
struct TimeAtPlacesView: View {
    @Environment(RulesModel.self) private var rules
    @Environment(PresenceModel.self) private var presence
    @State private var period: Period = .thisWeek
    @State private var customFrom = Calendar.current.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
    @State private var customTo = Date()
    @State private var editing: Visit?

    enum Period: String, CaseIterable, Identifiable {
        case thisWeek = "This week", lastWeek = "Last week", thisMonth = "This month", lastMonth = "Last month", custom = "Dates"
        var id: String { rawValue }
    }

    private var range: (from: Date, to: Date) {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let now = presence.now
        switch period {
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (start, cal.date(byAdding: .day, value: 7, to: start) ?? now)
        case .lastWeek:
            let thisStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (cal.date(byAdding: .day, value: -7, to: thisStart) ?? now, thisStart)
        case .thisMonth:
            let i = cal.dateInterval(of: .month, for: now)
            return (i?.start ?? now, i?.end ?? now)
        case .lastMonth:
            let thisStart = cal.dateInterval(of: .month, for: now)?.start ?? now
            let start = cal.date(byAdding: .month, value: -1, to: thisStart) ?? now
            return (start, thisStart)
        case .custom:
            let from = cal.startOfDay(for: customFrom)
            return (from, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customTo, customFrom))) ?? customTo)
        }
    }

    private var names: [String: String] { Dictionary(rules.places.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private var trackedPlaces: [Place] { rules.places.filter { presence.tracked.contains($0.id) } }

    var body: some View {
        List {
            trackingSection
            if !trackedPlaces.isEmpty {
                periodSection
                totalsSection
                daysSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Time at Places")
        .task { await presence.refreshCarTrips() }
        .refreshable { await presence.refreshCarTrips() }
        .toolbar {
            if !trackedPlaces.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: csvFile(), preview: SharePreview("Timesheet")) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
                        editing = Visit(placeId: trackedPlaces[0].id, arrived: start, left: start.addingTimeInterval(8 * 3600), source: .manual)
                    } label: {
                        Label("Add Time", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editing) { visit in
            VisitEditor(visit: visit, places: trackedPlaces)
        }
    }

    private var trackingSection: some View {
        Section {
            if rules.places.isEmpty {
                Text("Add a place (like Work) under Rules › Places first.").foregroundStyle(.secondary)
            }
            ForEach(rules.places) { place in
                Toggle(isOn: Binding(
                    get: { presence.tracked.contains(place.id) },
                    set: { on in Task { await presence.setTracked(place.id, on) } }
                )) {
                    Label(place.name, systemImage: "mappin.circle")
                }
            }
            Picker("Using", selection: Binding(
                get: { presence.log.mode },
                set: { mode in Task { await presence.setMode(mode); await presence.refreshCarTrips() } }
            )) {
                Text("The car").tag(PresenceLog.Mode.car)
                Text("iPhone").tag(PresenceLog.Mode.phone)
            }
            .pickerStyle(.segmented)
            if presence.loadingTrips {
                HStack { ProgressView(); Text("Getting the car's trips…").foregroundStyle(.secondary) }
            }
            if let problem = presence.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
            }
        } header: {
            Text("Track time at")
        } footer: {
            Text(presence.log.mode == .car
                 ? "From the car's trip log: it arrived when a drive ended and left when the next began, placed by where it was parked. Each day of trips is one Kia request. It stays on your phone."
                 : "From your iPhone's location, even with the app closed. Needs location set to Always. It stays on your phone.")
        }
    }

    private var periodSection: some View {
        Section {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            if period == .custom {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
            }
        }
    }

    private var totalsSection: some View {
        Section {
            ForEach(trackedPlaces) { place in
                let secs = presence.log.seconds(at: place.id, from: range.from, to: range.to, now: presence.now)
                let days = Set(rows.filter { $0.placeId == place.id }.map(\.day)).count
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(DisplayText.hours(secs)).font(.headline).monospacedDigit()
                        if days > 0 {
                            Text("\(days) day\(days == 1 ? "" : "s") · \(DisplayText.hours(secs / Double(days))) a day")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text(place.name)
                }
            }
        } header: {
            Text("Total")
        }
    }

    private var rows: [PresenceLog.DayRow] {
        presence.log.days(from: range.from, to: range.to, placeIds: presence.tracked, now: presence.now)
    }

    private var daysSection: some View {
        Section {
            if rows.isEmpty {
                Text("No time logged in this period.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Button {
                    editing = visit(for: row)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .foregroundStyle(.primary)
                            Text("\(names[row.placeId] ?? "Place") · \(row.firstArrival.formatted(date: .omitted, time: .shortened))–\(row.open ? "now" : row.lastDeparture.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DisplayText.hours(row.seconds))
                            .monospacedDigit()
                            .foregroundStyle(row.open ? .orange : .primary)
                    }
                }
            }
        } header: {
            Text("By day")
        } footer: {
            Text("Tap a day to correct it. Popping out for under 10 minutes doesn't count as leaving.")
        }
    }

    /// The stay behind a day's row, to edit.
    private func visit(for row: PresenceLog.DayRow) -> Visit? {
        presence.log.visits.last { v in
            v.placeId == row.placeId && v.arrived < row.day.addingTimeInterval(86400) && PresenceLog.end(of: v, now: presence.now) > row.day
        }
    }

    private func csvFile() -> URL {
        let csv = presence.log.csv(from: range.from, to: range.to, placeNames: names, now: presence.now)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Timesheet \(df.string(from: range.from)) to \(df.string(from: range.to.addingTimeInterval(-1))).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Correct or add a stay.
private struct VisitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PresenceModel.self) private var presence
    @State var visit: Visit
    let places: [Place]
    @State private var stillThere = false

    init(visit: Visit, places: [Place]) {
        _visit = State(initialValue: visit)
        self.places = places
        _stillThere = State(initialValue: visit.left == nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Place", selection: $visit.placeId) {
                    ForEach(places) { Text($0.name).tag($0.id) }
                }
                DatePicker("Arrived", selection: $visit.arrived)
                Toggle("Still there", isOn: $stillThere)
                if !stillThere {
                    DatePicker("Left", selection: Binding(
                        get: { visit.left ?? visit.arrived.addingTimeInterval(3600) },
                        set: { visit.left = $0 }
                    ), in: visit.arrived...)
                }
                if presence.log.visits.contains(where: { $0.id == visit.id }) {
                    Section {
                        Button("Delete", role: .destructive) {
                            Task {
                                await presence.delete(visit.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var v = visit
                        if stillThere { v.left = nil } else if v.left == nil { v.left = v.arrived.addingTimeInterval(3600) }
                        Task {
                            await presence.save(v)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
