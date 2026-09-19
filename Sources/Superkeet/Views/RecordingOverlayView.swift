import SwiftUI

struct RecordingOverlayView: View {
    let sessionStart: Date
    var phase: OverlayPhase = .recording
    @ObservedObject var audioMonitor = AudioLevelMonitor.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var layout = RecordingOverlayWindowController.shared

    var body: some View {
        TimelineView(.periodic(from: sessionStart, by: 1.0)) { context in
            let isRecording = phase.isRecording && settings.isRecording
            let elapsedTime = OverlayElapsedClock.elapsed(
                now: context.date,
                start: sessionStart,
                isRecording: isRecording
            )
            Group {
                if !phase.isRecording {
                    statusView
                } else {
                    switch settings.overlayAnimationStyle {
                    case .classic:
                        ExpandedRecordingOverlay(
                            audioMonitor: audioMonitor,
                            elapsedTime: elapsedTime,
                            isRecording: isRecording,
                            onStop: stopRecording,
                            onToggleMode: toggleMode
                        )
                    case .none:
                        EmptyView()
                    case .cursorWaveform:
                        CursorWaveformOverlay(
                            audioMonitor: audioMonitor,
                            elapsedTime: elapsedTime,
                            isRecording: isRecording,
                            onStop: stopRecording
                        )
                    case .gradientIsland:
                        GradientIslandOverlay(
                            audioMonitor: audioMonitor,
                            elapsedTime: elapsedTime,
                            isRecording: isRecording
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
                            isRecording: isRecording,
                            onStop: stopRecording,
                            onToggleMode: toggleMode
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: phase)
            .onChange(of: settings.recordingOverlayStyle) { _, _ in
                RecordingOverlayWindowController.shared.resizeForCurrentMode()
            }
        }
    }

    /// Shared "Transcribing…" / outcome pill. The Wide Notch style straddles the camera, so its
    /// pill sits to the right of the notch gap like the timer does while recording.
    @ViewBuilder
    private var statusView: some View {
        let gap = layout.notchGapWidth
        if settings.overlayAnimationStyle == .notchShelf, gap > 0 {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer().frame(width: geo.size.width / 2 + gap / 2)
                    OverlayStatusPill(phase: phase)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            OverlayStatusPill(phase: phase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct CompactRecordingOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void
    let onToggleMode: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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

            DotEqualizerView(audioMonitor: audioMonitor)

            Text(OverlayElapsedClock.formatted(elapsedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)

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

struct ExpandedRecordingOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void
    let onToggleMode: () -> Void

    var body: some View {
        VStack(spacing: 10) {
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

                EqualizerView(audioMonitor: audioMonitor)
                    .frame(width: 60)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(OverlayElapsedClock.formatted(elapsedTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }

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

/// Post-recording feedback shown in the same window and chrome as the recording overlay, so the
/// user's eye does not have to move to learn what happened to their text.
struct OverlayStatusPill: View {
    let phase: OverlayPhase

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .recording:
                EmptyView()
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            case .result(let outcome):
                Image(systemName: outcome.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Self.tint(for: outcome.severity))
                    .frame(width: 14, height: 14)
                Text(outcome.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    static func tint(for severity: TranscriptOutcome.Severity) -> Color {
        switch severity {
        case .success: return .green
        case .neutral: return .secondary
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

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
