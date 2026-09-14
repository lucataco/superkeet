import SwiftUI

struct LastTranscriptView: View {
    @ObservedObject private var service = ParakeetService.shared
    @State private var showOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service.sessionStatus).font(.headline)
            if let error = service.lastUserFacingError {
                Text(error).foregroundStyle(.orange).font(.caption)
            }
            if !service.lastRawTranscription.isEmpty {
                Toggle("Show original (before text changes)", isOn: $showOriginal)
                ScrollView {
                    Text(showOriginal ? service.lastRawTranscription : service.lastTranscription)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                HStack {
                    Button("Copy Last Transcript") { PasteService.shared.copyToClipboard(service.lastTranscription) }
                    Button("Copy Original") { PasteService.shared.copyToClipboard(service.lastRawTranscription) }
                    Button("Undo Text Changes and Copy") { service.undoLastTextChanges() }
                        .disabled(!service.canUndoTextChanges)
                }
                .controlSize(.small)
            }
            Text("The last result and its original text stay in memory until the next result or app exit. Undo copies restored text; paste it to replace text already inserted in another app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
