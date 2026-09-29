import PreconditionKit
import SwiftUI

/// "Describe a rule": type (or dictate) what you want, see what was understood, then edit or save.
struct ComposeRuleView: View {
    @Environment(RulesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: RuleComposer.Result?
    @State private var rewritten: String?
    @State private var thinking = false
    @FocusState private var focused: Bool
    let openEditor: (Rule) -> Void

    private let examples = [
        "Weekdays at 7:30 heat to 22 if it's below 5",
        "When I leave work after 4pm and it's cold, warm the car",
        "Cool to 19 when I get home if it's over 25",
        "Every day at 6:45pm heat to 21 if plugged in",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("When and what", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { Task { await understand() } }
                    Button {
                        Task { await understand() }
                    } label: {
                        HStack {
                            Label("Create Rule", systemImage: "checkmark")
                            Spacer()
                            if thinking { ProgressView() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
                } footer: {
                    Text(RuleAI.isAvailable
                        ? "Worked out on your iPhone (Apple Intelligence helps with looser wording)."
                        : "Worked out on your iPhone.")
                }

                if let result {
                    if let rule = result.rule {
                        Section {
                            ForEach(result.understood, id: \.self) { line in
                                Label(line.capitalizingFirst, systemImage: "checkmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.primary)
                            }
                            if let rewritten {
                                Text("Read as: “\(rewritten)”").font(.footnote).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(rule.name)
                        }
                        Section {
                            Button("Save Rule") {
                                Task {
                                    if await model.save(rule).isEmpty { dismiss() } else { openEditor(rule) }
                                }
                            }
                            .disabled(!model.problems(rule).isEmpty)
                            Button("Edit Before Saving") { openEditor(rule) }
                        } footer: {
                            if !model.problems(rule).isEmpty {
                                Text(model.problems(rule).joined(separator: " "))
                            }
                        }
                    } else {
                        Section {
                            ForEach(result.problems, id: \.self) { Text($0) }
                        }
                    }
                }

                Section("Try") {
                    ForEach(examples, id: \.self) { example in
                        Button(example) {
                            text = example
                            Task { await understand() }
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Describe a Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func understand() async {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        focused = false
        thinking = true
        defer { thinking = false }
        rewritten = nil
        var composed = await model.compose(sentence)
        if composed.rule == nil, composed.unknownPlaces.isEmpty,
           let better = await RuleAI.rewrite(sentence, placeNames: model.places.map(\.name)) {
            let second = await model.compose(better)
            if second.rule != nil {
                composed = second
                rewritten = better
            }
        }
        withAnimation { result = composed }
    }
}
