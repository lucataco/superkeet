import SwiftUI
import AppKit
import Combine

private let pointerTrackingInterval: TimeInterval = 1.0 / 15.0

@MainActor
final class RecordingOverlayWindowController: ObservableObject {
    static let shared = RecordingOverlayWindowController()

    @Published private(set) var notchGapWidth: CGFloat = 0
    @Published private(set) var phase: OverlayPhase = .recording

    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var sessionStart = Date()
    private var stateCancellables: Set<AnyCancellable> = []
    private var resultDismissal: DispatchWorkItem?
    private var pointerTracker: Timer?

    private init() {}

    /// Subscribes to the engine so the overlay stays up through "Transcribing…" and flashes the
    /// outcome ("Copied", "Pasted", …) instead of vanishing the instant recording stops.
    func start(service: ParakeetService = .shared) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard stateCancellables.isEmpty else { return }

        service.$daemonState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleDaemonState(state) }
            .store(in: &stateCancellables)

        service.$lastOutcome
            .compactMap { $0 }
            .removeDuplicates { $0.id == $1.id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.showOutcome(event.outcome) }
            .store(in: &stateCancellables)
    }

    private func handleDaemonState(_ state: ParakeetService.DaemonState) {
        guard window?.isVisible == true else { return }
        switch state {
        case .transcribing:
            if phase == .recording { showTranscribing() }
        case .stopped, .stopping:
            // The engine went away. Let a result flash finish; otherwise there is nothing to show.
            if case .result = phase { return }
            hide()
        case .starting, .idle, .recording:
            break
        }
    }

    private func showTranscribing() {
        guard AppSettings.shared.overlayAnimationStyle.showsOverlay else { return }
        stopPointerTracking()
        cancelResultDismissal()
        setPhase(.transcribing)
    }

    private func showOutcome(_ outcome: TranscriptOutcome) {
        guard window?.isVisible == true else { return }
        guard outcome.showsInOverlay else {
            hide()
            return
        }
        stopPointerTracking()
        cancelResultDismissal()
        setPhase(.result(outcome))

        let dismissal = DispatchWorkItem { [weak self] in
            guard let self, case .result = self.phase else { return }
            self.hide()
        }
        resultDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + outcome.displayDuration, execute: dismissal)
    }

    private func cancelResultDismissal() {
        resultDismissal?.cancel()
        resultDismissal = nil
    }

    private func setPhase(_ newPhase: OverlayPhase) {
        phase = newPhase
        hostingView?.rootView = RecordingOverlayView(sessionStart: sessionStart, phase: newPhase)
    }

    nonisolated static let compactSize = NSSize(width: 260, height: 50)
    nonisolated static let expandedSize = NSSize(width: 310, height: 94)
    nonisolated static let cursorWaveformSize = NSSize(width: 248, height: 44)
    nonisolated static let gradientIslandSize = NSSize(width: 200, height: 40)
    nonisolated static let notchShelfSize = NSSize(width: 560, height: 32)

    nonisolated static func size(for style: OverlayAnimationStyle) -> NSSize {
        switch style {
        case .mini: return compactSize
        case .classic: return expandedSize
        case .cursorWaveform: return cursorWaveformSize
        case .gradientIsland: return gradientIslandSize
        case .notchShelf: return notchShelfSize
        case .none: return .zero
        }
    }

    nonisolated static func windowLevel(for style: OverlayAnimationStyle) -> NSWindow.Level {
        switch style {
        case .gradientIsland, .notchShelf:
            return .statusBar
        case .mini, .classic, .cursorWaveform, .none:
            return .floating
        }
    }

    nonisolated static func ignoresMouseEvents(for style: OverlayAnimationStyle) -> Bool {
        style == .gradientIsland || style == .notchShelf
    }

    func show() {
        dispatchPrecondition(condition: .onQueue(.main))

        let style = AppSettings.shared.overlayAnimationStyle
        guard style.showsOverlay else { return }

        cancelResultDismissal()
        sessionStart = Date()
        phase = .recording

        if let window {
            hostingView?.rootView = RecordingOverlayView(sessionStart: sessionStart, phase: .recording)
            applyChrome(window, style: style)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            stopPointerTracking()
            startPointerTrackingIfNeeded(for: style)
            return
        }

        let overlayView = RecordingOverlayView(sessionStart: sessionStart, phase: .recording)
        let hosting = NSHostingView(rootView: overlayView)
        self.hostingView = hosting

        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        applyChrome(window, style: style)

        window.orderFrontRegardless()
        self.window = window

        startPointerTrackingIfNeeded(for: style)
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopPointerTracking()
        cancelResultDismissal()
        window?.orderOut(nil)
    }

    func resizeForCurrentMode() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window = window else { return }

        let style = AppSettings.shared.overlayAnimationStyle
        if !style.showsOverlay {
            hide()
            return
        }
        stopPointerTracking()
        startPointerTrackingIfNeeded(for: style)
        applyChrome(window, style: style, animate: true)
    }

    private func applyChrome(_ window: NSWindow, style: OverlayAnimationStyle, animate: Bool = false) {
        window.isMovableByWindowBackground = style != .cursorWaveform
        window.level = Self.windowLevel(for: style)
        window.ignoresMouseEvents = Self.ignoresMouseEvents(for: style)
        let layout = layoutForCurrentScreen(style: style)
        notchGapWidth = layout.gapWidth
        hostingView?.frame = NSRect(origin: .zero, size: layout.frame.size)
        window.setFrame(layout.frame, display: true, animate: animate)
    }

    private func layoutForCurrentScreen(style: OverlayAnimationStyle) -> (frame: NSRect, gapWidth: CGFloat) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else {
            return (NSRect(origin: .zero, size: Self.size(for: style)), 0)
        }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let size = Self.size(for: style)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visibleFrame,
            topSafeInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )

        switch style {
        case .mini, .classic, .none:
            return (
                NSRect(origin: OverlayGeometry.bottomCenterOrigin(visibleFrame: visibleFrame, size: size), size: size),
                0
            )
        case .cursorWaveform:
            return (
                NSRect(
                    origin: OverlayGeometry.pointerFollowingOrigin(
                        pointer: pointer,
                        size: size,
                        screenFrame: frame,
                        visibleFrame: visibleFrame
                    ),
                    size: size
                ),
                0
            )
        case .gradientIsland:
            let notchRightEdge = metrics.notchWidth > 0
                ? metrics.notchCenterX + metrics.notchWidth / 2
                : nil
            return (
                NSRect(
                    origin: OverlayGeometry.islandOrigin(
                        size: size,
                        screenFrame: frame,
                        visibleFrame: visibleFrame,
                        notchRightEdge: notchRightEdge
                    ),
                    size: size
                ),
                0
            )
        case .notchShelf:
            return OverlayGeometry.notchShelfLayout(
                size: size,
                screenFrame: frame,
                visibleFrame: visibleFrame,
                metrics: metrics
            )
        }
    }

    nonisolated static func shouldTrackPointer(for style: OverlayAnimationStyle) -> Bool {
        style == .cursorWaveform
    }

    private func startPointerTrackingIfNeeded(for style: OverlayAnimationStyle) {
        guard Self.shouldTrackPointer(for: style) else { return }
        let size = Self.size(for: style)
        pointerTracker = Timer.scheduledTimer(withTimeInterval: pointerTrackingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let window = self.window else { return }
                guard Self.shouldTrackPointer(for: AppSettings.shared.overlayAnimationStyle) else {
                    self.pointerTracker?.invalidate()
                    self.pointerTracker = nil
                    return
                }
                let pointer = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
                guard let screen else { return }
                let origin = OverlayGeometry.pointerFollowingOrigin(
                    pointer: pointer,
                    size: size,
                    screenFrame: screen.frame,
                    visibleFrame: screen.visibleFrame
                )
                if origin != window.frame.origin {
                    window.setFrameOrigin(origin)
                }
            }
        }
    }

    private func stopPointerTracking() {
        pointerTracker?.invalidate()
        pointerTracker = nil
    }
}
