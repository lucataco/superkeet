import XCTest
@testable import Superkeet

final class AppVersionTests: XCTestCase {
    func testBundleVersionWinsAndBuildDoesNotLeakFromDevelopmentResource() {
        let version = AppVersion.resolve(
            bundleInfo: ["CFBundleShortVersionString": "2.0"],
            developmentInfo: ["CFBundleShortVersionString": "3.0", "CFBundleVersion": "30"]
        )
        XCTAssertEqual(version.displayString, "2.0")
    }

    func testDisplayStringShowsBuildOnlyWhenItDiffersFromVersion() {
        XCTAssertEqual(AppVersion.resolve(bundleInfo: ["CFBundleShortVersionString": "1.9.3", "CFBundleVersion": "1.9.3"]).displayString, "1.9.3")
        XCTAssertEqual(AppVersion.resolve(bundleInfo: ["CFBundleShortVersionString": "1.9.3", "CFBundleVersion": "42"]).displayString, "1.9.3 (42)")
    }

    func testDevelopmentFallbackAndUnknownVersion() {
        XCTAssertEqual(AppVersion.resolve(bundleInfo: [:], developmentInfo: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "21"]).displayString, "2.1 (21)")
        XCTAssertEqual(AppVersion.resolve(bundleInfo: ["CFBundleShortVersionString": ""]).displayString, "1.0")
    }

    func testCurrentVersionUsesRepositoryPlistWhenMainMetadataIsAbsent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(AppVersion.current, AppVersion.resolve(bundleInfo: Bundle.main.infoDictionary ?? [:], developmentInfo: info))
    }
}
