import XCTest
@testable import Superkeet

final class ParakeetBinaryDiscoveryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testEnvironmentOverrideWins() throws {
        let root = try makeTemporaryDirectory()
        let binary = try makeExecutable(root.appendingPathComponent("custom/parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: ["PARAKEET_CLI_PATH": binary.path],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: root.appendingPathComponent("repo/superkeet").path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testParakeetSourceDirectoryResolvesReleaseBinary() throws {
        let root = try makeTemporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("parakeet-cli", isDirectory: true)
        let binary = try makeExecutable(sourceDirectory.appendingPathComponent("target/release/parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: ["PARAKEET_SOURCE_DIR": sourceDirectory.path],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: root.appendingPathComponent("repo/superkeet").path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testSiblingParakeetCliResolvedForSwiftRun() throws {
        let root = try makeTemporaryDirectory()
        let superkeetDirectory = root.appendingPathComponent("superkeet", isDirectory: true)
        try fileManager.createDirectory(at: superkeetDirectory, withIntermediateDirectories: true)
        let binary = try makeExecutable(root.appendingPathComponent("parakeet-cli/target/release/parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: [:],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: superkeetDirectory.path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testBootstrappedParakeetCliResolvedForSwiftRun() throws {
        let root = try makeTemporaryDirectory()
        let superkeetDirectory = root.appendingPathComponent("superkeet", isDirectory: true)
        try fileManager.createDirectory(at: superkeetDirectory, withIntermediateDirectories: true)
        let binary = try makeExecutable(superkeetDirectory.appendingPathComponent(".build/parakeet-cli/target/release/parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: [:],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: superkeetDirectory.path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testPathSearchFindsParakeet() throws {
        let root = try makeTemporaryDirectory()
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let binary = try makeExecutable(binDirectory.appendingPathComponent("parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: ["PATH": binDirectory.path],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: root.appendingPathComponent("repo/superkeet").path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testTildeExpansionInOverride() throws {
        let root = try makeTemporaryDirectory()
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let binary = try makeExecutable(homeDirectory.appendingPathComponent("bin/parakeet"))

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: ["PARAKEET_BINARY_PATH": "~/bin/parakeet"],
            homeDirectory: homeDirectory.path,
            currentDirectory: root.appendingPathComponent("repo/superkeet").path,
            systemSearchPaths: []
        )

        XCTAssertEqual(resolved, binary.standardizedFileURL.path)
    }

    func testNonExecutableCandidateIsIgnored() throws {
        let root = try makeTemporaryDirectory()
        let binary = root.appendingPathComponent("custom/parakeet")
        try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o644])

        let resolved = AppSettings.resolveDevelopmentBinaryPath(
            environment: ["PARAKEET_CLI_PATH": binary.path],
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: root.appendingPathComponent("repo/superkeet").path,
            systemSearchPaths: []
        )

        XCTAssertNil(resolved)
    }

    @discardableResult
    private func makeExecutable(_ url: URL) throws -> URL {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("superkeet-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { [fileManager] in
            try? fileManager.removeItem(at: url)
        }
        return url
    }
}
