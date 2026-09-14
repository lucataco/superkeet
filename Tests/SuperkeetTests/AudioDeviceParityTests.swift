import XCTest
@testable import Superkeet

final class AudioDeviceParityTests: XCTestCase {
    func testDeviceNamesAreSortedAndUniqueWithoutChangingSpelling() {
        XCTAssertEqual(AudioInputDeviceResolver.deviceNames(in: [
            (id: 1, name: "USB Mic"), (id: 2, name: "Built-in Mic"), (id: 3, name: "USB Mic")
        ]), ["Built-in Mic", "USB Mic"])
        XCTAssertEqual(AudioInputDeviceResolver.deviceNames(in: []), [])
    }

    func testNativeNamesMatchConfiguredEngine() throws {
        guard let engine = ProcessInfo.processInfo.environment["SUPERKEET_DEVICE_PARITY_ENGINE"] else {
            throw XCTSkip("Set SUPERKEET_DEVICE_PARITY_ENGINE to compare native device names with a built engine.")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: engine)
        process.arguments = ["devices"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = try XCTUnwrap(String(data: data, encoding: .utf8))
        let engineNames = output.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }.compactMap { line -> String? in
            guard let separator = line.range(of: ": ", options: .backwards) else { return nil }
            var name = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix(" (default)") { name.removeLast(" (default)".count) }
            return name
        }
        XCTAssertEqual(AudioInputDeviceResolver.availableDeviceNames(), Array(Set(engineNames)).sorted())
    }
}
