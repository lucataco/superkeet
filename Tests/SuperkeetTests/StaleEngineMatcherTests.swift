import XCTest
@testable import Superkeet

final class StaleEngineMatcherTests: XCTestCase {
    private let socket = "/Users/me/Library/Caches/com.superkeet.app/Runtime/daemon.sock"
    private let bundled = "/Applications/Superkeet.app/Contents/Resources/bin/parakeet"

    func testExactBinaryIsOurs() {
        XCTAssertTrue(StaleEngineMatcher.isOurEngine(executablePath: bundled, arguments: [], expectedBinary: bundled, socketPath: socket))
    }

    func testEngineFromAMovedAppServingOurSocketIsOurs() {
        let old = "/private/var/folders/xy/AppTranslocation/ABC/d/Superkeet.app/Contents/Resources/bin/parakeet"
        XCTAssertTrue(StaleEngineMatcher.isOurEngine(
            executablePath: old, arguments: ["serve", "--socket", socket, "--pid-file", "p"], expectedBinary: bundled, socketPath: socket
        ))
    }

    func testOtherProcessesAreLeftAlone() {
        XCTAssertFalse(StaleEngineMatcher.isOurEngine(
            executablePath: "/opt/homebrew/bin/parakeet", arguments: ["serve", "--socket", "/tmp/other.sock"], expectedBinary: bundled, socketPath: socket
        ), "Someone else's daemon")
        XCTAssertFalse(StaleEngineMatcher.isOurEngine(
            executablePath: "/usr/bin/python3", arguments: ["serve", "--socket", socket], expectedBinary: bundled, socketPath: socket
        ), "Not a parakeet binary")
        XCTAssertFalse(StaleEngineMatcher.isOurEngine(
            executablePath: "/opt/homebrew/bin/parakeet", arguments: ["transcribe", "--socket", socket], expectedBinary: bundled, socketPath: socket
        ))
    }

    func testParsesTheKernelArgumentLayout() {
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/bin/parakeet".utf8) + [0, 0, 0]
        for argument in ["parakeet", "serve", "--socket"] { buffer += Array(argument.utf8) + [0] }
        buffer += Array("PATH=/usr/bin".utf8) + [0]
        XCTAssertEqual(ProcessArguments.parse(buffer), ["parakeet", "serve", "--socket"])
        XCTAssertNil(ProcessArguments.parse([1, 0]))
    }

    func testReadsARealProcessArguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        XCTAssertEqual(ProcessArguments.arguments(of: process.processIdentifier), ["/bin/sleep", "5"])
    }
}
