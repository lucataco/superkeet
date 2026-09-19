import AppKit
import Foundation
import os.log

private let inventoryLog = Logger(subsystem: "com.superkeet.app", category: "InstalledAppInventory")

/// Installed-app lookups that never block the main actor. Scanning the
/// application directories takes hundreds of milliseconds, so the scan runs on
/// a background task and callers receive `nil` until it has finished rather
/// than waiting. A completed inventory is kept while a refresh is in flight.
@MainActor
final class InstalledAppInventory: ObservableObject {
    static let shared = InstalledAppInventory()

    /// Inventories older than this are rescanned on the next `refresh()`.
    var maximumAge: TimeInterval = 300

    @Published private(set) var resolver: AppResolver?
    private(set) var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?

    private let makeResolver: @Sendable () -> AppResolver
    private let bundleLookup: @MainActor (String) -> URL?
    private let runningBundleURLs: @MainActor () -> [URL]

    init(
        makeResolver: @escaping @Sendable () -> AppResolver = { AppResolver() },
        bundleLookup: (@MainActor (String) -> URL?)? = nil,
        runningBundleURLs: (@MainActor () -> [URL])? = nil
    ) {
        self.makeResolver = makeResolver
        self.bundleLookup = bundleLookup ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        self.runningBundleURLs = runningBundleURLs ?? { NSWorkspace.shared.runningApplications.compactMap(\.bundleURL) }
    }

    var isReady: Bool { resolver != nil }

    /// Scans in the background unless a fresh inventory exists or a scan is
    /// already running. `force` rescans regardless of age.
    func refresh(force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        if refreshTask != nil { return }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < maximumAge, resolver != nil { return }
        let makeResolver = self.makeResolver
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let started = ContinuousClock.now
            let resolver = makeResolver().memoized()
            let count = resolver.installedApplicationNames().count
            inventoryLog.info("Scanned \(count) installed apps in \(started.duration(to: .now))")
            await self?.finishRefresh(with: resolver)
        }
    }

    private func finishRefresh(with resolver: AppResolver) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.resolver = resolver
        refreshedAt = Date()
        refreshTask = nil
    }

    /// Waits for the inventory to become available, up to the timeout.
    func waitUntilReady(timeout: Duration = .seconds(3)) async -> Bool {
        if isReady { return true }
        refresh()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !isReady, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(25))
        }
        return isReady
    }

    /// Resolves a spoken app reference, or `nil` when unknown or not yet scanned.
    func resolve(_ name: String) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        return resolver?.resolve(name, bundleLookup: bundleLookup)
    }

    func installedNames() -> [String] {
        dispatchPrecondition(condition: .onQueue(.main))
        return resolver?.installedApplicationNames() ?? []
    }

    func isRunning(_ url: URL) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let target = url.standardizedFileURL.path
        return runningBundleURLs().contains { $0.standardizedFileURL.path == target }
    }

    /// Detector environment backed by this inventory. Lookups made before the
    /// first scan completes resolve nothing, so nothing speculative runs.
    var detectorEnvironment: SpeculativeIntentDetector.Environment {
        .init(
            resolveApp: { [weak self] name in MainActor.assumeIsolated { self?.resolve(name) } },
            installedNames: { [weak self] in MainActor.assumeIsolated { self?.installedNames() ?? [] } },
            isRunning: { [weak self] url in MainActor.assumeIsolated { self?.isRunning(url) ?? false } }
        )
    }
}
