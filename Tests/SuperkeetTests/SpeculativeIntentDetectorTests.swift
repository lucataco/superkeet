import AppKit
import XCTest
@testable import Superkeet

final class SpeculativeIntentDetectorTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")

    private func url(_ app: String) -> URL { directory.appendingPathComponent("\(app).app") }

    private func environment(
        installed: [String] = ["Notes", "Discord", "Safari", "Safari Technology Preview", "Pages", "Android Studio", "Google Chrome"],
        running: [String] = []
    ) -> SpeculativeIntentDetector.Environment {
        let apps = installed.map(url)
        let resolver = AppResolver(directories: [directory], applicationsInDirectory: { _ in apps })
        let runningURLs = Set(running.map(url))
        return .init(
            resolveApp: { resolver.resolve($0) },
            installedNames: { resolver.installedApplicationNames() },
            isRunning: { runningURLs.contains($0) }
        )
    }

    @discardableResult
    private func feed(
        _ detector: inout SpeculativeIntentDetector, _ texts: [String], finalLast: Bool = false
    ) -> (sequence: Int, commit: SpeculativeCommit)? {
        var result: (Int, SpeculativeCommit)?
        for (offset, text) in texts.enumerated() {
            let sequence = offset + 1
            let partial = PartialTranscript(text: text, isFinal: finalLast && offset == texts.count - 1, sequence: sequence)
            if let commit = detector.observe(partial) {
                XCTAssertNil(result, "A session commits at most once; second commit at sequence \(sequence)")
                result = (sequence, commit)
            }
        }
        return result
    }

    private let notesProbe = [
        "Open", "Open the", "Open the Notes", "Open the Notes app", "Open the Notes app and", "Open the Notes app and create",
        "Open the Notes app and create a", "Open the Notes app and create a new", "Open the Notes app and create a new note",
        "Open the Notes app and create a new note."
    ]

    func testDefaultThresholdTrustsTheFirstUnambiguousSighting() {
        var detector = SpeculativeIntentDetector(environment: environment())
        XCTAssertEqual(detector.stabilityThreshold, 1)
        let result = feed(&detector, notesProbe + ["Open the Notes app and create a new note."], finalLast: true)
        XCTAssertEqual(result?.sequence, 3, "\"Open the Notes\" already names an installed app no other name extends.")
        XCTAssertEqual(result?.commit.reason, .stable(count: 1))
        XCTAssertEqual(result?.commit.action.app.name, "Notes")
        XCTAssertFalse(detector.disagreement)
    }

    func testProbeTranscriptCommitsOnceTheAppNameIsStable() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 2)
        let result = feed(&detector, notesProbe + ["Open the Notes app and create a new note."], finalLast: true)
        XCTAssertEqual(result?.sequence, 4, "Commit on the second consecutive partial naming Notes, before the conjunction arrives.")
        XCTAssertEqual(result?.commit.action, .launch(SpeculativeApp(spokenName: "notes", url: url("Notes"))))
        XCTAssertEqual(result?.commit.clause, "open the notes app")
        XCTAssertEqual(result?.commit.reason, .stable(count: 2))
        XCTAssertEqual(detector.commit, result?.commit, "The commit is retained for the rest of the session.")
        XCTAssertFalse(detector.disagreement, "The rest of the sentence agrees with the launch.")
    }

    func testClauseBoundaryCommitsWhenStabilityIsNotYetReached() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 3)
        let result = feed(&detector, notesProbe)
        XCTAssertEqual(result?.sequence, 5, "\"Open the Notes app and\" completes the clause.")
        XCTAssertEqual(result?.commit.reason, .clauseBoundary)
        XCTAssertEqual(result?.commit.clause, "open the notes app")
        XCTAssertEqual(result?.commit.action.app.name, "Notes")
    }

    func testMisheardAppNameNeverCommits() {
        var detector = SpeculativeIntentDetector(environment: environment(installed: ["Ghostty", "Discord"], running: ["Ghostty"]))
        let result = feed(&detector, [
            "Switch", "Switch to", "Switch to G", "Switch to Gost", "Switch to Gosti", "Switch to Gosti and", "Switch to Gosti and then",
            "Switch to Gosti and then open", "Switch to Gosti and then open disc", "Switch to Gosti and then open disccord.",
            "Switch to Ghosti and then open Discord."
        ], finalLast: true)
        XCTAssertNil(result)
        XCTAssertNil(detector.commit)
        XCTAssertFalse(detector.disagreement)
    }

    func testFinalizedTextCommitsWithoutBoundaryOrStability() {
        var detector = SpeculativeIntentDetector(environment: environment())
        let result = feed(&detector, ["Open Notes"], finalLast: true)
        XCTAssertEqual(result?.sequence, 1)
        XCTAssertEqual(result?.commit.reason, .finalized)
        XCTAssertEqual(result?.commit.action.app.name, "Notes")
    }

    func testSingleVolatilePartialIsNotEnoughAtAHigherThreshold() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 2)
        XCTAssertNil(feed(&detector, ["Open Notes"]))
        XCTAssertNil(detector.commit)
    }

    func testStabilityCountsOnlyConsecutivePartialsNamingTheSameApp() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 2)
        let result = feed(&detector, ["Open Notes", "Open Nodes", "Open Notes", "Open Notes app"])
        XCTAssertEqual(result?.sequence, 4, "The unresolved partial in the middle resets the streak.")
        XCTAssertEqual(result?.commit.reason, .stable(count: 2))
    }

    func testPrefixAmbiguityWaitsForBoundaryOrFinal() {
        var waiting = SpeculativeIntentDetector(environment: environment())
        XCTAssertNil(feed(&waiting, ["Open Safari", "Open Safari browser"]))
        XCTAssertNil(waiting.commit)

        var boundary = SpeculativeIntentDetector(environment: environment())
        let atBoundary = feed(&boundary, ["Open Safari", "Open Safari browser", "Open Safari browser and"])
        XCTAssertEqual(atBoundary?.commit.reason, .clauseBoundary)
        XCTAssertEqual(atBoundary?.commit.action.app.name, "Safari")

        var finalized = SpeculativeIntentDetector(environment: environment())
        XCTAssertEqual(feed(&finalized, ["Open Safari", "Open Safari"], finalLast: true)?.commit.reason, .finalized)

        var longer = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 2)
        let preview = feed(&longer, ["Open Safari", "Open Safari Tech", "Open Safari Technology Preview", "Open Safari Technology Preview app"])
        XCTAssertEqual(preview?.sequence, 4)
        XCTAssertEqual(preview?.commit.action.app.name, "Safari Technology Preview")
        XCTAssertEqual(preview?.commit.reason, .stable(count: 2))
    }

    func testANameThatIsAPrefixOfAnotherAppWaitsEvenWithoutASpace() {
        // "Note" while "Notes" is installed: the recogniser may still be mid-word.
        var waiting = SpeculativeIntentDetector(environment: environment(installed: ["Note", "Notes", "Discord"]))
        XCTAssertNil(feed(&waiting, ["Open Note", "Open Note app"]))
        let settled = waiting.observe(PartialTranscript(text: "Open Note and", isFinal: false, sequence: 3))
        XCTAssertEqual(settled?.action.app.name, "Note", "A clause boundary settles it.")
        XCTAssertEqual(settled?.reason, .clauseBoundary)

        var full = SpeculativeIntentDetector(environment: environment(installed: ["Note", "Notes", "Discord"]))
        XCTAssertEqual(feed(&full, ["Open Notes"])?.commit.reason, .stable(count: 1), "Nothing extends \"notes\", so it launches at once.")
    }

    func testLeadInPhrasesBeforeTheVerbAreSkipped() {
        for phrase in [
            "Lets open Chrome and", "Let's open Chrome and", "I want to open Chrome and", "Okay so can you open Chrome and",
            "go ahead and pull up Chrome and", "fire up Chrome and", "Yeah, just start Chrome and"
        ] {
            var detector = SpeculativeIntentDetector(environment: environment())
            let result = feed(&detector, [phrase])
            XCTAssertEqual(result?.commit.action.app.name, "Google Chrome", phrase)
            XCTAssertEqual(result?.commit.reason, .clauseBoundary, phrase)
        }
    }

    func testAliasesResolveAndAmbiguityUsesTheSpokenName() {
        var detector = SpeculativeIntentDetector(environment: environment())
        let result = feed(&detector, ["Open Chrome", "Open Chrome browser"])
        XCTAssertEqual(result?.commit.action, .launch(SpeculativeApp(spokenName: "chrome", url: url("Google Chrome"))))
        XCTAssertEqual(result?.commit.action.app.name, "Google Chrome")
    }

    func testFillerWordsBeforeTheVerbAreSkipped() {
        var detector = SpeculativeIntentDetector(environment: environment())
        let result = feed(&detector, ["Hey Superkeet, please open the Notes app and"])
        XCTAssertEqual(result?.commit.reason, .clauseBoundary)
        XCTAssertEqual(result?.commit.clause, "open the notes app")

        var another = SpeculativeIntentDetector(environment: environment())
        XCTAssertEqual(feed(&another, ["um, can you launch Discord then"])?.commit.action.app.name, "Discord")
    }

    func testSwitchToActivatesOnlyRunningApps() {
        var running = SpeculativeIntentDetector(environment: environment(running: ["Notes"]))
        let activated = feed(&running, ["Switch to Notes and"])
        XCTAssertEqual(activated?.commit.action, .activate(SpeculativeApp(spokenName: "notes", url: url("Notes"))))
        XCTAssertEqual(activated?.commit.clause, "switch to notes")

        var stopped = SpeculativeIntentDetector(environment: environment(running: []))
        XCTAssertNil(feed(&stopped, ["Switch to Notes and", "Switch to Notes and create"], finalLast: true),
                     "Switching to a stopped app is left to the real command.")
        XCTAssertNil(stopped.commit)

        for phrase in ["Bring up Notes,", "Go to Notes;", "Switch over to Notes:", "Activate Notes."] {
            var detector = SpeculativeIntentDetector(environment: environment(running: ["Notes"]))
            XCTAssertEqual(feed(&detector, [phrase])?.commit.action, .activate(SpeculativeApp(spokenName: "notes", url: url("Notes"))), phrase)
        }
    }

    func testOpeningARunningAppIsStillALaunch() {
        var detector = SpeculativeIntentDetector(environment: environment(running: ["Notes"]))
        XCTAssertEqual(feed(&detector, ["Open Notes and"])?.commit.action, .launch(SpeculativeApp(spokenName: "notes", url: url("Notes"))))
    }

    func testWebAddressesAndActiveTabScopesNeverCommit() {
        for phrase in ["Open youtube.com and", "Open https://example.com", "Go to youtube.com in Safari and",
                       "In the current Chrome tab, open Notes and", "Open Notes in the active tab and",
                       "Open Notes in Safari's current tab"] {
            var detector = SpeculativeIntentDetector(environment: environment(running: ["Safari", "Notes"]))
            XCTAssertNil(feed(&detector, [phrase, phrase + " more"], finalLast: true), phrase)
        }
    }

    func testBrowserBeforeALaterURLIsStillLaunched() {
        var detector = SpeculativeIntentDetector(environment: environment())
        let result = feed(&detector, ["Open Safari and go to youtube.com"])
        XCTAssertEqual(result?.commit.action.app.name, "Safari", "The URL belongs to a later clause; opening the browser early is harmless.")
    }

    func testCommandsThatDoNotStartWithAnOpenVerbAreIgnored() {
        for phrase in ["Create a new note in Notes and", "Click Save in Notes", "Notes open and", "Open", "Open the"] {
            var detector = SpeculativeIntentDetector(environment: environment())
            XCTAssertNil(feed(&detector, [phrase], finalLast: true), phrase)
        }
    }

    func testOnlyOneCommitPerSessionAndLaterDisagreementIsRecorded() {
        var detector = SpeculativeIntentDetector(environment: environment())
        let first = feed(&detector, ["Open Notes and"])
        XCTAssertEqual(first?.commit.action.app.name, "Notes")

        XCTAssertNil(detector.observe(PartialTranscript(text: "Open Pages and create", isFinal: false, sequence: 2)))
        XCTAssertEqual(detector.commit?.action.app.name, "Notes")
        XCTAssertTrue(detector.disagreement)
    }

    func testFinalTextThatNoLongerNamesTheAppIsADisagreement() {
        var detector = SpeculativeIntentDetector(environment: environment())
        feed(&detector, ["Open Notes and"])
        XCTAssertNil(detector.observe(PartialTranscript(text: "Open the No", isFinal: false, sequence: 2)))
        XCTAssertFalse(detector.disagreement, "A volatile revision that resolves to nothing may still be mid-word.")
        XCTAssertNil(detector.observe(PartialTranscript(text: "Often the notes.", isFinal: true, sequence: 3)))
        XCTAssertTrue(detector.disagreement)
    }

    func testAgreeingFinalKeepsDisagreementClear() {
        var detector = SpeculativeIntentDetector(environment: environment())
        feed(&detector, ["Open Notes and"])
        XCTAssertNil(detector.observe(PartialTranscript(text: "Open the Notes app and create a new note.", isFinal: true, sequence: 2)))
        XCTAssertFalse(detector.disagreement)
    }

    func testOutOfOrderAndRepeatedPartialsAreIgnored() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 2)
        XCTAssertNil(detector.observe(PartialTranscript(text: "Open Notes", isFinal: false, sequence: 3)))
        XCTAssertNil(detector.observe(PartialTranscript(text: "Open Notes app", isFinal: false, sequence: 2)), "Older sequence numbers are dropped.")
        XCTAssertNil(detector.observe(PartialTranscript(text: "Open Notes", isFinal: false, sequence: 4)), "Identical text does not count as a second sighting.")
        XCTAssertNil(detector.commit)
        let final = detector.observe(PartialTranscript(text: "Open Notes", isFinal: true, sequence: 5))
        XCTAssertEqual(final?.reason, .finalized, "The same text becoming final is a real change.")
    }

    func testResetStartsAFreshSession() {
        var detector = SpeculativeIntentDetector(environment: environment())
        feed(&detector, ["Open Notes and"])
        _ = detector.observe(PartialTranscript(text: "Open Pages and", isFinal: false, sequence: 2))
        XCTAssertTrue(detector.disagreement)
        detector.reset()
        XCTAssertNil(detector.commit)
        XCTAssertFalse(detector.disagreement)
        XCTAssertEqual(feed(&detector, ["Open Discord and"])?.commit.action.app.name, "Discord")
    }

    func testStabilityThresholdIsAtLeastOne() {
        var detector = SpeculativeIntentDetector(environment: environment(), stabilityThreshold: 0)
        XCTAssertEqual(detector.stabilityThreshold, 1)
        XCTAssertEqual(feed(&detector, ["Open Notes"])?.commit.reason, .stable(count: 1))
    }

    func testLeadingClauseParsing() {
        typealias Clause = SpeculativeIntentDetector.Clause
        XCTAssertEqual(
            SpeculativeIntentDetector.leadingClause(in: "Open the Notes app and create a new note."),
            Clause(verb: .open, candidate: "the notes app", text: "open the notes app", hasBoundary: true, containsURL: false)
        )
        XCTAssertEqual(
            SpeculativeIntentDetector.leadingClause(in: "Switch over to Notes"),
            Clause(verb: .switchTo, candidate: "notes", text: "switch over to notes", hasBoundary: false, containsURL: false)
        )
        XCTAssertEqual(
            SpeculativeIntentDetector.leadingClause(in: "OPEN   UP   Discord."),
            Clause(verb: .open, candidate: "discord", text: "open up discord", hasBoundary: true, containsURL: false)
        )
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "open notes to write something")?.candidate, "notes")
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "open Android Studio")?.candidate, "android studio",
                       "Conjunctions inside words are not boundaries.")
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "open Android Studio")?.hasBoundary, false)
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "Open youtube.com")?.containsURL, true)
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "Open notes.app and")?.containsURL, false,
                       "A .app suffix is not a web address.")
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "Open the")?.candidate, "the",
                       "A bare article parses; resolution against installed apps rejects it.")
        for text in ["open", "Open ", "create a note", "", "   "] {
            XCTAssertNil(SpeculativeIntentDetector.leadingClause(in: text), text)
        }
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "and open Notes")?.candidate, "notes",
                       "\"And\" is how people connect the next command; it is a lead-in, not a blocker.")
    }

    @MainActor
    func testInventoryEnvironmentUsesInstalledAndRunningApps() async {
        let inventory = InstalledAppInventory()
        let environment = inventory.detectorEnvironment
        XCTAssertNil(environment.resolveApp("the notes app"), "Nothing resolves before the background scan completes.")
        XCTAssertTrue(environment.installedNames().isEmpty)

        let ready = await inventory.waitUntilReady(timeout: .seconds(10))
        XCTAssertTrue(ready)
        XCTAssertNotNil(environment.resolveApp("the notes app"), "Notes ships with macOS.")
        XCTAssertNil(environment.resolveApp("definitely not an installed application"))
        XCTAssertTrue(environment.installedNames().contains { $0.caseInsensitiveCompare("Notes") == .orderedSame })

        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<50 { _ = environment.resolveApp("the notes app") }
        XCTAssertLessThan(clock.now - started, .milliseconds(200), "Repeated resolution must not rescan the disk.")
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            XCTAssertTrue(environment.isRunning(finder), "Finder is always running in a logged-in session.")
        }
        XCTAssertFalse(environment.isRunning(URL(fileURLWithPath: "/fixture/Applications/Nothing.app")))
    }
}
