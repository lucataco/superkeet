import XCTest
@testable import Superkeet

final class RecoverableStoreFileTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
    }

    func testUnreadableFileIsBackedUpBeforeTheFirstWrite() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("garbage".utf8).write(to: url)
        let file = RecoverableStoreFile(url: url)
        file.needsRecoveryBackup = true

        let backup = try XCTUnwrap(file.write(Data("{}".utf8)))
        XCTAssertEqual(try Data(contentsOf: backup), Data("garbage".utf8))
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
        XCTAssertFalse(file.needsRecoveryBackup)
    }

    func testDeletingTheUnreadableFileLetsSavesContinue() throws {
        let url = directory.appendingPathComponent("store.json")
        try Data("garbage".utf8).write(to: url)
        let file = RecoverableStoreFile(url: url)
        file.needsRecoveryBackup = true
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(try file.write(Data("{}".utf8)), "Nothing is left to preserve, so there is no backup.")
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
        XCTAssertEqual(try backups(), [])
        XCTAssertFalse(file.needsRecoveryBackup)
    }
}
