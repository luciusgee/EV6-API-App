import PreconditionKit
import SwiftUI

/// The log (HANDOVER.md §6.4): what happened and why, newest first.
struct ActivityView: View {
    @Environment(CarModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case commands = "Commands"
        case problems = "Problems"
        var id: String { rawValue }
    }

    private var entries: [LogEntry] {
        switch filter {
        case .all: return model.log
        case .commands: return model.log.filter { [.manual, .command, .fired].contains($0.kind) }
        case .problems: return model.log.filter { $0.kind == .error || $0.decision.contains("failed") || $0.decision == "refused" }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if entries.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    LogRow(entry: entry)
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.logCSV(), preview: SharePreview("EV6 Precondition log")) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.log.isEmpty)
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        if let details = entry.details, !details.isEmpty {
            DisclosureGroup {
                Text(details)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } label: {
                summary
            }
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.ruleName ?? entry.decision.capitalizingFirst)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.at, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.reason).font(.subheadline)
            let meta = [
                entry.httpCode.map { "HTTP \($0)" },
                entry.requestsUsed > 0 ? "\(entry.requestsUsed) request\(entry.requestsUsed == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
