import AppKit
import Foundation

@MainActor
protocol NativeActionExecuting: AnyObject, Sendable {
    func execute(_ action: NativeOpenAction) async throws -> String
}

@MainActor
protocol NativeAppLaunching: AnyObject {
    func launch(applicationAt url: URL) async throws -> NativeLaunchedApp
}

@MainActor
protocol NativeWorkspaceOpening {
    func applicationURL(bundleIdentifier: String) -> URL?
    func openApplication(at url: URL) async throws -> NativeLaunchedApp
    func openURL(_ url: URL, in application: URL?) async throws
}

@MainActor
protocol NativeShortcutPressing: AnyObject {
    func press(_ shortcut: KeyboardShortcut, inApplicationAt url: URL) async throws -> Int32
}

@MainActor
final class NativeActionExecutor: NativeActionExecuting, NativeAppLaunching {
    static let shared = NativeActionExecutor()
    nonisolated static let serverID = NativeOpenAction.serverID

    private let resolver: AppResolver
    private let workspace: any NativeWorkspaceOpening
    private let shortcuts: any NativeShortcutPressing

    init(
        resolver: AppResolver = AppResolver(),
        workspace: any NativeWorkspaceOpening = SystemNativeWorkspace(),
        shortcuts: any NativeShortcutPressing = SystemShortcutPresser()
    ) {
        self.resolver = resolver
        self.workspace = workspace
        self.shortcuts = shortcuts
    }

    func execute(_ action: NativeOpenAction) async throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        try action.validate()
        let result: String
        do {
            switch action {
            case .openApp(let name):
                let app = try resolve(name)
                try Task.checkCancellation()
                result = try await launch(applicationAt: app).summary
            case .openURL(let url, let browser):
                let app = try browser.map(resolve)
                try Task.checkCancellation()
                try await workspace.openURL(url, in: app)
                let destination = app.map { " in \($0.deletingPathExtension().lastPathComponent)" } ?? " in the default browser"
                result = "Opened \(url.absoluteString)\(destination)."
            case .pressShortcut(let name, let shortcut):
                let app = try resolve(name)
                try Task.checkCancellation()
                let pid = try await shortcuts.press(shortcut, inApplicationAt: app)
                result = "Pressed \(shortcut.displayName) in \(app.deletingPathExtension().lastPathComponent) (pid \(pid))."
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeOpenActionError {
            throw error
        } catch {
            if ActionErrorHandling.isCancellation(error) { throw CancellationError() }
            throw NativeOpenActionError.openFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        return result
    }

    func launch(applicationAt url: URL) async throws -> NativeLaunchedApp {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        do {
            return try await workspace.openApplication(at: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeOpenActionError {
            throw error
        } catch {
            if ActionErrorHandling.isCancellation(error) { throw CancellationError() }
            throw NativeOpenActionError.openFailed(error.localizedDescription)
        }
    }

    private func resolve(_ name: String) throws -> URL {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let url = resolver.resolve(name, bundleLookup: { workspace.applicationURL(bundleIdentifier: $0) }) else {
            throw NativeOpenActionError.appNotFound(name)
        }
        return url
    }
}

@MainActor
struct SystemNativeWorkspace: NativeWorkspaceOpening {
    private struct LaunchedProcess: Sendable {
        let processIdentifier: Int32
        let bundleIdentifier: String?
        let name: String?
    }

    var launchWaiter = NativeLaunchWaiter()

    func applicationURL(bundleIdentifier: String) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at url: URL) async throws -> NativeLaunchedApp {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        let process: LaunchedProcess = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let app {
                    continuation.resume(returning: LaunchedProcess(
                        processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName
                    ))
                } else {
                    continuation.resume(throwing: NativeOpenActionError.openFailed("No application was returned."))
                }
            }
        }
        let pid = process.processIdentifier
        let running = NSRunningApplication(processIdentifier: pid)
        let windowReady = try await launchWaiter.wait {
            running?.isFinishedLaunching != false && Self.hasOrdinaryWindow(processIdentifier: pid)
        }
        return NativeLaunchedApp(
            name: process.name ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: process.bundleIdentifier,
            processIdentifier: pid,
            windowReady: windowReady
        )
    }

    static func hasOrdinaryWindow(processIdentifier pid: Int32) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
    }

    func openURL(_ url: URL, in application: URL?) async throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        guard let app = application ?? NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw NativeOpenActionError.openFailed("No default application handles this URL.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { running, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if running != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NativeOpenActionError.openFailed("No application accepted the URL."))
                }
            }
        }
    }
}

@MainActor
final class SystemShortcutPresser: NativeShortcutPressing {
    struct Environment {
        var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var runningApplication: (URL) -> NSRunningApplication? = { url in
            let target = url.standardizedFileURL.path
            return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == target && !$0.isTerminated }
        }
        var frontmostProcessIdentifier: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var post: (KeyboardShortcut) -> Bool = { SystemShortcutPresser.post($0) }
        var activationTimeout: Duration = .milliseconds(1_500)
    }

    private let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    func press(_ shortcut: KeyboardShortcut, inApplicationAt url: URL) async throws -> Int32 {
        dispatchPrecondition(condition: .onQueue(.main))
        let name = url.deletingPathExtension().lastPathComponent
        guard environment.accessibilityTrusted() else { throw NativeOpenActionError.accessibilityRequired }
        guard let app = environment.runningApplication(url) else { throw NativeOpenActionError.appNotRunning(name) }
        let pid = app.processIdentifier
        try Task.checkCancellation()
        if environment.frontmostProcessIdentifier() != pid {
            _ = app.activate(options: [])
            let waiter = NativeLaunchWaiter(timeout: environment.activationTimeout, pollInterval: .milliseconds(50))
            guard try await waiter.wait(until: { environment.frontmostProcessIdentifier() == pid }) else {
                throw NativeOpenActionError.openFailed("\(name) did not come to the front, so \(shortcut.displayName) was not sent.")
            }
        }
        try Task.checkCancellation()
        guard environment.post(shortcut) else {
            throw NativeOpenActionError.openFailed("The keyboard event for \(shortcut.displayName) could not be created.")
        }
        return pid
    }

    nonisolated static func post(_ shortcut: KeyboardShortcut) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
