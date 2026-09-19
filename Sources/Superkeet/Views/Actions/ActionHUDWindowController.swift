import AppKit
import Combine
import SwiftUI

@MainActor
final class ActionHUDWindowController {
    static let shared = ActionHUDWindowController()

    /// What the HUD has to show right now, derived from the published state of
    /// the approval controller, the session controller, and the early launcher.
    struct Visibility: Equatable {
        var hasPendingApproval = false
        var hasPendingPlan = false
        var phase = AgentSessionController.Phase.idle
        var hasSpeculativeActivity = false

        var isShown: Bool { hasPendingApproval || hasPendingPlan || phase.showsHUD || hasSpeculativeActivity }

        /// The panel takes keyboard focus only while the user must answer, so
        /// Return/Escape work without stealing keystrokes the rest of the time.
        var wantsKeyboard: Bool { hasPendingApproval || hasPendingPlan }

        var autoHides: Bool {
            if case .finished = phase { return !wantsKeyboard }
            return false
        }
    }

    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var autoHideWorkItem: DispatchWorkItem?
    private var started = false
    private var visibility = Visibility()

    private let autoHideDelay: TimeInterval = 8

    func start() {
        guard !started else { return }
        started = true

        Publishers.CombineLatest4(
            ActionApprovalController.shared.$pending,
            ActionApprovalController.shared.$pendingPlan,
            AgentSessionController.shared.$phase,
            SpeculativeLaunchCoordinator.shared.$activity
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] pending, plan, phase, activity in
            self?.update(Visibility(
                hasPendingApproval: pending != nil,
                hasPendingPlan: plan != nil,
                phase: phase,
                hasSpeculativeActivity: activity != nil
            ))
        }
        .store(in: &cancellables)

        // The checklist grows while a command runs; keep the panel sized to it.
        AgentSessionController.shared.$checklist
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
        if visibility.autoHides {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: item)
    }

    private func show(takingKeyboard: Bool, releasingKeyboard: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize(panel)
        position(panel)
        if releasingKeyboard, panel.isKeyWindow {
            // Hand keystrokes back to the app the user was working in. The
            // panel is non-activating, so reordering it is enough.
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

    /// Extra vertical space so the HUD does not sit on top of a recording
    /// overlay drawn along the top edge while the user is still speaking.
    static func recordingOverlayClearance(isRecording: Bool, style: OverlayAnimationStyle) -> CGFloat {
        isRecording && style.anchorsToTop ? 72 : 0
    }
}
