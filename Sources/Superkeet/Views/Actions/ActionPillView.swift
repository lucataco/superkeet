import SwiftUI

/// The compact Actions HUD: a dark pill under the notch with a voice glyph, one line of text,
/// a stop button and a "…" button that opens the full card.
struct ActionPillView: View {
    static let size = CGSize(width: 430, height: 36)

    let content: ActionPillContent
    /// Live microphone levels when something is already metering the mic; `nil` animates the bars
    /// from speech instead.
    var levels: [Float]?
    var stopHelp = "Stop"
    /// `nil` hides the stop square when there is nothing to stop.
    var onStop: (() -> Void)?
    var onMore: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            glyph
                .frame(width: 18, height: 18)
            line
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onMore)
            HStack(spacing: 2) {
                if let onStop {
                    PillIconButton(systemName: "stop.fill", size: 9, help: stopHelp, action: onStop)
                }
                PillIconButton(systemName: "ellipsis", size: 12, help: "Show details", action: onMore)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.13).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    @ViewBuilder
    private var glyph: some View {
        switch content.glyph {
        case .bars(let active):
            PillVoiceBars(active: active, levels: levels)
        case .spinner:
            PillSpinner()
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var line: some View {
        HStack(spacing: 8) {
            if content.isTicker {
                PillTicker(text: content.text)
            } else {
                Text(content.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(textColor)
            }
            if let check = content.checkBeside {
                Label(check, systemImage: "checkmark")
                    .labelStyle(PillCheckLabelStyle())
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private var textColor: Color {
        switch content.tone {
        case .placeholder: return Color.white.opacity(0.45)
        case .normal: return .white
        case .warning: return .orange
        }
    }
}

/// One line of live words, pinned to its end: new words come in on the right and older ones slide
/// out past a fade on the left.
struct PillTicker: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            words
            // Too long for the pill: pin the end and let the start slide out past a fade. The words
            // sit in an overlay so their full width never widens the pill.
            Color.clear
                .frame(height: 20)
                .overlay(alignment: .trailing) { words }
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: text)
        .accessibilityLabel(text)
    }

    private var words: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white)
    }
}

private struct PillCheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
            configuration.title
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }
}

private struct PillIconButton: View {
    let systemName: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Five bars that move with the voice. Real mic levels drive them when available; otherwise they
/// sway while words are coming in. Still under Reduce Motion.
struct PillVoiceBars: View {
    let active: Bool
    var levels: [Float]?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let restingHeights: [CGFloat] = [0.35, 0.55, 0.75, 0.55, 0.35]
    private static let maxHeight: CGFloat = 14

    var body: some View {
        if active, !reduceMotion, levels == nil {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                bars(heights: Self.swayHeights(at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            bars(heights: heights)
        }
    }

    private var heights: [CGFloat] {
        guard active, !reduceMotion, let levels, !levels.isEmpty else { return Self.restingHeights }
        return Self.restingHeights.indices.map { index in
            let level = EqualizerPalette.boostedLevel(CGFloat(levels[min(index + 1, levels.count - 1)]))
            return max(0.25, level)
        }
    }

    static func swayHeights(at time: TimeInterval) -> [CGFloat] {
        restingHeights.indices.map { index in
            let wave = sin(time * 9 + Double(index) * 1.3) * 0.5 + 0.5
            return 0.3 + 0.7 * CGFloat(wave)
        }
    }

    private func bars(heights: [CGFloat]) -> some View {
        HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(active ? 0.95 : 0.6))
                    .frame(width: 2.5, height: max(3, heights[index] * Self.maxHeight))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: heights)
        .accessibilityHidden(true)
    }
}

/// A small arc spinner, drawn rather than an AppKit progress control so it matches the bars.
struct PillSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
            .frame(width: 13, height: 13)
        }
        .accessibilityLabel("Working")
    }
}
