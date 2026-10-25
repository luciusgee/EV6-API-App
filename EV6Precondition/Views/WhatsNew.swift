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
        Release(number: 2, title: "Ready for any car", items: [
            Item("car.fill", "Your car, live", "A drawing of your car built from its own data: the battery filling with charge, tyre pressures at each wheel, and power flowing to the motors or in from the charger."),
            Item("checkmark.seal", "Every E-GMP car, detected", "Kia EV6 and EV9, Hyundai Ioniq 5, 5 N, 6 and 9, Genesis GV60 and Electrified GV70, recognised from the VIN when you connect, with the right battery size."),
            Item("gauge.with.dots.needle.67percent", "Any other car too", "Speed, engine data, emission codes and performance timing on almost any car with standard OBD-II."),
            Item("bolt.car", "Charge curves", "Plug in with the app open to record the charge: power against charge, energy added and battery temperature (More › Charging)."),
            Item("hand.raised", "Privacy and safety", "Nothing leaves your phone. A short safety note before timing, and credits for the open-source data behind the decoding."),
        ]),
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
