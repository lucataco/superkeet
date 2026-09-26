import XCTest
@testable import Superkeet

final class AppNearMatchTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")

    private func resolver(_ names: [String]) -> AppResolver {
        let apps = names.map { directory.appendingPathComponent("\($0).app") }
        return AppResolver(directories: [directory], applicationsInDirectory: { _ in apps })
    }

    func testMisheardNamesResolveToTheOneCloseApp() {
        let apps = resolver(["Notes", "Photo Booth", "Safari", "Arc", "Calendar"])
        XCTAssertEqual(apps.uniqueNearMatch("the phone booth")?.lastPathComponent, "Photo Booth.app")
        XCTAssertEqual(apps.uniqueNearMatch("calender")?.lastPathComponent, "Calendar.app")
        XCTAssertNil(apps.uniqueNearMatch("nodes"), "Five letters: too short to guess while speaking.")
    }

    func testShortOrDistantNamesDoNotGuess() {
        let apps = resolver(["Notes", "Arc", "Mail", "Photo Booth"])
        XCTAssertNil(apps.uniqueNearMatch("arch"), "Too short to guess safely.")
        XCTAssertNil(apps.uniqueNearMatch("nail"), "Too short to guess safely.")
        XCTAssertNil(apps.uniqueNearMatch("a new note"))
        XCTAssertNil(apps.uniqueNearMatch("spotify"))
    }

    func testTwoSimilarAppsMeanNoGuess() {
        let apps = resolver(["Calendar", "Calendars"])
        XCTAssertNil(apps.uniqueNearMatch("calender"), "Both are within two edits of each other.")
    }

    @MainActor
    func testTheLiveDetectorUsesTheNearMatch() async {
        let apps = ["Notes", "Photo Booth"].map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { [directory] in AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil }, runningBundleURLs: { apps }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        XCTAssertEqual(inventory.detectorEnvironment.resolveApp("the phone booth")?.lastPathComponent, "Photo Booth.app")
        XCTAssertNil(inventory.resolve("the phone booth"), "The command runner's exact resolve is unchanged.")
    }
}
