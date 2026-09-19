import XCTest
@testable import Superkeet

final class AppResolverTests: XCTestCase {
    private let system = URL(fileURLWithPath: "/fixture/Applications")
    private let personal = URL(fileURLWithPath: "/fixture/User/Applications")

    func testNormalizesCaseSpeechSuffixesAndPunctuation() {
        for (name, expected) in [
            ("  HELIUM browser. ", "helium"), ("Discord app!", "discord"),
            ("Google Chrome.app", "google chrome"), ("‘Visual Studio Code’", "visual studio code"),
            ("The Helium browser app", "helium"), ("A.B Test", "a.b test")
        ] {
            XCTAssertEqual(AppResolver.normalizedName(name), expected)
        }
    }

    func testResolvesExactCaseInsensitiveNamesInInjectedDirectories() {
        let helium = system.appendingPathComponent("Helium.app")
        let discord = personal.appendingPathComponent("Discord.app")
        let inventory = [system: [helium], personal: [discord]]
        let resolver = AppResolver(directories: [system, personal], applicationsInDirectory: { inventory[$0] ?? [] })
        XCTAssertEqual(resolver.resolve("helium browser."), helium)
        XCTAssertEqual(resolver.resolve("DISCORD app"), discord)
        XCTAssertNil(resolver.resolve("Heli"), "A partial name must not select an unrelated installed app.")
        XCTAssertNil(resolver.resolve("Missing"))
        XCTAssertNil(resolver.resolve("   "))
    }

    func testAliasesUseRegisteredBundleBeforeScanning() {
        let registered = URL(fileURLWithPath: "/fixture/Registered/Google Chrome.app")
        let scanned = system.appendingPathComponent("Google Chrome.app")
        let resolver = AppResolver(directories: [system], applicationsInDirectory: { _ in [scanned] })
        var identifiers: [String] = []
        let resolved = resolver.resolve("chrome browser") { id in
            identifiers.append(id)
            return registered
        }
        XCTAssertEqual(resolved, registered)
        XCTAssertEqual(identifiers, ["com.google.Chrome"])
        XCTAssertEqual(resolver.resolve("chrome"), scanned, "Aliases must also work when Launch Services has no registration.")
    }

    func testAliasTableAndExplicitBundleIDs() {
        let code = system.appendingPathComponent("Visual Studio Code.app")
        let edge = system.appendingPathComponent("Microsoft Edge.app")
        let resolver = AppResolver(directories: [system], applicationsInDirectory: { _ in [code, edge] })
        XCTAssertEqual(resolver.resolve("VS Code"), code)
        XCTAssertEqual(resolver.resolve("vscode"), code)
        XCTAssertEqual(resolver.resolve("Edge browser"), edge)
        XCTAssertEqual(resolver.resolve("com.example.Editor", bundleLookup: { $0 == "com.example.Editor" ? code : nil }), code)
    }

    func testDirectoryPriorityAndAppExtension() {
        let first = system.appendingPathComponent("Notes.app")
        let second = personal.appendingPathComponent("Notes.app")
        let inventory = [system: [system.appendingPathComponent("Notes.txt"), first], personal: [second]]
        let resolver = AppResolver(directories: [personal, system], applicationsInDirectory: { inventory[$0] ?? [] })
        XCTAssertEqual(resolver.resolve("Notes"), second)
    }

    func testInstalledApplicationNamesAreUniqueSortedAndSkipNonApps() {
        let inventory = [
            system: [system.appendingPathComponent("Notes.app"), system.appendingPathComponent("Readme.txt"),
                     system.appendingPathComponent("Utilities/Terminal.app")],
            personal: [personal.appendingPathComponent("notes.app"), personal.appendingPathComponent("Discord.app")]
        ]
        let resolver = AppResolver(directories: [personal, system], applicationsInDirectory: { inventory[$0] ?? [] })
        XCTAssertEqual(resolver.installedApplicationNames(), ["Discord", "notes", "Terminal"],
                       "Names are case-insensitively unique, keep the first spelling seen, and sort case-insensitively.")
    }

    func testMemoizedResolverScansEachDirectoryOnce() {
        let scans = OSAllocatedUnfairLockBox<[URL]>([])
        let system = self.system
        let notes = system.appendingPathComponent("Notes.app")
        let base = AppResolver(directories: [personal, system], applicationsInDirectory: { directory in
            scans.mutate { $0.append(directory) }
            return directory == system ? [notes] : []
        })
        let resolver = base.memoized()
        XCTAssertEqual(resolver.resolve("Notes"), notes)
        XCTAssertEqual(resolver.resolve("the notes app"), notes)
        XCTAssertNil(resolver.resolve("Missing"))
        XCTAssertEqual(resolver.installedApplicationNames(), ["Notes"])
        XCTAssertEqual(Set(scans.value), [personal, system])
        XCTAssertEqual(scans.value.count, 2, "Every later lookup is answered from memory.")

        XCTAssertEqual(base.resolve("Notes"), notes)
        XCTAssertEqual(scans.value.count, 4, "The original resolver still scans on each call.")
    }

    func testScansNestedUtilitiesInIsolatedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Utilities/Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let resolver = AppResolver(directories: [root])
        XCTAssertEqual(resolver.resolve("fixture app")?.resolvingSymlinksInPath(), app.resolvingSymlinksInPath())
        XCTAssertNil(resolver.resolve("Missing"))
    }
}
