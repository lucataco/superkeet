import SwiftUI

struct PhraseReplacementsView: View {
    @ObservedObject private var store = PhraseReplacementStore.shared
    @State private var phrase = ""
    @State private var replacement = ""
    @State private var bundleID = ""

    private var draft: PhraseReplacement {
        PhraseReplacement(
            phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines),
            replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var body: some View {
        Section {
            ForEach(store.rules) { rule in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(rule.phrase) → \(rule.replacement)")
                        Text(rule.bundleID.isEmpty ? "All applications" : rule.bundleID)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { store.save(store.rules.filter { $0.id != rule.id }) }
                        .accessibilityLabel("Remove replacement for \(rule.phrase)")
                }
            }
            TextField("Heard phrase (for example, off middleware)", text: $phrase)
            TextField("Replace with (for example, auth middleware)", text: $replacement)
            TextField("App bundle identifier (blank for all apps)", text: $bundleID)
            Button("Add Phrase Replacement") {
                store.save(store.rules + [draft])
                if store.errorMessage == nil { phrase = ""; replacement = ""; bundleID = "" }
            }
            .disabled(!draft.isValid)
            if let error = store.errorMessage { Text(error).foregroundStyle(.orange) }
        } header: {
            Text("Personal Phrase Replacements")
        } footer: {
            Text("Explicit, whole-phrase replacements after recognition. App-specific rules take priority. Use a narrow phrase such as ‘off middleware’, rather than replacing ‘off’ everywhere. These rules do not bias the speech model.")
        }
    }
}
