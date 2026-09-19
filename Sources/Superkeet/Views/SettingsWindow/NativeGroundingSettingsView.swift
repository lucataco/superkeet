import SwiftUI

struct NativeGroundingSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var status = "Install the runtime with: bash scripts/install_grounder.sh"
    @State private var checking = false

    var body: some View {
        Section {
            Toggle("Native UI grounder (experimental)", isOn: $settings.nativeGroundingEnabled)
                .disabled(settings.isActionSessionActive)
            Text("Apple Intelligence plans the task. The local GLiNER fine-tune selects a control for each native click or text-field replacement through Cua Driver.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(checking ? "Loading grounder…" : "Check and Warm Runtime") {
                checking = true
                Task {
                    defer { checking = false }
                    do {
                        try await GLiNERChooser.shared.prepare()
                        status = "Ready — lucataco/gliner2.5-cua-grounder-macos-v1 (offline)."
                    } catch {
                        status = error.localizedDescription
                    }
                }
            }
            .disabled(checking || !settings.nativeGroundingEnabled || settings.isActionSessionActive)
            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } header: {
            Text("Native Grounding")
        } footer: {
            Text("Uses one named app with one visible window. Text entry replaces the selected field's value. Approval and audit settings apply; unverified actions stop without retrying.")
        }
        .onChange(of: settings.nativeGroundingEnabled) { _, enabled in
            if !enabled { Task { await GLiNERChooser.shared.stop() } }
        }
    }
}
