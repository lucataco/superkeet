import XCTest
@testable import Superkeet

final class MCPLaunchResolutionTests: XCTestCase {
    private let executable: (String) -> Bool = { path in
        ["/usr/local/bin/npx", "/opt/homebrew/bin/node", "/bin/sh"].contains(path)
    }

    func testResolvesCommandFromSearchPath() {
        let resolved = MCPExecutableResolver.resolve(
            command: "npx",
            searchPath: "/usr/bin:/usr/local/bin",
            isExecutable: executable
        )
        XCTAssertEqual(resolved, "/usr/local/bin/npx")
    }

    func testFallsBackToLaterPathEntry() {
        let resolved = MCPExecutableResolver.resolve(
            command: "node",
            searchPath: "/usr/bin:/opt/homebrew/bin",
            isExecutable: executable
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/node")
    }

    func testAbsolutePathIsUsedDirectly() {
        let resolved = MCPExecutableResolver.resolve(
            command: "/bin/sh",
            searchPath: "/usr/bin",
            isExecutable: executable
        )
        XCTAssertEqual(resolved, "/bin/sh")
    }

    func testMissingCommandReturnsNil() {
        XCTAssertNil(
            MCPExecutableResolver.resolve(command: "npx", searchPath: "/usr/bin", isExecutable: executable)
        )
    }

    func testEmptyCommandReturnsNil() {
        XCTAssertNil(
            MCPExecutableResolver.resolve(command: "   ", searchPath: "/usr/bin", isExecutable: executable)
        )
    }

    func testMergedPathDeduplicatesAndAppendsFallback() {
        let merged = LoginShellPath.merged(
            shellOutput: "/custom/bin:/usr/bin",
            fallback: "/usr/bin:/bin"
        )
        XCTAssertEqual(merged, "/custom/bin:/usr/bin:/bin")
    }

    func testMergedPathWithNoShellOutputUsesFallback() {
        XCTAssertEqual(LoginShellPath.merged(shellOutput: nil, fallback: "/bin:/usr/bin"), "/bin:/usr/bin")
    }

    func testExtractPathIgnoresLoginBanner() {
        let output = "Welcome to zsh\nsome notice__SUPERKEET_PATH__/custom/bin:/usr/bin\n"
        XCTAssertEqual(LoginShellPath.extractPath(from: output), "/custom/bin:/usr/bin")
    }

    func testExtractPathWithoutMarkerReturnsNil() {
        XCTAssertNil(LoginShellPath.extractPath(from: "/usr/bin:/bin"))
    }

    func testRunLoginShellExtractsPath() async {
        let output = await LoginShellPath.runLoginShell(
            shell: "/bin/sh",
            timeout: 5,
            command: "printf '\(LoginShellPath.marker)%s' \"/from/shell:/usr/bin\""
        )
        XCTAssertEqual(output, "/from/shell:/usr/bin")
    }

    func testRunLoginShellTimesOutOnHungCommand() async {
        let start = Date()
        let output = await LoginShellPath.runLoginShell(
            shell: "/bin/sh",
            timeout: 0.5,
            command: "sleep 30"
        )
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunLoginShellReturnsNilForMissingShell() async {
        let output = await LoginShellPath.runLoginShell(shell: "/nonexistent/shell-xyz")
        XCTAssertNil(output)
    }
}
