import SwiftUI

/// Recording overlay; style is chosen by `AppSettings.overlayAnimationStyle`.
struct RecordingOverlayView: View {
    let sessionStart: Date
    @ObservedObject var audioMonitor = AudioLevelMonitor.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: sessionStart, by: 1.0)) { context in
            let elapsedTime = OverlayElapsedClock.elapsed(
                now: context.date,
                start: sessionStart,
                isRecording: settings.isRecording
            )
            Group {
                switch settings.overlayAnimationStyle {
                case .classic:
                    ExpandedRecordingOverlay(
                        audioMonitor: audioMonitor,
                        elapsedTime: elapsedTime,
                        isRecording: settings.isRecording,
                        onStop: stopRecording,
                        onToggleMode: toggleMode
                    )
                case .none:
                    EmptyView()
                case .cursorWaveform:
                    CursorWaveformOverlay(
                        audioMonitor: audioMonitor,
                        elapsedTime: elapsedTime,
                        isRecording: settings.isRecording,
                        onStop: stopRecording
                    )
                case .gradientIsland:
                    GradientIslandOverlay(
                        audioMonitor: audioMonitor,
                        elapsedTime: elapsedTime,
                        isRecording: settings.isRecording
                    )
                case .notchShelf:
                    NotchShelfOverlay(
                        audioMonitor: audioMonitor,
                        elapsedTime: elapsedTime
                    )
                case .mini:
                    CompactRecordingOverlay(
                        audioMonitor: audioMonitor,
                        elapsedTime: elapsedTime,
                        isRecording: settings.isRecording,
                        onStop: stopRecording,
                        onToggleMode: toggleMode
                    )
                }
            }
            .onChange(of: settings.recordingOverlayStyle) { _, _ in
                RecordingOverlayWindowController.shared.resizeForCurrentMode()
            }
        }
    }

    private func stopRecording() {
        MenuBarManager.shared.stopRecordingOnly()
    }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let next: OverlayAnimationStyle = settings.overlayAnimationStyle == .mini ? .classic : .mini
            settings.recordingOverlayStyle = next.rawValue
        }
        RecordingOverlayWindowController.shared.resizeForCurrentMode()
    }
}

// MARK: - Compact Mode

/// Tight pill: red dot, dot equalizer, timer, stop button
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
            Text(OverlayElapsedClock.formatted(elapsedTime))
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
                    Text(OverlayElapsedClock.formatted(elapsedTime))
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
