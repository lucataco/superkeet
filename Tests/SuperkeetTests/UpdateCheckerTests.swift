import XCTest
@testable import Superkeet

final class UpdateCheckerTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/lucataco/superkeet/releases/tag/\#(tag)","draft":false,"prerelease":\#(prerelease)}"#.utf8)
    }

    func testComparesVersionsNumerically() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.2"))
        XCTAssertTrue(UpdateChecker.isVersion("1.9.1", newerThan: "1.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.9.0", newerThan: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.8.9", newerThan: "1.9.0"))
    }

    func testReportsANewerRelease() async throws {
        let data = release("v1.10.0")
        let result = await UpdateChecker.check(currentVersion: "1.9.0", fetch: { _ in data })
        XCTAssertEqual(result, .available(version: "1.10.0", url: try XCTUnwrap(URL(string: "https://github.com/lucataco/superkeet/releases/tag/v1.10.0"))))
    }

    func testSameOrOlderOrPrereleaseIsUpToDate() async {
        for (tag, pre) in [("v1.9.0", false), ("v1.8.0", false), ("v2.0.0", true)] {
            let data = release(tag, prerelease: pre)
            let result = await UpdateChecker.check(currentVersion: "1.9.0", fetch: { _ in data })
            XCTAssertEqual(result, .upToDate(current: "1.9.0"), tag)
        }
    }

    func testNetworkFailureIsReported() async {
        let result = await UpdateChecker.check(currentVersion: "1.9.0", fetch: { _ in throw URLError(.notConnectedToInternet) })
        guard case .failed(let message) = result else { return XCTFail("Expected failure, got \(result)") }
        XCTAssertTrue(message.hasPrefix("Couldn't check for updates."))
    }
}
