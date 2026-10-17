import XCTest
@testable import Superkeet

final class AppPathsTests: XCTestCase {
    func testSharedStoresStayOutOfTheUserLibraryDuringTests() {
        XCTAssertTrue(AppPaths.isRunningTests)
        let directory = AppPaths.applicationSupportDirectory.standardizedFileURL.path
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
        XCTAssertFalse(directory.hasPrefix(library), directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory))
    }
}
