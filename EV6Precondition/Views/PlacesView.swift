import CoreLocation
import MapKit
import PreconditionKit
import SwiftUI

/// Places for leave/arrive rules: home, work, the gym. Each is a circle on the map.
struct PlacesView: View {
    @Environment(RulesModel.self) private var model
    @Environment(CarModel.self) private var car
    @State private var editing: Place?

    var body: some View {
        List {
            if !model.places.isEmpty {
                Section {
                    Map(interactionModes: []) {
                        ForEach(model.places) { place in
                            MapCircle(center: place.centre.coordinate, radius: Double(place.radiusM))
                                .foregroundStyle(Color.accentColor.opacity(0.2))
                                .stroke(Color.accentColor, lineWidth: 1.5)
                            Marker(place.name, systemImage: icon(place.name), coordinate: place.centre.coordinate)
                        }
                        if let parked = car.snapshot?.parkingPosition {
                            Marker("EV6", systemImage: "car.fill", coordinate: parked.coordinate).tint(.green)
                        }
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
            }
            Section {
                ForEach(model.places) { place in
                    Button {
                        editing = place
                    } label: {
                        HStack {
                            Label(place.name, systemImage: icon(place.name))
                            Spacer()
                            let count = model.rulesUsing(placeId: place.id).count
                            Text(count == 0 ? "No rules" : "\(count) rule\(count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Button {
                    editing = model.newPlace(at: car.snapshot?.parkingPosition ?? LatLon(lat: 51.5072, lon: -0.1276))
                } label: {
                    Label("Add Place", systemImage: "plus")
                }
            } footer: {
                Text("Rules can start climate when you leave or arrive at a place. iOS watches the boundaries, even with the app closed, using hardly any battery.")
            }
        }
        .navigationTitle("Places")
        .sheet(item: $editing) { place in
            PlaceEditorView(place: place, isNew: !model.places.contains { $0.id == place.id })
        }
    }

    private func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("home") || n.contains("house") { return "house.fill" }
        if n.contains("work") || n.contains("office") { return "briefcase.fill" }
        if n.contains("gym") { return "dumbbell.fill" }
        if n.contains("school") { return "graduationcap.fill" }
        if n.contains("shop") || n.contains("store") { return "cart.fill" }
        return "mappin.circle.fill"
    }
}

struct PlaceEditorView: View {
    @Environment(RulesModel.self) private var model
    @Environment(CarModel.self) private var car
    @Environment(\.dismiss) private var dismiss
    @State private var place: Place
    @State private var camera: MapCameraPosition
    @State private var search = ""
    @State private var searching = false
    @State private var inUse: [String]?
    let isNew: Bool

    init(place: Place, isNew: Bool) {
        _place = State(initialValue: place)
        _camera = State(initialValue: .region(MKCoordinateRegion(center: place.centre.coordinate, latitudinalMeters: Double(place.radiusM) * 5, longitudinalMeters: Double(place.radiusM) * 5)))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Home or Work", text: $place.name)
                }
                Section {
                    MapReader { proxy in
                        Map(position: $camera) {
                            MapCircle(center: place.centre.coordinate, radius: Double(place.radiusM))
                                .foregroundStyle(Color.accentColor.opacity(0.25))
                                .stroke(Color.accentColor, lineWidth: 2)
                            Marker(place.name.isEmpty ? "Place" : place.name, coordinate: place.centre.coordinate)
                            if let parked = car.snapshot?.parkingPosition {
                                Marker("EV6", systemImage: "car.fill", coordinate: parked.coordinate).tint(.green)
                            }
                            UserAnnotation()
                        }
                        .mapControls { MapUserLocationButton() }
                        .onTapGesture { point in
                            if let c = proxy.convert(point, from: .local) {
                                withAnimation { place.centre = LatLon(lat: c.latitude, lon: c.longitude) }
                            }
                        }
                    }
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
                    HStack {
                        TextField("Search address", text: $search)
                            .submitLabel(.search)
                            .onSubmit { Task { await find() } }
                        if searching { ProgressView() }
                    }
                } footer: {
                    Text("Tap the map to move the centre.")
                }
                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("Radius", value: Describe.distance(place.radiusM))
                        Slider(
                            value: Binding(get: { Double(place.radiusM) }, set: { place.radiusM = Int($0) }),
                            in: Double(Place.minRadiusM)...Double(Place.maxRadiusM),
                            step: 50
                        )
                    }
                    if let parked = car.snapshot?.parkingPosition {
                        Button {
                            withAnimation { place.centre = parked; recentre() }
                        } label: {
                            Label("Use the Car's Position", systemImage: "car.fill")
                        }
                    }
                    Button {
                        Task { await useMyLocation() }
                    } label: {
                        Label("Use My Location", systemImage: "location.fill")
                    }
                } footer: {
                    Text("150–300 m suits a house; a bigger circle suits a large site. iOS notices a crossing within a minute or two, usually a little way past the edge.")
                }
                if !isNew {
                    Section {
                        Button("Delete Place", role: .destructive) {
                            Task {
                                if let users = await model.deletePlace(id: place.id) {
                                    inUse = users
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    } footer: {
                        if let inUse {
                            Text("Used by \(inUse.joined(separator: ", ")). Change or delete those rules first.").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Place" : place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save(place: place)
                            dismiss()
                        }
                    }
                    .disabled(place.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: place.radiusM) { _, _ in recentre() }
        }
    }

    private func recentre() {
        camera = .region(MKCoordinateRegion(center: place.centre.coordinate, latitudinalMeters: Double(place.radiusM) * 5, longitudinalMeters: Double(place.radiusM) * 5))
    }

    private func find() async {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: place.centre.coordinate, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        let c = item.placemark.coordinate
        withAnimation {
            place.centre = LatLon(lat: c.latitude, lon: c.longitude)
            if place.name.isEmpty { place.name = item.name ?? "" }
            recentre()
        }
    }

    private func useMyLocation() async {
        LocationAccess.shared.requestIfNeeded()
        if let here = await LocationPhoneLocator().locate() {
            withAnimation {
                place.centre = here
                recentre()
            }
        }
    }
}

extension LatLon {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
