import SwiftUI

struct AboutTabView: View {
    @State private var updateStatus: UpdateChecker.Result?
    @State private var checkingForUpdates = false
    private let websiteURL = URL(string: "https://catacolabs.com")
    private let modelURL = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
    private let onnxModelURL = URL(string: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx")
    private let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            AppIconView()

            VStack(spacing: 4) {
                Text("Superkeet")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Version \(AppVersion.current.displayString)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            updateSection

            Text("Voice-to-text powered by Parakeet — an on-device speech recognition engine using NVIDIA's Parakeet TDT 0.6B model.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                Text("Built with")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 4) {
                    creditRow("Speech Engine", "Parakeet TDT 0.6B v3 (ONNX)")
                    creditRow("Voice Detection", "Silero VAD v5")
                    creditRow("Inference", "ONNX Runtime")
                    creditRow("Framework", "SwiftUI + AppKit")
                }

                modelAttribution
            }

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                Text("Your audio and transcripts are processed on your Mac and never sent to the cloud. Superkeet goes online only to download the speech model, and to run any MCP servers you enable in Actions Mode.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                HStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                        .accessibilityHidden(true)
                    Text("On-device speech recognition")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Text("Made with love from")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let websiteURL {
                    Link("Catacolabs", destination: websiteURL)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 4) {
            Button(checkingForUpdates ? "Checking…" : "Check for Updates") {
                checkingForUpdates = true
                Task {
                    updateStatus = await UpdateChecker.check()
                    checkingForUpdates = false
                }
            }
            .disabled(checkingForUpdates)
            .controlSize(.small)

            switch updateStatus {
            case .upToDate(let current):
                Text("Superkeet \(current) is the latest version.")
                    .font(.caption).foregroundColor(.secondary)
            case .available(let version, let url):
                HStack(spacing: 4) {
                    Text("Superkeet \(version) is available.")
                    Link("Download", destination: url)
                    Text("or run `brew upgrade --cask superkeet`.")
                }
                .font(.caption)
            case .failed(let message):
                Text(message).font(.caption).foregroundColor(.orange)
            case nil:
                EmptyView()
            }
        }
    }

    /// The Parakeet model is licensed CC BY 4.0, which requires attribution.
    @ViewBuilder
    private var modelAttribution: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("Model:")
                if let modelURL { Link("Parakeet TDT 0.6B v3", destination: modelURL) }
                Text("by NVIDIA,")
                if let licenseURL { Link("CC BY 4.0", destination: licenseURL) }
            }
            HStack(spacing: 4) {
                Text("Converted to ONNX by")
                if let onnxModelURL { Link("istupakov", destination: onnxModelURL) }
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}
