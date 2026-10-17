import Foundation

enum IdleEnginePolicy {
    static let defaultTimeoutMinutes = 15
    static let timeoutDefaultsKey = "idleTimeoutMinutes"
    static let migratedToDefaultKey = "idleTimeoutMigratedToDefault15"

    static func timeoutAfterUpgrade(storedMinutes: Int?, alreadyMigrated: Bool) -> Int? {
        if alreadyMigrated { return nil }
        if let storedMinutes, storedMinutes > 0 { return nil }
        return defaultTimeoutMinutes
    }

    static func applyUpgrade(defaults: UserDefaults) {
        let stored = defaults.object(forKey: timeoutDefaultsKey) as? Int
        let alreadyMigrated = defaults.bool(forKey: migratedToDefaultKey)
        if let next = timeoutAfterUpgrade(storedMinutes: stored, alreadyMigrated: alreadyMigrated) {
            defaults.set(next, forKey: timeoutDefaultsKey)
        }
        defaults.set(true, forKey: migratedToDefaultKey)
    }
}
