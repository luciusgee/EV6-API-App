import PreconditionKit
import SwiftUI

/// Commutes waiting to be added from an ev6://commutes link.
@MainActor
@Observable
final class CommuteInbox {
    static let shared = CommuteInbox()
    var pending: [CommuteImport]?
    /// Rules to add from an ev6://rules link, as backup text.
    var rules: String?
}

/// Asks before adding commutes from a link, then reads each route's link and saves them.
struct CommuteImportView: View {
    let list: [CommuteImport]
    @Environment(CommuteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var problems: [String] = []
    @State private var done = false
    /// How many commutes were saved.
    @State private var added = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Add these commutes? Each route is read from its Google Maps link. A commute with the same name is replaced.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list, id: \.name) { c in
                    Section(c.name) {
                        ForEach(Array(c.routes.enumerated()), id: \.offset) { i, r in
                            HStack {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                                Text(r.name)
                                if i == 0 { Spacer(); Text("favourite").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if !problems.isEmpty {
                    Section("Couldn't add") {
                        ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
                if done {
                    Section {
                        Label("Added \(added) commute\(added == 1 ? "" : "s"). Add the message and phone number in Trips › Manage commutes.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add commutes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "Close" : "Cancel") { dismiss() }
                }
                if !done {
                    ToolbarItem(placement: .confirmationAction) {
                        if working { ProgressView() } else { Button("Add") { Task { await add() } } }
                    }
                }
            }
        }
    }

    private func add() async {
        working = true
        defer { working = false }
        problems = []
        var saved = 0
        for c in list {
            var routes: [CommuteRoute] = []
            for r in c.routes {
                do {
                    routes.append(CommuteRoute(name: r.name, link: r.link, points: try await MapsLinkExpander.points(from: r.link)))
                } catch {
                    problems.append("\(c.name) · \(r.name): \((error as? GoogleMapsLink.Failure)?.description ?? error.localizedDescription)")
                }
            }
            guard !routes.isEmpty else { continue }
            var commute = model.commutes.first { $0.name.localizedCaseInsensitiveCompare(c.name) == .orderedSame } ?? Commute(name: c.name)
            commute.routes = routes
            if commute.name.localizedCaseInsensitiveCompare("Work") == .orderedSame, commute.message == Commute.defaultMessage {
                commute.message = "I'll be at work at {eta}"
            }
            await model.save(commute)
            saved += 1
        }
        added = saved
        // Nothing saved: keep Add so it can be tried again.
        done = saved > 0
    }
}
