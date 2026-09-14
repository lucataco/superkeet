import Foundation

final class RecoverableStoreFile {
    let url: URL
    var needsRecoveryBackup = false
    private var backupURL: URL?

    init(url: URL) { self.url = url }

    func write(_ data: Data) throws -> URL? {
        if needsRecoveryBackup {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "The original store is not a regular file; it was left untouched."])
            }
            let backup = url.appendingPathExtension("unreadable-\(UUID().uuidString).backup")
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            backupURL = backup
            needsRecoveryBackup = false
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return backupURL
    }
}
