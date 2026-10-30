import XCTest
@testable import Superkeet

/// Replays the demo video's audio, as the engine heard it take by take, through the same live
/// detectors the app runs, on a simulated clock, and checks every action is dispatched no later
/// than the video shows it happening.
///
/// The partials and ticks come from `Tests/Fixtures/demo-actions/replay-partials.ndjson`,
/// produced by `scripts/demo_replay_partials.py` from `demo-audio.wav` with the pinned engine.
/// The video's visible onsets are in `video-clock.tsv`. No microphone, speakers, model or
/// engine is needed here, so it runs in CI.
final class DemoReplayTimingTests: XCTestCase {
    private static let partialLatencyMs = 150
    /// The engine sends a tick as the audio it covers arrives, before the decode that makes the
    /// partial, so it lags the audio only by capture buffering, about one 32 ms VAD chunk.
    private static let tickLatencyMs = 30
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
        var ticks: [(atMs: Int, silenceMs: Int)] = []
        var final = ""
    }

    private enum Heard {
        case partial(PartialTranscript)
        case tick(EngineTick)
    }

    private struct Dispatch {
        let atMs: Int
        let action: NativeOpenAction
        let how: String
    }

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
            case "tick":
                take.ticks.append((try XCTUnwrap(object["at_ms"] as? Int), try XCTUnwrap(object["trailing_silence_ms"] as? Int)))
            case "final":
                take.final = try XCTUnwrap(object["text"] as? String)
            default:
                XCTFail("Unknown line \(line)")
            }
            takes[index] = take
        }
        return takes.keys.sorted().compactMap { takes[$0] }
    }

    private func loadVideoClock() throws -> [String: Int] {
        let raw = try String(contentsOf: fixtures.appendingPathComponent("video-clock.tsv"), encoding: .utf8)
        var clock: [String: Int] = [:]
        for line in raw.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2, let ms = Int(columns[0]) else { continue }
            clock[String(columns[1])] = ms
        }
        return clock
    }

    private func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1_000) }
    private func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1_000).rounded()) }

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

            let heard: [(arrival: Int, order: Int, event: Heard)] =
                take.ticks.map { tick in
                    (tick.atMs + Self.tickLatencyMs, 0, .tick(EngineTick(
                        sessionID: "take", audio: .milliseconds(tick.atMs - take.startMs), trailingSilence: .milliseconds(tick.silenceMs)
                    )))
                } + take.partials.map { partial in
                    (partial.atMs + Self.partialLatencyMs, 1, .partial(PartialTranscript(text: partial.text, isFinal: false, sequence: partial.sequence)))
                }
            for (arrival, _, event) in heard.sorted(by: { ($0.arrival, $0.order) < ($1.arrival, $1.order) }) {
                guard arrival < take.endMs else { break }
                fireTrailing(before: arrival)
                switch event {
                case .tick(let tick):
                    record(steps.observe(tick), at: arrival, how: "sentence ended in silence")
                case .partial(let transcript):
                    if let commit = launch.observe(transcript) {
                        dispatches.append(Dispatch(atMs: arrival, action: .openApp(name: commit.action.app.name), how: "instant launch"))
                        ran.append(.openApp(name: commit.action.app.name))
                    }
                    record(steps.observe(transcript, launchedApp: launch.commit?.action.app, at: date(arrival)), at: arrival, how: "while speaking")
                }
            }
            fireTrailing(before: take.endMs)

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
        let videoClock = try loadVideoClock()
        let expectations: [(event: String, matches: (NativeOpenAction) -> Bool)] = [
            ("notes_open", { appName($0) == "Notes" }),
            ("new_note", { if case .pressShortcut("Notes", let key) = $0 { return key.displayName == "⌘N" }; return false }),
            ("title_hello", { if case .typeText("Notes", let text) = $0 { return text.lowercased().contains("hello") }; return false }),
            ("arc", { appName($0) == "Arc" }),
            ("search", { if case .openURL(let url, _) = $0 { return url.absoluteString.contains("Norbert") }; return false }),
            ("xcom", { if case .openURL(let url, _) = $0 { return url.host == "x.com" }; return false }),
            ("photobooth", { appName($0) == "Photo Booth" }),
            ("countdown", { if case .pressShortcut(_, let key) = $0 { return key.displayName == "↩" || key.keyCode == 36 }; return false })
        ]
        var summary: [String] = []
        for expectation in expectations {
            guard let videoMs = videoClock[expectation.event] else {
                XCTFail("video-clock.tsv has no \(expectation.event) row.")
                continue
            }
            guard let dispatch = first(dispatches, expectation.matches) else {
                XCTFail("\(expectation.event) was never dispatched.\n\(report)")
                continue
            }
            let margin = videoMs - dispatch.atMs
            summary.append("\(expectation.event): \(dispatch.atMs) ms (\(dispatch.how)), video \(videoMs) ms, \(margin) ms early")
            XCTAssertLessThanOrEqual(dispatch.atMs, videoMs, "\(expectation.event) is later than the video.\n\(report)")
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
