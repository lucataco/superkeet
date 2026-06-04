import SwiftUI

/// Floating pill-shaped overlay window shown during recording.
/// Supports compact (dot equalizer) and expanded (bar equalizer) modes.
struct RecordingOverlayView: View {
    @ObservedObject var audioMonitor = AudioLevelMonitor.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var elapsedTime: TimeInterval = 0
    @State private var startTime: Date?
    @State private var timer: Timer?

    var body: some View {
        Group {
            switch settings.recordingOverlayStyle {
            case "classic":
                ExpandedRecordingOverlay(
                    audioMonitor: audioMonitor,
                    elapsedTime: elapsedTime,
                    isRecording: settings.isRecording,
                    onStop: stopRecording,
                    onToggleMode: toggleMode
                )
            case "none":
                EmptyView()
            default: // "mini" or any other value
                CompactRecordingOverlay(
                    audioMonitor: audioMonitor,
                    elapsedTime: elapsedTime,
                    isRecording: settings.isRecording,
                    onStop: stopRecording,
                    onToggleMode: toggleMode
                )
            }
        }
        .onAppear {
            let start = Date()
            startTime = start
            elapsedTime = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsedTime = Date().timeIntervalSince(start)
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: settings.recordingOverlayStyle) { _, _ in
            RecordingOverlayWindowController.shared.resizeForCurrentMode()
        }
    }

    private func stopRecording() {
        MenuBarManager.shared.stopRecordingOnly()
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            settings.recordingOverlayStyle = settings.recordingOverlayStyle == "mini" ? "classic" : "mini"
        }
        RecordingOverlayWindowController.shared.resizeForCurrentMode()
    }
}

// MARK: - Compact Mode

/// Tight, Superwhisper-style pill: red dot, dot equalizer, "Recording", timer, stop button
struct CompactRecordingOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void
    let onToggleMode: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing red recording dot
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isRecording ? 1.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isRecording
                    )
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 20)

            // Dot equalizer
            DotEqualizerView(audioMonitor: audioMonitor)

            // Timer
            Text(formatTimeCompact(elapsedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            // Stop button
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
        .onTapGesture(count: 2) {
            onToggleMode()
        }
    }

    private func formatTimeCompact(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let tenths = Int((time * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Expanded Mode

/// Larger overlay with tall bar equalizer and more visual presence
struct ExpandedRecordingOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void
    let onToggleMode: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Top row: chevron to collapse
            HStack {
                Spacer()
                Button(action: onToggleMode) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            HStack(spacing: 16) {
                // Pulsing red recording dot
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 22, height: 22)
                        .scaleEffect(isRecording ? 1.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isRecording
                        )
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                }

                // Bar equalizer
                EqualizerView(audioMonitor: audioMonitor)
                    .frame(width: 60)

                // Recording label + timer
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(formatTimeExpanded(elapsedTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Stop button
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.8))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .onTapGesture(count: 2) {
            onToggleMode()
        }
    }

    private func formatTimeExpanded(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let tenths = Int((time * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Visual Effect

/// NSVisualEffectView wrapper for the frosted glass background
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
