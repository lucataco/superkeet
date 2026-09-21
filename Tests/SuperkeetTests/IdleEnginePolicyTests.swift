import XCTest
@testable import Superkeet

final class IdleEnginePolicyTests: XCTestCase {
    func testOldNeverDefaultBecomesFifteenMinutes() {
        XCTAssertEqual(IdleEnginePolicy.timeoutAfterUpgrade(storedMinutes: 0, alreadyMigrated: false), 15)
        XCTAssertEqual(IdleEnginePolicy.timeoutAfterUpgrade(storedMinutes: nil, alreadyMigrated: false), 15)
    }

    func testChosenPositiveTimeoutStays() {
        XCTAssertNil(IdleEnginePolicy.timeoutAfterUpgrade(storedMinutes: 30, alreadyMigrated: false))
        XCTAssertNil(IdleEnginePolicy.timeoutAfterUpgrade(storedMinutes: 5, alreadyMigrated: false))
    }

    func testNeverAfterUpgradeStaysNever() {
        XCTAssertNil(IdleEnginePolicy.timeoutAfterUpgrade(storedMinutes: 0, alreadyMigrated: true))
    }

    func testApplyUpgradeWritesOnce() {
        let defaults = UserDefaults(suiteName: "IdleEnginePolicyTests.\(UUID().uuidString)")
        XCTAssertNotNil(defaults)
        guard let defaults else { return }
        defaults.set(0, forKey: IdleEnginePolicy.timeoutDefaultsKey)

        IdleEnginePolicy.applyUpgrade(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: IdleEnginePolicy.timeoutDefaultsKey), 15)
        XCTAssertTrue(defaults.bool(forKey: IdleEnginePolicy.migratedToDefaultKey))

        defaults.set(0, forKey: IdleEnginePolicy.timeoutDefaultsKey)
        IdleEnginePolicy.applyUpgrade(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: IdleEnginePolicy.timeoutDefaultsKey), 0)
    }
}
