import XCTest
@testable import Superkeet

final class AppVersionTests: XCTestCase {
    func testBundleVersionWinsAndBuildDoesNotLeakFromDevelopmentResource() {
        let version = AppVersion.resolve(
            bundleInfo: ["CFBundleShortVersionString": "2.0"],
            developmentInfo: ["CFBundleShortVersionString": "3.0", "CFBundleVersion": "30"]
        )
        XCTAssertEqual(version.displayString, "2.0 (2.0)")
    }

    func testDevelopmentFallbackAndUnknownVersion() {
        XCTAssertEqual(AppVersion.resolve(bundleInfo: [:], developmentInfo: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "21"]).displayString, "2.1 (21)")
        XCTAssertEqual(AppVersion.resolve(bundleInfo: ["CFBundleShortVersionString": ""]).displayString, "1.0 (1.0)")
    }

    func testCurrentVersionUsesRepositoryPlistWhenMainMetadataIsAbsent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(AppVersion.current, AppVersion.resolve(bundleInfo: Bundle.main.infoDictionary ?? [:], developmentInfo: info))
    }
}
