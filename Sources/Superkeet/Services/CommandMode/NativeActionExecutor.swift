import AppKit
import Foundation

@MainActor
protocol NativeActionExecuting: AnyObject, Sendable {
    func execute(_ action: NativeOpenAction) async throws -> String
}

@MainActor
protocol NativeAppLaunching: AnyObject {
    /// Launches (or brings forward) the app. With `awaitWindow`, waits up to a few seconds for an
    /// ordinary window so callers that act inside the app know there is something to act on.
    func launch(applicationAt url: URL, awaitWindow: Bool) async throws -> NativeLaunchedApp
}

extension NativeAppLaunching {
    func launch(applicationAt url: URL) async throws -> NativeLaunchedApp {
        try await launch(applicationAt: url, awaitWindow: true)
    }
}

@MainActor
protocol NativeWorkspaceOpening {
    func applicationURL(bundleIdentifier: String) -> URL?
    /// Returns as soon as macOS reports the process; `windowReady` reflects that moment only.
    func openApplication(at url: URL) async throws -> NativeLaunchedApp
    /// Polls until the process shows an ordinary window or the wait times out.
    func waitForWindow(processIdentifier: Int32) async throws -> Bool
    func openURL(_ url: URL, in application: URL?) async throws
}

@MainActor
protocol NativeShortcutPressing: AnyObject {
    func press(_ shortcut: KeyboardShortcut, inApplicationAt url: URL) async throws -> Int32
}

@MainActor
protocol NativeTextTyping: AnyObject {
    /// Types the text into the app at its current insertion point; returns the app's pid.
    func type(_ text: String, inApplicationAt url: URL) async throws -> Int32
}

@MainActor
final class NativeActionExecutor: NativeActionExecuting, NativeAppLaunching {
    static let shared = NativeActionExecutor()
    nonisolated static let serverID = NativeOpenAction.serverID

    /// Injected by tests. Otherwise lookups go through the inventory's memoized scan, so a
    /// resolution never re-reads the Applications folders (a fresh scan cost 0.8 s per open).
    private let injectedResolver: AppResolver?
    private let workspace: any NativeWorkspaceOpening
    private let shortcuts: any NativeShortcutPressing
    private let typer: any NativeTextTyping

    init(
        resolver: AppResolver? = nil,
        workspace: any NativeWorkspaceOpening = SystemNativeWorkspace(),
        shortcuts: any NativeShortcutPressing = SystemShortcutPresser(),
        typer: any NativeTextTyping = SystemTextTyper()
    ) {
        self.injectedResolver = resolver
        self.workspace = workspace
        self.shortcuts = shortcuts
        self.typer = typer
    }

    private static let fallbackResolver = AppResolver().memoized()

    private func currentResolver() -> AppResolver {
        if let injectedResolver { return injectedResolver }
        let inventory = InstalledAppInventory.shared
        if let resolver = inventory.resolver { return resolver }
        inventory.refresh()
        return Self.fallbackResolver
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
            case .typeText(let name, let text):
                let app = try resolve(name)
                try Task.checkCancellation()
                let pid = try await typer.type(text, inApplicationAt: app)
                result = "Typed “\(Self.clip(text))” in \(app.deletingPathExtension().lastPathComponent) (pid \(pid))."
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

    func launch(applicationAt url: URL, awaitWindow: Bool) async throws -> NativeLaunchedApp {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        do {
            var launched = try await workspace.openApplication(at: url)
            if awaitWindow, !launched.windowReady {
                launched = launched.withWindowReady(try await workspace.waitForWindow(processIdentifier: launched.processIdentifier))
            }
            return launched
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NativeOpenActionError {
            throw error
        } catch {
            if ActionErrorHandling.isCancellation(error) { throw CancellationError() }
            throw NativeOpenActionError.openFailed(error.localizedDescription)
        }
    }

    /// Waits for a window of an app that was launched without waiting. Never throws; a cancelled
    /// or timed-out wait simply reports the window as not ready.
    func waitForWindow(processIdentifier: Int32) async -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return (try? await workspace.waitForWindow(processIdentifier: processIdentifier)) ?? false
    }

    func resolve(_ name: String) throws -> URL {
        dispatchPrecondition(condition: .onQueue(.main))
        // A whole sentence is never an app name; refuse before touching the disk.
        guard NativeOpenAction.isPlausibleAppName(name) else { throw NativeOpenActionError.appNotFound(name) }
        // The final command may take a sound-alike ("the crown" opens Chrome); only the live-speech
        // path, which resolves through the inventory directly, stays exact.
        guard let url = currentResolver().resolve(name, bundleLookup: { workspace.applicationURL(bundleIdentifier: $0) }, fuzzy: true) else {
            throw NativeOpenActionError.appNotFound(name)
        }
        return url
    }

    nonisolated static func clip(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
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
    /// Brings an already-running app's windows back: unhide, un-minimize, activate. Injectable
    /// because it talks to the Accessibility API of other processes.
    var restoreWindows: @MainActor (NSRunningApplication) -> Void = SystemNativeWorkspace.restoreWindows

    func applicationURL(bundleIdentifier: String) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at url: URL) async throws -> NativeLaunchedApp {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        // "Open Chrome" when Chrome is running but minimized must bring its window back. The reopen
        // event macOS sends to a running app does not un-minimize windows in most apps, so do it
        // ourselves before asking the workspace to open (which also activates the app).
        if let running = Self.runningApplication(at: url) {
            restoreWindows(running)
        }
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
        return NativeLaunchedApp(
            name: process.name ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: process.bundleIdentifier,
            processIdentifier: pid,
            windowReady: Self.isWindowReady(processIdentifier: pid)
        )
    }

    func waitForWindow(processIdentifier pid: Int32) async throws -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return try await launchWaiter.wait { Self.isWindowReady(processIdentifier: pid) }
    }

    static func isWindowReady(processIdentifier pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching != false && hasOrdinaryWindow(processIdentifier: pid)
    }

    nonisolated static func runningApplication(at url: URL) -> NSRunningApplication? {
        let target = url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == target && !$0.isTerminated }
    }

    /// Unhides, un-minimizes (through Accessibility, which Superkeet already holds for its
    /// shortcuts), and activates a running app so "open" always ends with a visible window.
    static func restoreWindows(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for window in windows {
                    var minimized: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                          (minimized as? Bool) == true else { continue }
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }
        }
        app.activate(options: [])
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
        var runningApplication: (URL) -> NSRunningApplication? = { SystemNativeWorkspace.runningApplication(at: $0) }
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

/// Types dictated text with synthetic Unicode key events, the same path automatic paste uses for
/// ⌘V, so it lands in whatever has the insertion point in the target app. Text is sent in short
/// chunks (apps drop long Unicode strings on one event) and each new line becomes a Return press.
@MainActor
final class SystemTextTyper: NativeTextTyping {
    struct Environment {
        var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var runningApplication: (URL) -> NSRunningApplication? = { SystemNativeWorkspace.runningApplication(at: $0) }
        var frontmostProcessIdentifier: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var postText: (String) -> Bool = { SystemTextTyper.post($0) }
        var postReturn: () -> Bool = { KeyboardShortcut(keys: ["return"]).map(SystemShortcutPresser.post) ?? false }
        var activationTimeout: Duration = .milliseconds(1_500)
        /// Pause between chunks so the target app's event queue keeps up.
        var chunkDelay: Duration = .milliseconds(8)
    }

    nonisolated static let chunkLength = 20

    private let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    func type(_ text: String, inApplicationAt url: URL) async throws -> Int32 {
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
                throw NativeOpenActionError.openFailed("\(name) did not come to the front, so nothing was typed.")
            }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 {
                try Task.checkCancellation()
                guard environment.postReturn() else { throw NativeOpenActionError.openFailed("The Return key event could not be created.") }
                try await Task.sleep(for: environment.chunkDelay)
            }
            for chunk in Self.chunks(of: String(line)) {
                try Task.checkCancellation()
                guard environment.postText(chunk) else { throw NativeOpenActionError.openFailed("The keyboard event for the text could not be created.") }
                try await Task.sleep(for: environment.chunkDelay)
            }
        }
        return pid
    }

    nonisolated static func chunks(of line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for character in line {
            if current.utf16.count + String(character).utf16.count > chunkLength, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    nonisolated static func post(_ chunk: String) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
        let units = Array(chunk.utf16)
        units.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
