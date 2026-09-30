import MapKit
import MessageUI
import PreconditionKit
import SwiftUI

/// Your commutes: which way to go now, and your ETA message.
struct CommuteView: View {
    @Environment(CommuteModel.self) private var model
    @State private var adding = false

    var body: some View {
        List {
            if model.commutes.isEmpty {
                Section {
                    Text("Add the routes you drive, from Google Maps links. The app checks traffic on each, picks the way you'd rather go unless it's much slower, and writes your ETA message.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.commutes) { commute in
                NavigationLink {
                    CommuteDetailView(id: commute.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commute.name).font(.headline)
                        Text(model.advice[commute.id]?.headline ?? "\(commute.routes.count) route\(commute.routes.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Section {
                Button {
                    adding = true
                } label: {
                    Label("Add a commute", systemImage: "plus")
                }
                ForEach(missingWayBack) { c in
                    Button {
                        Task { await addWayBack(c) }
                    } label: {
                        Label("Make the way back from \(c.name)", systemImage: "arrow.uturn.backward")
                    }
                }
            } footer: {
                if !missingWayBack.isEmpty {
                    Text("Adds the same routes the other way, so the quick check knows where you're going from either end.")
                }
            }
            if !model.commutes.isEmpty {
                Section {
                    DisclosureGroup("Run it automatically") {
                        Text(Self.automationHelp).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Commutes")
        .sheet(isPresented: $adding) {
            CommuteEditView(commute: Commute(name: model.commutes.isEmpty ? "Home" : "Work"), isNew: true)
        }
    }

    /// Commutes with nothing starting where they end.
    private var missingWayBack: [Commute] {
        model.commutes.filter { c in
            guard let end = c.end else { return false }
            return model.commutes.starting(near: end) == nil
        }
    }

    private func addWayBack(_ c: Commute) async {
        let home = c.name.localizedCaseInsensitiveContains("home")
        let name = home ? "Work" : "Home"
        let message = home ? "I'll be at work at {eta}" : Commute.defaultMessage
        await model.save(c.reversed(name: name, message: message))
    }

    static let automationHelp = """
    The app can check by itself: open a commute, tap Edit, and turn on Check automatically. It notifies you \
    with the quickest way and your ETA message, one tap to send. iOS only lets Shortcuts send a message with \
    no tap at all: make an automation (a time, or leaving work) set to Run Immediately, with Check my commute \
    from My EV6, then Send Message with its result.
    """
}

struct CommuteDetailView: View {
    let id: UUID
    @Environment(CommuteModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var editing = false
    @State private var composing = false
    /// A check has finished since the screen opened, so no advice means it failed.
    @State private var tried = false
    @Environment(\.dismiss) private var dismiss

    private var commute: Commute? { model.commutes.first { $0.id == id } }
    private var advice: CommuteAdvice? { model.advice[id] }
    private var checking: Bool { model.checking.contains(id) }

    var body: some View {
        List {
            if let commute {
                summary
                routes(commute)
                messageSection(commute)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(commute?.name ?? "Commute")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
            }
        }
        .refreshable {
            await model.check(id)
            tried = true
        }
        .onChange(of: commute == nil) { _, gone in
            // Deleted from the edit sheet: there's nothing left to show.
            if gone { dismiss() }
        }
        .task {
            // Checking costs a Google request per route; don't redo one from the last few minutes.
            if let a = advice, Date().timeIntervalSince(a.checkedAt) < 180 { return }
            await model.check(id)
            tried = true
        }
        .sheet(isPresented: $editing) {
            if let commute { CommuteEditView(commute: commute, isNew: false) }
        }
        .sheet(isPresented: $composing) {
            if let commute, let text = messageText {
                MessageComposer(recipient: commute.recipient, text: text).ignoresSafeArea()
            }
        }
    }

    private var messageText: String? {
        model.message(for: id) { $0.formatted(date: .omitted, time: .shortened) }
    }

    private var summary: some View {
        Section {
            if checking && advice == nil {
                HStack {
                    ProgressView()
                    Text("Checking traffic…").foregroundStyle(.secondary)
                }
            } else if let advice {
                VStack(alignment: .leading, spacing: 8) {
                    if let arrival = advice.arrival {
                        Text("Arrive \(arrival.formatted(date: .omitted, time: .shortened))")
                            .font(.largeTitle.weight(.bold))
                            .monospacedDigit()
                    }
                    Text(advice.headline).font(.headline)
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text("Checked \(advice.checkedAt.formatted(date: .omitted, time: .shortened)). Pull down to check again.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if tried && !checking {
                Text("Couldn't check the traffic. Pull down to try again.").foregroundStyle(.secondary)
            }
        }
    }

    private func routes(_ commute: Commute) -> some View {
        Section {
            if commute.routes.isEmpty {
                Text("No routes yet. Tap Edit to add them.").foregroundStyle(.secondary)
            }
            ForEach(commute.routes) { route in
                let check = advice?.checks.first { $0.id == route.id }
                Button {
                    if let url = route.mapsURL { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: advice?.pick?.id == route.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(advice?.pick?.id == route.id ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name).foregroundStyle(.primary)
                            if let problem = check?.problem {
                                Text(problem).font(.caption).foregroundStyle(.red)
                            } else if let delay = check?.time?.delayMinutes {
                                Text(delay < 5 ? "Clear" : "\(delay) min of traffic")
                                    .font(.caption)
                                    .foregroundStyle(delay < 5 ? .green : (delay < 15 ? .orange : .red))
                            }
                        }
                        Spacer()
                        if let t = check?.time {
                            Text("\(t.minutes) min").font(.headline).monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                }
            }
        } header: {
            Text("Routes")
        } footer: {
            Text("In the order you'd rather take them. Tap one to see it in Google Maps.")
        }
    }

    private func messageSection(_ commute: Commute) -> some View {
        Section {
            if let text = messageText {
                Text(text)
                Button {
                    send(commute, text: text)
                } label: {
                    Label("Send with \(commute.channel.title)", systemImage: commute.channel == .messages ? "message.fill" : "paperplane.fill")
                }
                ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
            } else {
                Text("Your message will show here once the traffic's been checked.").foregroundStyle(.secondary)
            }
        } header: {
            Text("ETA message")
        }
    }

    private func send(_ commute: Commute, text: String) {
        switch commute.channel {
        case .messages:
            if MFMessageComposeViewController.canSendText() {
                composing = true
            } else if let url = URL(string: "sms:\(commute.recipient)") {
                openURL(url)
            }
        case .whatsapp:
            if let url = WhatsApp.url(to: commute.recipient, text: text) { openURL(url) }
        }
    }
}

enum WhatsApp {
    /// wa.me wants the number with its country code and no "+"; a UK 07… number becomes 447….
    static func number(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("00") { digits.removeFirst(2) } else if digits.hasPrefix("0") { digits = "44" + digits.dropFirst() }
        return digits
    }

    static func url(to recipient: String, text: String) -> URL? {
        var c = URLComponents(string: "https://wa.me/\(number(recipient))")
        c?.queryItems = [URLQueryItem(name: "text", value: text)]
        return c?.url
    }
}

/// The Messages compose sheet, filled in; you tap send.
struct MessageComposer: UIViewControllerRepresentable {
    let recipient: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        if !recipient.isEmpty { vc.recipients = [recipient] }
        vc.body = text
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            dismiss()
        }
    }
}

struct CommuteEditView: View {
    @State var commute: Commute
    let isNew: Bool
    @Environment(CommuteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newLink = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var saving = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Home", text: $commute.name)
                        .submitLabel(.done)
                }
                Section {
                    ForEach(Array(commute.routes.enumerated()), id: \.element.id) { i, route in
                        NavigationLink {
                            CommuteRouteEditView(
                                route: route,
                                position: i,
                                count: commute.routes.count,
                                onChange: { changed in
                                    if let at = commute.routes.firstIndex(where: { $0.id == changed.id }) { commute.routes[at] = changed }
                                },
                                onMove: { offset in
                                    guard let at = commute.routes.firstIndex(where: { $0.id == route.id }) else { return }
                                    let to = min(max(0, at + offset), commute.routes.count - 1)
                                    let r = commute.routes.remove(at: at)
                                    commute.routes.insert(r, at: to)
                                },
                                onDelete: { commute.routes.removeAll { $0.id == route.id } }
                            )
                        } label: {
                            HStack {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                                Text(route.name)
                                if i == 0 { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                                Spacer()
                                Text("\(max(0, route.points.count - 2)) via").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { commute.routes.remove(atOffsets: $0) }
                    .onMove { commute.routes.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Routes, favourite first")
                } footer: {
                    Text("Tap a route to rename it, change its link or move it. The first (★) is used unless another is more than \(commute.toleranceMinutes) min quicker.")
                }
                Section {
                    TextField("Name, e.g. M1 and A14", text: $newName)
                        .submitLabel(.next)
                    TextField("Google Maps link", text: $newLink, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await addRoute() }
                    } label: {
                        HStack {
                            Text("Add route")
                            if adding { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(newLink.isEmpty || adding)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Add a route")
                } footer: {
                    Text("Paste the link you share from Google Maps (the same ones your shortcut opens). The start, end and the points you dragged the route through are read from it.")
                }
                Section {
                    Toggle("When I drive away from the start", isOn: $commute.auto.whenLeaving)
                    Toggle("At a set time", isOn: Binding(
                        get: { commute.auto.remindAt != nil },
                        set: { commute.auto.remindAt = $0 ? ClockTime(hour: 17) : nil }
                    ))
                    if let at = commute.auto.remindAt {
                        DatePicker("Time", selection: Binding(get: { at.date }, set: { commute.auto.remindAt = ClockTime(date: $0) }),
                                   displayedComponents: .hourAndMinute)
                        DaysPicker(days: $commute.auto.days)
                    }
                } header: {
                    Text("Check automatically")
                } footer: {
                    Text(commute.auto.whenLeaving
                         ? "Driving away from where this commute starts checks the traffic and notifies you. It needs location access set to Always. Tap the notification to send your ETA."
                         : "A notification with the quickest way and your ETA, one tap to send.")
                }
                Section {
                    Stepper(commute.toleranceMinutes == 0 ? "Always take the quickest" : "Allow \(commute.toleranceMinutes) min slower", value: $commute.toleranceMinutes, in: 0...45, step: 5)
                } footer: {
                    Text("How much longer your favourite can take before another route is suggested.")
                }
                Section {
                    TextField("Message", text: $commute.message, axis: .vertical)
                    TextField("Phone number", text: $commute.recipient)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    Picker("Send with", selection: $commute.channel) {
                        ForEach(MessageChannel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("ETA message")
                } footer: {
                    Text("{eta} becomes your arrival time, {minutes} the drive and {route} the way you're going.")
                }
                if !isNew {
                    Section {
                        Button("Delete commute", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New commute" : commute.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            await model.save(commute)
                            dismiss()
                        }
                    }
                    .disabled(saving || commute.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this commute?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.delete(commute.id)
                        dismiss()
                    }
                }
            }
        }
    }

    private func addRoute() async {
        adding = true
        defer { adding = false }
        problem = nil
        do {
            let points = try await MapsLinkExpander.points(from: newLink)
            let name = newName.trimmingCharacters(in: .whitespaces)
            commute.routes.append(CommuteRoute(name: name.isEmpty ? "Route \(commute.routes.count + 1)" : name,
                                               link: newLink.trimmingCharacters(in: .whitespacesAndNewlines), points: points))
            newName = ""
            newLink = ""
        } catch let failure as GoogleMapsLink.Failure {
            problem = failure.description
        } catch {
            problem = "Couldn't open the link: \(error.localizedDescription)"
        }
    }
}

/// One commute route: its name, where it goes, its link, and its place in the order.
struct CommuteRouteEditView: View {
    @State var route: CommuteRoute
    let position: Int
    let count: Int
    let onChange: (CommuteRoute) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newLink = ""
    @State private var replacing = false
    @State private var problem: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $route.name)
                    .submitLabel(.done)
            }
            if route.points.count >= 2 {
                Section {
                    Map(initialPosition: .automatic) {
                        MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 4)
                        ForEach(Array(coords.enumerated()), id: \.offset) { i, c in
                            if i == 0 {
                                Marker("Start", systemImage: "circle.fill", coordinate: c).tint(.blue)
                            } else if i == coords.count - 1 {
                                Marker("End", coordinate: c).tint(.red)
                            } else {
                                Marker("Via \(i)", systemImage: "arrow.triangle.turn.up.right.diamond.fill", coordinate: c).tint(.orange)
                            }
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                    if let url = route.mapsURL {
                        Link(destination: url) { Label("Open in Google Maps", systemImage: "map") }
                    }
                } footer: {
                    Text("Straight lines between the start, the points it goes through, and the end. Traffic checks follow the roads through those points.")
                }
            }
            Section {
                TextField("New Google Maps link", text: $newLink, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await replace() }
                } label: {
                    HStack {
                        Text("Use this link")
                        if replacing { Spacer(); ProgressView() }
                    }
                }
                .disabled(newLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacing)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Change the route")
            } footer: {
                Text("Drag the route in Google Maps the way you drive it, share it, and paste the link here.")
            }
            Section {
                if position > 0 {
                    Button { onMove(-position); dismiss() } label: { Label("Make favourite", systemImage: "star") }
                    Button { onMove(-1); dismiss() } label: { Label("Move up", systemImage: "arrow.up") }
                }
                if position < count - 1 {
                    Button { onMove(1); dismiss() } label: { Label("Move down", systemImage: "arrow.down") }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete route", systemImage: "trash") }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(route.name.isEmpty ? "Route" : route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: route) { _, r in onChange(r) }
        .confirmationDialog("Delete this route?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        }
    }

    private var coords: [CLLocationCoordinate2D] {
        route.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    private func replace() async {
        replacing = true
        defer { replacing = false }
        problem = nil
        let link = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            route.points = try await MapsLinkExpander.points(from: link)
            route.link = link
            newLink = ""
        } catch let failure as GoogleMapsLink.Failure {
            problem = failure.description
        } catch {
            problem = "Couldn't open the link: \(error.localizedDescription)"
        }
    }
}

/// Checks the commute that starts where you are: at home the way to work, at work the way home.
struct QuickCommuteButton: View {
    @Environment(CommuteModel.self) private var model
    @Environment(CarModel.self) private var car
    @State private var finding = false
    @State private var note: String?

    /// A guess from where the car's parked, for the label, before asking for your location.
    private var guess: Commute? {
        car.snapshot?.parkingPosition.flatMap { model.commutes.starting(near: $0) }
    }

    var body: some View {
        Button {
            Task { await go() }
        } label: {
            HStack {
                Label(guess.map { "Check traffic: \($0.name)" } ?? "Check traffic from here", systemImage: "location.fill")
                    .font(.body.weight(.semibold))
                Spacer()
                if finding { ProgressView() }
            }
        }
        .disabled(finding || model.commutes.isEmpty)
        if let note {
            Text(note).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func go() async {
        finding = true
        defer { finding = false }
        note = nil
        LocationAccess.shared.requestIfNeeded()
        let here = await LocationPhoneLocator().locate() ?? car.snapshot?.parkingPosition
        if let here, let c = model.commutes.starting(near: here) {
            CommuteInbox.shared.open = c.id
        } else if model.commutes.count == 1 {
            CommuteInbox.shared.open = model.commutes[0].id
        } else {
            note = here == nil
                ? "Couldn't tell where you are. Pick a commute below."
                : "You're not at the start of a commute. Pick one below, or add the way back."
        }
    }
}
