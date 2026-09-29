import MapKit
import PreconditionKit
import SwiftUI

/// Everything known about one charging site: connectors and speeds, status, price, live availability
/// and reviews (with a Google key), drivers' check-ins, and directions.
struct ChargeSiteView: View {
    let site: ChargeSite
    @Environment(CarModel.self) private var car
    @State private var live: PlaceInsight?
    @State private var liveProblem: String?
    @State private var loadingLive = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let op = site.operatorName {
                        Text(op.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(site.name).font(.title3.weight(.semibold))
                    if let address = site.address {
                        Text(address).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if let kw = site.maxKW { Badge(text: "\(Int(kw)) kW", tint: kw >= 100 ? .green : .teal) }
                        if site.rapidCount > 0 { Badge(text: "\(site.rapidCount) rapid", tint: .blue) }
                        if let status = site.status { Badge(text: status, tint: site.operational == false ? .red : .secondary) }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            } footer: {
                if let updated = site.statusUpdated { Text("Status updated \(updated.formatted(date: .abbreviated, time: .omitted)).") }
            }

            if let live {
                liveSection(live)
            } else if ChargerKeys.google != nil {
                Section("Right now") {
                    if loadingLive {
                        HStack {
                            ProgressView()
                            Text("Checking availability…").foregroundStyle(.secondary)
                        }
                    }
                    if let liveProblem { Text(liveProblem).foregroundStyle(.secondary) }
                }
            }

            Section("Connectors") {
                if site.connectors.isEmpty {
                    Text("No connector details listed.").foregroundStyle(.secondary)
                }
                ForEach(Array(site.connectors.enumerated()), id: \.offset) { _, c in
                    HStack {
                        Image(systemName: c.dc ? "bolt.fill" : "powerplug")
                            .foregroundStyle(c.operational == false ? .red : (c.dc ? .green : .secondary))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.type)
                            if c.operational == false { Text("Not working").font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        Text(c.kW.map { "\(c.count) × \(Int($0)) kW" } ?? "\(c.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let cost = site.cost, !cost.isEmpty { LabeledContent("Price", value: cost) }
                if let access = site.access { LabeledContent("Access", value: access) }
            }

            if !site.comments.isEmpty {
                Section {
                    ForEach(Array(site.comments.prefix(12).enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if let checkin = c.checkin {
                                    Label(checkin, systemImage: c.positive == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(c.positive == false ? .red : .green)
                                }
                                Spacer()
                                if let rating = c.rating { Stars(rating: Double(rating)) }
                            }
                            if let text = c.text, !text.isEmpty { Text(text).font(.subheadline) }
                            Text([c.user, c.date?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Drivers' check-ins")
                        Spacer()
                        if let r = site.rating { Stars(rating: r) }
                    }
                } footer: {
                    Text("From Open Charge Map.")
                }
            }

            Section {
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: site.position.lat, longitude: site.position.lon)))
                    item.name = site.name
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                } label: {
                    Label("Directions in Apple Maps", systemImage: "location.fill")
                }
                if let url = live?.mapsURL {
                    Link(destination: url) { Label("Open in Google Maps", systemImage: "map") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(site.operatorName ?? "Charger")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLive() }
    }

    @ViewBuilder
    private func liveSection(_ live: PlaceInsight) -> some View {
        Section {
            if live.availability.isEmpty {
                Text("The operator doesn't share live availability.").foregroundStyle(.secondary)
            }
            ForEach(Array(live.availability.enumerated()), id: \.offset) { _, a in
                HStack {
                    Text("\(a.type)\(a.kW.map { " · \(Int($0)) kW" } ?? "")")
                    Spacer()
                    if let free = a.available {
                        Text("\(free) of \(a.count) free")
                            .monospacedDigit()
                            .foregroundStyle(free > 0 ? .green : .orange)
                    } else {
                        Text("\(a.count) total").foregroundStyle(.secondary)
                    }
                }
                if let broken = a.outOfService, broken > 0 {
                    Text("\(broken) out of service").font(.caption).foregroundStyle(.red)
                }
            }
            if let rating = live.rating {
                HStack {
                    Stars(rating: rating)
                    Text(String(format: "%.1f", rating)).monospacedDigit()
                    if let n = live.ratingCount { Text("(\(n) Google reviews)").foregroundStyle(.secondary) }
                }
                .font(.subheadline)
            }
            ForEach(Array(live.reviews.prefix(5).enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let rating = r.rating { Stars(rating: Double(rating)) }
                        Spacer()
                        Text([r.author, r.when].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let text = r.text { Text(text).font(.subheadline).lineLimit(6) }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Right now")
        } footer: {
            if let updated = live.availability.compactMap(\.updated).max() {
                Text("Availability from Google, updated \(updated.formatted(date: .omitted, time: .shortened)).")
            }
        }
    }

    private func loadLive() async {
        guard live == nil, let key = ChargerKeys.google else { return }
        loadingLive = true
        defer { loadingLive = false }
        do {
            live = try await GooglePlacesClient(transport: URLSessionTransport(), key: key).insight(near: site.position)
        } catch {
            liveProblem = (error as? GooglePlacesClient.Failure)?.description ?? "Couldn't reach Google."
        }
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

struct Stars: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: rating >= Double(i) + 0.75 ? "star.fill" : (rating >= Double(i) + 0.25 ? "star.leadinghalf.filled" : "star"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.yellow)
        .accessibilityElement()
        .accessibilityLabel(String(format: "%.1f stars", rating))
    }
}
