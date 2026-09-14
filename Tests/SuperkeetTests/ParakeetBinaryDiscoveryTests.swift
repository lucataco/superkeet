import XCTest
@testable import Superkeet

final class ParakeetBinaryDiscoveryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFile(_ url: URL, executable: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.standardizedFileURL
    }

    private func select(_ root: URL, _ environment: [String: String] = [:]) throws -> DevelopmentEngineSelection {
        try DevelopmentEngineLocator.select(
            environment: environment,
            homeDirectory: root.appendingPathComponent("home").path,
            currentDirectory: root.appendingPathComponent("work/superkeet").path,
            systemSearchPaths: []
        )
    }

    func testExplicitBinaryWinsOverOtherOverrideAndSource() throws {
        let root = try makeRoot()
        let binary = try makeFile(root.appendingPathComponent("preferred"), executable: true)
        let other = try makeFile(root.appendingPathComponent("other"), executable: true)
        XCTAssertEqual(try select(root, ["PARAKEET_BINARY_PATH": binary.path, "PARAKEET_CLI_PATH": other.path, "PARAKEET_SOURCE_DIR": "/missing"]), .executable(binary))
    }

    func testInvalidExplicitOverrideDoesNotFallBack() throws {
        let root = try makeRoot()
        let fallback = try makeFile(root.appendingPathComponent("bin/parakeet"), executable: true)
        let invalid = try makeFile(root.appendingPathComponent("not-executable"))
        for path in [invalid.path, root.appendingPathComponent("missing").path] {
            XCTAssertThrowsError(try select(root, ["PARAKEET_CLI_PATH": path, "PATH": fallback.deletingLastPathComponent().path]))
        }
        XCTAssertThrowsError(try select(root, ["PARAKEET_BINARY_PATH": invalid.path, "PARAKEET_CLI_PATH": fallback.path]))
    }

    func testExplicitSourceSelectsOneReleaseBuildPathEvenWhenDebugExists() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        _ = try makeFile(source.appendingPathComponent("Cargo.toml"))
        _ = try makeFile(source.appendingPathComponent("target/debug/parakeet"), executable: true)
        let selection = try select(root, ["PARAKEET_SOURCE_DIR": source.path])
        XCTAssertEqual(selection, .source(source, needsClone: false))
        XCTAssertEqual(selection.binaryURL, source.appendingPathComponent("target/release/parakeet"))
    }

    func testSourceArtifactWithoutManifestRemainsUsable() throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let binary = try makeFile(source.appendingPathComponent("target/release/parakeet"), executable: true)
        XCTAssertEqual(try select(root, ["PARAKEET_SOURCE_DIR": source.path]), .executable(binary))
    }

    func testInvalidSourceDoesNotFallBackToPath() throws {
        let root = try makeRoot()
        let binary = try makeFile(root.appendingPathComponent("bin/parakeet"), executable: true)
        XCTAssertThrowsError(try select(root, ["PARAKEET_SOURCE_DIR": "/missing/source", "PATH": binary.deletingLastPathComponent().path]))
    }

    func testVersionedCheckoutAndFormulaSourcePrecedence() throws {
        let root = try makeRoot()
        let cache = root.appendingPathComponent("work/superkeet/.build/parakeet-cli-\(DevelopmentEngineLocator.repositoryRef)", isDirectory: true)
        _ = try makeFile(cache.appendingPathComponent("Cargo.toml"))
        XCTAssertEqual(try select(root), .source(cache, needsClone: false))
        let formula = root.appendingPathComponent("Formulae/parakeet-cli", isDirectory: true)
        _ = try makeFile(formula.appendingPathComponent("Cargo.toml"))
        XCTAssertEqual(try select(root), .source(formula, needsClone: false))
    }

    func testLegacyCheckoutAndSiblingArtifactsAreDiscoverable() throws {
        let root = try makeRoot()
        let sibling = try makeFile(root.appendingPathComponent("work/parakeet-cli/target/release/parakeet"), executable: true)
        XCTAssertEqual(try select(root), .executable(sibling))
        let legacy = try makeFile(root.appendingPathComponent("work/superkeet/.build/parakeet-cli/target/release/parakeet"), executable: true)
        XCTAssertEqual(try select(root), .executable(legacy))
    }

    func testPathBinaryIsUsedWithoutUnnecessaryBootstrap() throws {
        let root = try makeRoot()
        let binary = try makeFile(root.appendingPathComponent("bin/parakeet"), executable: true)
        XCTAssertEqual(try select(root, ["PATH": binary.deletingLastPathComponent().path]), .executable(binary))
    }

    func testTildeAndRelativeOverridesAreNormalized() throws {
        let root = try makeRoot()
        let binary = try makeFile(root.appendingPathComponent("home/bin/parakeet"), executable: true)
        XCTAssertEqual(try select(root, ["PARAKEET_BINARY_PATH": "~/bin/parakeet"]), .executable(binary))
        let relative = try makeFile(root.appendingPathComponent("work/superkeet/custom/parakeet"), executable: true)
        XCTAssertEqual(try select(root, ["PARAKEET_CLI_PATH": "custom/parakeet"]), .executable(relative))
    }

    func testMissingEnginePlansVersionedClone() throws {
        let root = try makeRoot()
        let checkout = root.appendingPathComponent("work/superkeet/.build/parakeet-cli-\(DevelopmentEngineLocator.repositoryRef)", isDirectory: true)
        XCTAssertEqual(try select(root), .source(checkout, needsClone: true))
    }
}
