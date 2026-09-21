import Foundation

/// How long Superkeet leaves the speech engine parked after it returns to idle.
///
/// The INT8 daemon holds about 1.8 GB RSS while doing nothing. Reloading it until
/// the next `start` is ready takes about 0.8 s on Apple Silicon, so a short idle
/// timeout reclaims RAM without a noticeable first-word penalty. Zero means never.
enum IdleEnginePolicy {
    static let defaultTimeoutMinutes = 15
    static let timeoutDefaultsKey = "idleTimeoutMinutes"
    static let migratedToDefaultKey = "idleTimeoutMigratedToDefault15"

    /// Old builds stored Never (0) as the factory default. One 1.8.0 launch writes 15
    /// unless the user already picked a positive timeout. A later Never stays Never.
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
