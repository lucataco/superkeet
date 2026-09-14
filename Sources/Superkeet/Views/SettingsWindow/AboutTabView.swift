import SwiftUI

struct AboutTabView: View {
    private let websiteURL = URL(string: "https://catacolabs.com")

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

            Text("Voice-to-text powered by Parakeet — a fully local, offline speech recognition engine using NVIDIA's Parakeet TDT 0.6B model.")
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
                    creditRow("Inference", "ONNX Runtime with CoreML")
                    creditRow("Framework", "SwiftUI + AppKit")
                }
            }

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                Text("All audio is processed locally on your Mac. Nothing is sent to the cloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                    Text("100% Private & Offline")
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
