import SwiftUI

/// What each release brought, newest first. Every build with something you'd use adds one at the top.
enum WhatsNew {
    struct Release: Identifiable {
        let number: Int
        let title: String
        let items: [Item]
        var id: Int { number }
    }

    struct Item: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }

        init(_ icon: String, _ title: String, _ detail: String) {
            self.icon = icon
            self.title = title
            self.detail = detail
        }
    }

    static let releases: [Release] = [
        Release(number: 1, title: "A proper EV scanner", items: [
            Item("stopwatch", "Performance timing", "0–60, 0–100 km/h, ¼ mile, standing mile, in-gear pulls and braking, timed from the car's own speed readings with splits, trap speed and power."),
            Item("flag.pattern.checkered.2.crossed", "Lap timer", "Set a start/finish line by driving across it; laps, best lap and a live delta from GPS."),
            Item("battery.100percent.bolt", "Battery report", "State of health, every cell, temperatures and lifetime totals, and a PDF report to share."),
            Item("exclamationmark.triangle", "Trouble codes", "Read and clear codes from every module, explained."),
            Item("car.side", "Demo car", "No adapter? Try everything with a simulated EV6 (More › Use the demo car)."),
        ]),
    ]

    static var latest: Int { releases.first?.number ?? 0 }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(WhatsNew.releases) { release in
                    Section(release.title) {
                        ForEach(release.items) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.title3)
                                    .foregroundStyle(.red)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.headline)
                                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("What's new")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
