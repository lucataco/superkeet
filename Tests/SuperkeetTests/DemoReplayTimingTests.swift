import XCTest
@testable import Superkeet

/// Replays the demo video's audio, as the engine heard it take by take, through the same live
/// detectors the app runs, on a simulated clock, and checks every action is dispatched no later
/// than the video shows it happening.
///
/// The partials come from `Tests/Fixtures/demo-actions/replay-partials.ndjson`, produced by
/// `scripts/demo_replay_partials.py` from `demo-audio.wav` with the pinned engine. No
/// microphone, speakers, model or engine is needed here, so it runs in CI.
final class DemoReplayTimingTests: XCTestCase {
    /// Engine decode plus socket delivery of a partial after the audio it covers.
    private static let partialLatencyMs = 150
    /// Engine finalisation, handoff and command routing after the endpoint.
    private static let finalLatencyMs = 450

    private let directory = URL(fileURLWithPath: "/fixture/Applications")
    private lazy var apps: [URL] = ["Notes", "Arc", "Photo Booth", "Photos", "Safari"]
        .map { directory.appendingPathComponent("\($0).app") }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-actions")
    }

    private struct Take {
        var startMs = 0
        var endMs = 0
        var partials: [(atMs: Int, sequence: Int, text: String)] = []
        var final = ""
    }

    private struct Dispatch {
        let atMs: Int
        let action: NativeOpenAction
        let how: String
    }

    /// The same exact resolver InstalledAppInventory uses while the user is speaking.
    private lazy var resolver = AppResolver(directories: [directory], applicationsInDirectory: { [apps] _ in apps })

    private func resolve(_ name: String) -> URL? {
        resolver.resolve(name)
    }

    private func loadTakes() throws -> [Take] {
        let raw = try String(contentsOf: fixtures.appendingPathComponent("replay-partials.ndjson"), encoding: .utf8)
        var takes: [Int: Take] = [:]
        for line in raw.split(separator: "\n") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let index = try XCTUnwrap(object["take"] as? Int)
            var take = takes[index] ?? Take()
            switch object["type"] as? String {
            case "take":
                take.startMs = try XCTUnwrap(object["start_ms"] as? Int)
                take.endMs = try XCTUnwrap(object["end_ms"] as? Int)
            case "partial":
                take.partials.append((try XCTUnwrap(object["at_ms"] as? Int), try XCTUnwrap(object["sequence"] as? Int), try XCTUnwrap(object["text"] as? String)))
            case "final":
                take.final = try XCTUnwrap(object["text"] as? String)
            default:
                XCTFail("Unknown line \(line)")
            }
            takes[index] = take
        }
        return takes.keys.sorted().compactMap { takes[$0] }
    }

    private func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }
    private func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1_000).rounded()) }

    /// Runs the live detectors over every take and returns what was dispatched, when.
    private func simulate() throws -> [Dispatch] {
        let takes = try loadTakes()
        XCTAssertGreaterThan(takes.count, 3, "The fixture should hold one take per utterance.")
        var dispatches: [Dispatch] = []
        var carriedApp: String?

        for take in takes {
            var launch = SpeculativeIntentDetector(environment: .init(
                resolveApp: resolve, installedNames: { [apps] in apps.map { $0.deletingPathExtension().lastPathComponent } },
                isRunning: { _ in true }
            ))
            var steps = SpeculativeStepDetector(environment: .init(
                resolveApp: resolve, isRunning: { _ in true },
                allows: { SpeculativeStepDetector.allows($0, policy: .readOnlyAuto) },
                installedNames: { [apps] in apps.map { $0.deletingPathExtension().lastPathComponent } }
            ), currentApp: carriedApp)
            var ran: [NativeOpenAction] = []

            func record(_ new: [SpeculativeStep], at time: Int, how: String) {
                for step in new {
                    dispatches.append(Dispatch(atMs: time, action: step.action, how: how))
                    ran.append(step.action)
                }
            }
            func fireTrailing(before time: Int) {
                if let deadline = steps.trailingDeadline, ms(deadline) <= time {
                    record(steps.commitStableTrailing(at: deadline), at: ms(deadline), how: "held still")
                }
            }

            for partial in take.partials {
                let arrival = partial.atMs + Self.partialLatencyMs
                guard arrival < take.endMs else { break }
                fireTrailing(before: arrival)
                let transcript = PartialTranscript(text: partial.text, isFinal: false, sequence: partial.sequence)
                if let commit = launch.observe(transcript) {
                    dispatches.append(Dispatch(atMs: arrival, action: .openApp(name: commit.action.app.name), how: "instant launch"))
                    ran.append(.openApp(name: commit.action.app.name))
                }
                record(steps.observe(transcript, launchedApp: launch.commit?.action.app, at: date(arrival)), at: arrival, how: "while speaking")
            }
            fireTrailing(before: take.endMs)

            // The final transcript runs whatever is left, clause by clause, like the command runner.
            let finalAt = take.endMs + Self.finalLatencyMs
            var app = carriedApp ?? launch.commit?.action.app.name
            for clause in CommandClauses.split(take.final) where !CommandClauses.isDroppable(clause) && !CommandLeadIn.isAcknowledgement(clause) {
                let context = NativeClauseContext(currentApp: app, resolveApp: resolve, isRunning: { _ in true })
                guard let action = NativeClauseRouter.action(for: clause, context: context) else { continue }
                if let index = ran.firstIndex(of: action) {
                    ran.remove(at: index)
                } else if case .openApp(let name) = action, ran.contains(where: {
                    if case .openApp(let other) = $0 { return resolve(other) == resolve(name) } else { return false }
                }) {
                    // Opened while speaking under a different spoken form.
                } else {
                    dispatches.append(Dispatch(atMs: finalAt, action: action, how: "final transcript"))
                }
                switch action {
                case .openApp(let name): app = resolve(name)?.deletingPathExtension().lastPathComponent ?? app
                case .openURL(_, let browser): app = browser ?? app
                case .pressShortcut(let target, _), .typeText(let target, _): app = target
                }
            }
            carriedApp = app
        }
        return dispatches
    }

    private func first(_ dispatches: [Dispatch], _ matches: (NativeOpenAction) -> Bool) -> Dispatch? {
        dispatches.first { matches($0.action) }
    }

    func testEveryDemoActionIsDispatchedNoLaterThanTheVideoShowsIt() throws {
        let dispatches = try simulate()
        let report = dispatches.map { "\($0.atMs) ms  \($0.how)  \($0.action.toolName) \((try? $0.action.argumentsJSON()) ?? "")" }
            .joined(separator: "\n")

        func appName(_ action: NativeOpenAction) -> String? {
            if case .openApp(let name) = action { return resolve(name)?.deletingPathExtension().lastPathComponent }
            return nil
        }
        let expectations: [(event: String, videoMs: Int, matches: (NativeOpenAction) -> Bool)] = [
            ("notes_open", 4_500, { appName($0) == "Notes" }),
            ("new_note", 8_500, { if case .pressShortcut("Notes", let key) = $0 { return key.displayName == "⌘N" }; return false }),
            ("title_hello", 11_500, { if case .typeText("Notes", let text) = $0 { return text.lowercased().contains("hello") }; return false }),
            ("arc", 17_500, { appName($0) == "Arc" }),
            ("search", 21_000, { if case .openURL(let url, _) = $0 { return url.absoluteString.contains("Norbert") }; return false }),
            ("xcom", 25_500, { if case .openURL(let url, _) = $0 { return url.host == "x.com" }; return false }),
            ("photobooth", 31_500, { appName($0) == "Photo Booth" }),
            ("countdown", 37_000, { if case .pressShortcut(_, let key) = $0 { return key.displayName == "↩" || key.keyCode == 36 }; return false })
        ]
        var summary: [String] = []
        for expectation in expectations {
            guard let dispatch = first(dispatches, expectation.matches) else {
                XCTFail("\(expectation.event) was never dispatched.\n\(report)")
                continue
            }
            let margin = expectation.videoMs - dispatch.atMs
            summary.append("\(expectation.event): \(dispatch.atMs) ms (\(dispatch.how)), video \(expectation.videoMs) ms, \(margin) ms early")
            XCTAssertLessThanOrEqual(dispatch.atMs, expectation.videoMs, "\(expectation.event) is later than the video.\n\(report)")
        }
        print("Demo replay timing:\n" + summary.joined(separator: "\n"))
    }

    func testNotesOpensWhileItsNameIsStillBeingSpoken() throws {
        let dispatches = try simulate()
        let notes = try XCTUnwrap(dispatches.first { if case .openApp = $0.action { return true }; return false })
        XCTAssertEqual(notes.how, "instant launch")
        XCTAssertLessThan(notes.atMs, 5_000)
    }

    func testTheNewNoteRunsBeforeTheFinalTranscript() throws {
        let dispatches = try simulate()
        let newNote = try XCTUnwrap(dispatches.first { if case .pressShortcut("Notes", _) = $0.action { return true }; return false })
        XCTAssertNotEqual(newNote.how, "final transcript", "⌘N should not wait for the speaker to stop.")
    }

    func testNothingIsDispatchedTwice() throws {
        let dispatches = try simulate()
        var seen: [String] = []
        for dispatch in dispatches {
            let key = "\(dispatch.action.toolName) \((try? dispatch.action.argumentsJSON()) ?? "")"
            XCTAssertFalse(seen.contains(key), "Dispatched twice: \(key)")
            seen.append(key)
        }
    }
}
