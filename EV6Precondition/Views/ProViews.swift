import SwiftUI

/// Shows `content` with Pro, otherwise a card offering it.
struct ProLock<Content: View>: View {
    @Environment(Store.self) private var store
    let feature: String
    @ViewBuilder let content: Content
    @State private var showing = false

    init(feature: String, @ViewBuilder content: () -> Content) {
        self.feature = feature
        self.content = content()
    }

    var body: some View {
        if store.isPro {
            content
        } else {
            Button {
                showing = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(feature) is in Pro").font(.headline)
                        Text("One purchase, no subscription.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showing) { ProSheet() }
        }
    }
}

/// What Pro adds, with Buy and Restore.
struct ProSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false

    struct Feature: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let features = [
        Feature(icon: "doc.richtext", title: "Battery report PDF", detail: "A spec-sheet report of the battery to keep or give a buyer."),
        Feature(icon: "flag.pattern.checkered.2.crossed", title: "Lap timer", detail: "GPS laps with a live delta to your best."),
        Feature(icon: "bolt.car", title: "Charge history", detail: "Every charge's power curve, energy and temperatures."),
        Feature(icon: "record.circle", title: "Data recording", detail: "Log any sensors to a spreadsheet file."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                        .padding(.top, 12)
                    Text("\(AppInfo.name) Pro").font(.largeTitle.weight(.bold))
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Self.features) { f in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: f.icon).font(.title3).foregroundStyle(.orange).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title).font(.headline)
                                    Text(f.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button {
                        Task { await store.buy() }
                    } label: {
                        Text(store.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock Pro")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .foregroundStyle(Color.black)
                    .disabled(store.product == nil || store.busy)
                    if store.product == nil {
                        if loading {
                            ProgressView()
                        } else {
                            Text("Couldn't reach the App Store. Try again.").font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { Task { await loadProduct() } }
                        }
                    }
                    Button("Restore purchase") { Task { await store.restore() } }
                        .disabled(store.busy)
                    if let error = store.error {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    Text("A one-off purchase, shared with your family through Family Sharing. Live data, trouble codes, the battery check, live charge recording and performance timing stay free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: store.isPro) { _, pro in if pro { dismiss() } }
            .task { await loadProduct() }
        }
    }

    /// Start only fetches the product once; fetch it again if that failed or came back empty.
    @MainActor
    private func loadProduct() async {
        guard store.product == nil, !loading else { return }
        loading = true
        defer { loading = false }
        await store.loadProduct()
    }
}
