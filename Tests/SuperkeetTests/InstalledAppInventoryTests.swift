import XCTest
@testable import Superkeet

@MainActor
final class InstalledAppInventoryTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")

    /// Counts scans and optionally holds each one until released, so the test
    /// can observe the not-yet-ready state deterministically.
    private final class ScanGate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let semaphore = DispatchSemaphore(value: 0)
        var blocking = false

        var scans: Int { lock.withLock { count } }

        func scanned() {
            lock.withLock { count += 1 }
            if blocking { semaphore.wait() }
        }

        func release() { semaphore.signal() }
    }

    private func makeInventory(
        apps: [String] = ["Notes", "Discord"], gate: ScanGate = ScanGate(), running: [URL] = []
    ) -> InstalledAppInventory {
        let directory = self.directory
        let urls = apps.map { directory.appendingPathComponent("\($0).app") }
        return InstalledAppInventory(
            makeResolver: {
                AppResolver(directories: [directory], applicationsInDirectory: { _ in
                    gate.scanned()
                    return urls
                })
            },
            bundleLookup: { _ in nil },
            runningBundleURLs: { running }
        )
    }

    func testLookupsReturnNothingUntilTheBackgroundScanFinishes() async {
        let gate = ScanGate()
        gate.blocking = true
        let inventory = makeInventory(gate: gate)
        XCTAssertFalse(inventory.isReady)
        XCTAssertNil(inventory.resolve("Notes"))
        XCTAssertTrue(inventory.installedNames().isEmpty)

        inventory.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(inventory.isReady, "The scan is still blocked; the main actor was never held up.")
        XCTAssertNil(inventory.resolve("Notes"))

        gate.release()
        let ready = await inventory.waitUntilReady(timeout: .seconds(5))
        XCTAssertTrue(ready)
        XCTAssertEqual(inventory.resolve("the notes app")?.lastPathComponent, "Notes.app")
        XCTAssertEqual(inventory.installedNames(), ["Discord", "Notes"])
        XCTAssertEqual(gate.scans, 1, "The memoized resolver scanned the directory once.")
    }

    func testRefreshIsSkippedWhileFreshOrInFlightAndForcedWhenAsked() async {
        let gate = ScanGate()
        let inventory = makeInventory(gate: gate)
        inventory.refresh()
        inventory.refresh()
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        XCTAssertEqual(gate.scans, 1, "A refresh requested during a scan does not start another.")

        inventory.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.scans, 1, "A fresh inventory is not rescanned.")

        inventory.refresh(force: true)
        for _ in 0..<100 where gate.scans < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(gate.scans, 2)
    }

    func testStaleInventoryIsRescannedButKeptUntilReplaced() async {
        let gate = ScanGate()
        let inventory = makeInventory(gate: gate)
        inventory.maximumAge = 0
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        XCTAssertEqual(gate.scans, 1)

        gate.blocking = true
        inventory.refresh()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(inventory.isReady, "The previous inventory answers while the rescan runs.")
        XCTAssertNotNil(inventory.resolve("Notes"))
        gate.release()
        for _ in 0..<100 where gate.scans < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(gate.scans, 2)
    }

    func testWaitUntilReadyTimesOutWhileBlocked() async {
        let gate = ScanGate()
        gate.blocking = true
        let inventory = makeInventory(gate: gate)
        let ready = await inventory.waitUntilReady(timeout: .milliseconds(100))
        XCTAssertFalse(ready)
        gate.release()
    }

    func testRunningCheckComparesBundlePaths() async {
        let notes = directory.appendingPathComponent("Notes.app")
        let inventory = makeInventory(running: [URL(fileURLWithPath: "/fixture/Applications/./Notes.app")])
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        XCTAssertTrue(inventory.isRunning(notes))
        XCTAssertFalse(inventory.isRunning(directory.appendingPathComponent("Discord.app")))
    }

    func testDetectorEnvironmentDelegatesToTheInventory() async {
        let notes = directory.appendingPathComponent("Notes.app")
        let inventory = makeInventory(running: [notes])
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        let environment = inventory.detectorEnvironment
        XCTAssertEqual(environment.resolveApp("notes"), notes)
        XCTAssertEqual(environment.installedNames(), ["Discord", "Notes"])
        XCTAssertTrue(environment.isRunning(notes))
        XCTAssertFalse(environment.isRunning(directory.appendingPathComponent("Discord.app")))
    }
}
