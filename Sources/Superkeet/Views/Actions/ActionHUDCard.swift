import SwiftUI

struct ActionHUDHeader: Equatable {
    enum Icon: Equatable {
        case idle
        case listening
        case working
        case done
        case failed
        case approval
        case plan
    }

    var icon: Icon
    var title: String
    var subtitle: String?
    var button: String?
    var buttonHelp: String?
}

struct ActionHUDCard<Content: View>: View {
    let header: ActionHUDHeader
    let footer: String?
    let onButton: () -> Void
    let content: Content

    init(header: ActionHUDHeader, footer: String? = nil, onButton: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.onButton = onButton
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            content
            if let footer {
                Divider()
                Label(footer, systemImage: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(header.title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let button = header.button {
                Button(button, action: onButton)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(header.buttonHelp ?? "")
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch header.icon {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .listening:
            glyph("waveform", Color.accentColor)
        case .done:
            glyph("checkmark", .secondary)
        case .failed:
            glyph("exclamationmark.triangle.fill", .orange)
        case .approval:
            glyph("hand.raised.fill", .orange)
        case .plan:
            glyph("list.bullet.clipboard.fill", .orange)
        case .idle:
            glyph("wand.and.stars", Color.accentColor)
        }
    }

    private func glyph<Style: ShapeStyle>(_ name: String, _ style: Style) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(style)
    }
}

struct ActionHUDBody: View {
    struct Transcript: Equatable {
        var text: String
        var isRecording: Bool
        var placeholder: String
    }

    enum Note: Equatable {
        case progress(String)
        case result(String)
        case problem(String)
    }

    static let visibleLines = 6

    var transcript: Transcript?
    var note: Note?
    var lines: [ActionLine] = []
    var queued: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let transcript {
                LiveTranscriptText(transcript: transcript.text, isRecording: transcript.isRecording, placeholder: transcript.placeholder)
            }
            if let note, !note.isProgress {
                noteText(note)
            }
            linesList
            if let note, note.isProgress {
                noteText(note)
            }
            ForEach(Array(queued.enumerated()), id: \.offset) { _, command in
                Text("Next: “\(command)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var linesList: some View {
        let visible = lines.folded(limit: Self.visibleLines)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if visible.hidden > 0 {
                    Text("… \(visible.hidden) earlier")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(visible.lines.enumerated()), id: \.offset) { _, line in
                    ActionLineRow(line: line)
                }
            }
        }
    }

    @ViewBuilder
    private func noteText(_ note: Note) -> some View {
        switch note {
        case .progress(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        case .result(let text):
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        case .problem(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension ActionHUDBody.Note {
    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }
}

struct ActionLineRow: View {
    let line: ActionLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = line.reason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch line.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            glyph("checkmark", .secondary)
        case .failed:
            glyph("exclamationmark", .orange)
        case .denied:
            glyph("hand.raised.fill", .orange)
        }
    }

    private func glyph<Style: ShapeStyle>(_ name: String, _ style: Style) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style)
    }
}

struct LiveTranscriptText: View {
    let transcript: String
    let isRecording: Bool
    var placeholder = "Say a command…"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorVisible = true

    private var displayedText: String { transcript.isEmpty ? placeholder : transcript }

    var body: some View {
        (Text(displayedText) + Text(isRecording ? "▍" : "").foregroundColor(cursorVisible ? .primary : .clear))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(displayedText)
            .task(id: isRecording && !reduceMotion) {
                cursorVisible = true
                guard isRecording, !reduceMotion else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        cursorVisible.toggle()
                    }
                } catch is CancellationError {
                } catch { }
            }
    }
}
