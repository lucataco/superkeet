import XCTest
@testable import Superkeet

final class DemoReplayClassificationTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")
    private var notes: URL { directory.appendingPathComponent("Notes.app") }
    private var arc: URL { directory.appendingPathComponent("Arc.app") }
    private var photoBooth: URL { directory.appendingPathComponent("Photo Booth.app") }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-actions")
    }

    private func context(currentApp: String?) -> NativeClauseContext {
        NativeClauseContext(
            currentApp: currentApp,
            resolveApp: { [notes, arc, photoBooth] name in
                let normalized = AppResolver.normalizedName(name)
                if normalized.contains("note") { return notes }
                if normalized.contains("arc") { return arc }
                if normalized.contains("photo") || normalized.contains("camera") { return photoBooth }
                return nil
            },
            isRunning: { _ in true }
        )
    }

    private func routeLines(for text: String, startingApp: String? = nil) -> [String] {
        var current = startingApp
        var lines: [String] = []
        for clause in CommandClauses.split(text) {
            if CommandLeadIn.isAcknowledgement(clause) || CommandClauses.isDroppable(clause) {
                continue
            }
            let action = NativeClauseRouter.action(for: clause, context: context(currentApp: current))
            if let action {
                lines.append("NAT\t\(clause)\t\(action.toolName)")
                switch action {
                case .openApp(let name):
                    current = AppResolver.normalizedName(name).contains("arc") ? "Arc"
                        : AppResolver.normalizedName(name).contains("photo") ? "Photo Booth"
                        : "Notes"
                case .openURL(_, let browser):
                    if let browser { current = browser }
                case .pressShortcut(let app, _), .typeText(let app, _):
                    current = app
                }
            } else {
                lines.append("PLAN\t\(clause)")
            }
        }
        return lines
    }

    func testEngineTranscriptKeepsCaptureOnThePlanner() throws {
        let transcript = try String(contentsOf: fixtures.appendingPathComponent("expected-transcript.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = try loadSection("engine")
        let actual = routeLines(for: transcript)
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.contains("PLAN\tlet's take a picture of me"), actual.joined(separator: "\n"))
    }

    func testIdealizedUtterancesRouteNativeExceptCapture() throws {
        let expected = try loadSection("ideal")
        let utterances = [
            "Alright, can you open up the notes app for me and once you're there can you create a new note and inside this new note let's make the title say hello",
            "can you open up the Arc browser and once you're there can you Google search Norbert Wiener",
            "Now can you open up x.com",
            "now can you open up the photo booth and let's take a picture of me",
        ]
        var current: String?
        var actual: [String] = []
        for utterance in utterances {
            let lines = routeLines(for: utterance, startingApp: current)
            actual.append(contentsOf: lines)
            if lines.contains(where: { $0.contains("Arc") || $0.contains("the Arc browser") }) {
                current = "Arc"
            }
            if utterance.contains("photo booth") {
                current = "Photo Booth"
            }
        }
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.contains("PLAN\tlet's take a picture of me"), actual.joined(separator: "\n"))
    }

    func testCommaRestoresTheNotesCompound() {
        let text = "Can you open up the Notes app for me? And once you're there, create a new note. And inside this new note, let's make the title say hello."
        let lines = routeLines(for: text)
        XCTAssertEqual(lines.filter { $0.hasPrefix("NAT\t") }.count, 3, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("type_text") }, lines.joined(separator: "\n"))
    }

    private func loadSection(_ name: String) throws -> [String] {
        let raw = try String(contentsOf: fixtures.appendingPathComponent("expected-routes.txt"), encoding: .utf8)
        var section: [String] = []
        var taking = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == "# engine" || line == "# ideal" {
                taking = line.dropFirst().trimmingCharacters(in: .whitespaces) == name
                continue
            }
            if line.hasPrefix("#") {
                continue
            }
            if taking, !line.isEmpty {
                section.append(line)
            }
        }
        XCTAssertFalse(section.isEmpty, "expected-routes.txt is missing # \(name)")
        return section
    }
}
