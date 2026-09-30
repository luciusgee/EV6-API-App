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
        .navigationTitle("Commute")
        .sheet(isPresented: $adding) {
            CommuteEditView(commute: Commute(name: model.commutes.isEmpty ? "Home" : "Work"), isNew: true)
        }
    }

    static let automationHelp = """
    In Shortcuts, create an automation (a time on weekdays, or when you leave work) and set it to Run \
    Immediately. Add Check my commute from My EV6, then Send Message with its result.
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
                    if let url = URL(string: route.link) { openURL(url) }
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
                    ForEach($commute.routes) { $route in
                        let i = commute.routes.firstIndex { $0.id == route.id } ?? 0
                        HStack {
                            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                            TextField("Name", text: $route.name)
                                .submitLabel(.done)
                            Spacer()
                            Text("\(max(0, route.points.count - 2)) via").font(.caption).foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            if i > 0 { Button("Move up") { commute.routes.swapAt(i, i - 1) } }
                            if i < commute.routes.count - 1 { Button("Move down") { commute.routes.swapAt(i, i + 1) } }
                        }
                    }
                    .onDelete { commute.routes.remove(atOffsets: $0) }
                    .onMove { commute.routes.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Routes, favourite first")
                } footer: {
                    Text("Press and hold a route to move it. The first is used unless another is more than \(commute.toleranceMinutes) min quicker.")
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
