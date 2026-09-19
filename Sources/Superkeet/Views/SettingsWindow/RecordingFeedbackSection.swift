import SwiftUI

/// Overlay style and sound cues: how Superkeet tells you it is listening. Lives on the General
/// tab next to the shortcuts because it is part of the recording experience, not output routing.
struct RecordingFeedbackSection: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(OverlayAnimationStyle.allCases) { style in
                    VisualizationOption(
                        title: style.title,
                        description: style.subtitle,
                        icon: style.symbolName,
                        location: style.locationLabel,
                        isSelected: settings.overlayAnimationStyle == style
                    ) {
                        settings.recordingOverlayStyle = style.rawValue
                    }
                }
            }
            .padding(.vertical, 4)

            Picker(selection: $settings.captureSoundStyle) {
                ForEach(CaptureSoundStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbolName).tag(style.rawValue)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound Cues")
                    Text("Start and stop sounds while recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recording Feedback")
        } footer: {
            Text("The overlay stays up while transcribing and confirms when your text is copied or pasted.")
        }
    }
}

struct VisualizationOption: View {
    let title: String
    let description: String
    let icon: String
    var location: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(height: 24)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Text(description)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let location {
                    Text(location.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
