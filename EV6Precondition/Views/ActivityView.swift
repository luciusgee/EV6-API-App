import PreconditionKit
import SwiftUI

/// The log (HANDOVER.md §6.4): what happened and why, newest first. Opened from Settings.
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

    /// Newest day first, entries newest first.
    private var days: [(Date, [LogEntry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { cal.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text(filter == .all ? "Nothing yet. Commands, rule decisions and problems appear here." : "Nothing here yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.0) { group in
                Section(dayTitle(group.0)) {
                    ForEach(group.1) { LogRow(entry: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.logCSV(), preview: SharePreview("EV6 Precondition log")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.log.isEmpty)
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

    private var icon: (String, Color) {
        switch entry.kind {
        case .command, .fired: return ("checkmark.circle.fill", .green)
        case .manual: return entry.decision == "sent" ? ("hand.tap.fill", .accentColor) : ("hand.raised.fill", .orange)
        case .skipped: return ("minus.circle", .secondary)
        case .dryRun: return ("play.circle", .accentColor)
        case .error: return ("exclamationmark.triangle.fill", .red)
        case .info: return ("info.circle", .secondary)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon.0)
                .foregroundStyle(icon.1)
                .font(.body)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.ruleName ?? entry.decision.capitalizingFirst)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(entry.at, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.reason)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                let meta = [
                    entry.trigger,
                    entry.httpCode.map { "HTTP \($0)" },
                    entry.requestsUsed > 0 ? "\(entry.requestsUsed) request\(entry.requestsUsed == 1 ? "" : "s")" : nil,
                ].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
