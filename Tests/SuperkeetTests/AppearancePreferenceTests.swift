import XCTest
import AppKit
@testable import Superkeet

final class AppearancePreferenceTests: XCTestCase {

    func testRawValuesAreStable() {
        // Raw values are persisted via @AppStorage, so they must not change.
        XCTAssertEqual(AppearancePreference.system.rawValue, "system")
        XCTAssertEqual(AppearancePreference.light.rawValue, "light")
        XCTAssertEqual(AppearancePreference.dark.rawValue, "dark")
    }

    func testAllCasesCoverEveryOption() {
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
    }

    func testLabels() {
        XCTAssertEqual(AppearancePreference.system.label, "System")
        XCTAssertEqual(AppearancePreference.light.label, "Light")
        XCTAssertEqual(AppearancePreference.dark.label, "Dark")
    }

    func testSystemFollowsOSWithNilAppearance() {
        XCTAssertNil(AppearancePreference.system.nsAppearance)
    }

    func testLightMapsToAqua() {
        XCTAssertEqual(AppearancePreference.light.nsAppearance?.name, .aqua)
    }

    func testDarkMapsToDarkAqua() {
        XCTAssertEqual(AppearancePreference.dark.nsAppearance?.name, .darkAqua)
    }

    func testIdentifiableUsesRawValue() {
        for preference in AppearancePreference.allCases {
            XCTAssertEqual(preference.id, preference.rawValue)
        }
    }
}
