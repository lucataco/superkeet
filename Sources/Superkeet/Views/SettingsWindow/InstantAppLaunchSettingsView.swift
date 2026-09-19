import SwiftUI

/// Settings for opening apps the moment they are named while speaking a command.
struct InstantAppLaunchSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = SpeculativeLaunchCoordinator.shared

    @State private var availability: PartialTranscriptAvailability?
    @State private var recognizerName: String?
    @State private var installing = false
    @State private var installError: String?

    var body: some View {
        Section {
            Toggle(isOn: $settings.instantAppLaunchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch apps instantly while speaking")
                    Text("“Open Notes and…” opens Notes as soon as the name is heard, without waiting for you to finish or approving it first. Only installed apps can be opened or switched to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.actionsEnabled || settings.isActionSessionActive)

            statusRow
        } header: {
            Text("Instant App Launch")
        } footer: {
            Text("Spots app names in the interim text of the Parakeet engine (protocol 2), or of Apple's on-device recogniser on older engines. The final transcript always comes from Parakeet, and the command reuses the launch instead of opening the app twice. Early launches are recorded in the action log.")
        }
        .task(id: settings.actionsEnabled) { await refreshAvailability() }
        .task(id: ParakeetService.shared.daemonProtocolVersion) { await refreshAvailability() }
        .onChange(of: settings.instantAppLaunchEnabled) { _, enabled in
            if enabled { Task { await SpeculativeLaunchCoordinator.shared.prepare() } }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if availability == .assetsNotInstalled {
                    Button(installing ? "Downloading…" : "Download Speech Model") {
                        installing = true
                        installError = nil
                        Task {
                            defer { installing = false }
                            do {
                                try await coordinator.installAssets()
                            } catch {
                                installError = error.localizedDescription
                            }
                            await refreshAvailability()
                        }
                    }
                    .controlSize(.small)
                    .disabled(installing || !settings.instantAppLaunchEnabled)
                }
                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard settings.actionsEnabled else { return "Turn on Actions Mode to use instant launches." }
        guard settings.instantAppLaunchEnabled else { return "Off. Apps open only after the full command is transcribed and approved." }
        guard let availability else { return "Checking the speech recogniser…" }
        if let message = availability.userFacingMessage { return message }
        let via = recognizerName.map { " Interim text comes from \($0)." } ?? ""
        return "Ready. Apps open about a second after you say their name.\(via)"
    }

    private var statusSymbol: String {
        guard settings.actionsEnabled, settings.instantAppLaunchEnabled, let availability else { return "info.circle" }
        return availability.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        guard settings.actionsEnabled, settings.instantAppLaunchEnabled, let availability else { return .secondary }
        return availability.isAvailable ? .green : .orange
    }

    private func refreshAvailability() async {
        guard settings.actionsEnabled else { return }
        availability = await coordinator.availability()
        recognizerName = await coordinator.recognizerName()
    }
}
