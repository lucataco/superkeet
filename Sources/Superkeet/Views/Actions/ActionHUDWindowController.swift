import AppKit
import Combine
import SwiftUI

@MainActor
final class ActionHUDWindowController {
    static let shared = ActionHUDWindowController()

    struct Visibility: Equatable {
        enum AutoHideAction: Equatable {
            case hide
            case dismissOutcome
        }

        var hasPendingApproval = false
        var hasPendingPlan = false
        var phase = AgentSessionController.Phase.idle
        var hasSpeculativeActivity = false
        var isListening = false
        var hasQueuedCommands = false

        var isShown: Bool { hasPendingApproval || hasPendingPlan || phase.showsHUD || hasSpeculativeActivity || isListening }

        var wantsKeyboard: Bool { hasPendingApproval || hasPendingPlan }

        var autoHideAction: AutoHideAction? {
            guard case .finished = phase, !wantsKeyboard else { return nil }
            return isListening ? .dismissOutcome : .hide
        }

        var autoHides: Bool { autoHideAction == .hide }

        var autoHideDelay: TimeInterval { isListening || hasQueuedCommands ? 2 : 8 }
    }

    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var autoHideWorkItem: DispatchWorkItem?
    private var started = false
    private var visibility = Visibility()

    func start() {
        guard !started else { return }
        started = true

        Publishers.CombineLatest4(
            ActionApprovalController.shared.$pending,
            ActionApprovalController.shared.$pendingPlan,
            AgentSessionController.shared.$phase,
            Publishers.CombineLatest4(
                SpeculativeLaunchCoordinator.shared.$activity,
                SpeculativeLaunchCoordinator.shared.$listening,
                AgentSessionController.shared.$queuedCommands,
                ListeningSessionController.shared.$isActive
            )
        )
        .map { pending, plan, phase, live in
            Visibility(
                hasPendingApproval: pending != nil,
                hasPendingPlan: plan != nil,
                phase: phase,
                hasSpeculativeActivity: live.0 != nil,
                // The pill stays up for the whole listening session, including the gap between
                // one utterance's transcript and the next take opening.
                isListening: live.1 != nil || live.3,
                hasQueuedCommands: !live.2.isEmpty
            )
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.update($0) }
        .store(in: &cancellables)

        Publishers.CombineLatest4(
            AgentSessionController.shared.$checklist,
            AgentSessionController.shared.$queuedCommands,
            SpeculativeLaunchCoordinator.shared.$listening,
            AppSettings.shared.$isRecording
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.resizeIfShown() }
        .store(in: &cancellables)
    }

    private func update(_ visibility: Visibility) {
        let previous = self.visibility
        self.visibility = visibility
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        guard visibility.isShown else {
            hide()
            return
        }

        show(takingKeyboard: visibility.wantsKeyboard, releasingKeyboard: previous.wantsKeyboard && !visibility.wantsKeyboard)
        if visibility.autoHideAction != nil {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        let expectedPhase = visibility.phase
        let item = DispatchWorkItem { [weak self] in
            guard let self, AgentSessionController.shared.phase == expectedPhase else { return }
            var current = self.visibility
            current.hasPendingApproval = ActionApprovalController.shared.pending != nil
            current.hasPendingPlan = ActionApprovalController.shared.pendingPlan != nil
            current.isListening = SpeculativeLaunchCoordinator.shared.listening != nil || ListeningSessionController.shared.isActive
            switch current.autoHideAction {
            case .hide:
                self.hide()
            case .dismissOutcome:
                AgentSessionController.shared.reset()
            case nil:
                break
            }
        }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + visibility.autoHideDelay, execute: item)
    }

    private func show(takingKeyboard: Bool, releasingKeyboard: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize(panel)
        position(panel)
        if releasingKeyboard, panel.isKeyWindow {
            panel.orderOut(nil)
        }
        if takingKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func resizeIfShown() {
        guard let panel, panel.isVisible else { return }
        resize(panel)
        position(panel)
    }

    private func resize(_ panel: NSPanel) {
        if let hosting = panel.contentView as? NSHostingView<ActionHUDView> {
            hosting.layoutSubtreeIfNeeded()
            panel.setContentSize(hosting.fittingSize)
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: ActionHUDView())
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let settings = AppSettings.shared
        let clearance = Self.recordingOverlayClearance(
            isRecording: settings.isRecording, style: settings.overlayAnimationStyle
        )
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 12 - clearance
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    static func recordingOverlayClearance(isRecording: Bool, style: OverlayAnimationStyle) -> CGFloat {
        isRecording && style.anchorsToTop ? 72 : 0
    }
}
