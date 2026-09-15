import AppKit
import Combine
import SwiftUI

@MainActor
final class ActionHUDWindowController {
    static let shared = ActionHUDWindowController()

    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var autoHideWorkItem: DispatchWorkItem?
    private var started = false

    private let autoHideDelay: TimeInterval = 8

    func start() {
        guard !started else { return }
        started = true

        Publishers.CombineLatest(
            ActionApprovalController.shared.$pending,
            AgentSessionController.shared.$phase
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] pending, phase in
            self?.update(hasPending: pending != nil, phase: phase)
        }
        .store(in: &cancellables)
    }

    private func update(hasPending: Bool, phase: AgentSessionController.Phase) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        guard hasPending || phase.showsHUD else {
            hide()
            return
        }

        show()
        if case .finished = phase {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: item)
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let hosting = panel.contentView as? NSHostingView<ActionHUDView> {
            hosting.layoutSubtreeIfNeeded()
            panel.setContentSize(hosting.fittingSize)
        }
        position(panel)
        panel.orderFrontRegardless()
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
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
