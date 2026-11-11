import AppKit
import SwiftUI
import XCTest
@testable import Superkeet

/// Writes the compact pill in each state under a mock notch to `.build/hud-renders/pill-*.png`.
/// Run with `SUPERKEET_RENDER_HUD=1 swift test --filter ActionPillRenderTests`.
@MainActor
final class ActionPillRenderTests: XCTestCase {
    private typealias Content = ActionPillContent

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/hud-renders", isDirectory: true)
    }

    private static let states: [(name: String, state: ActionPillState)] = [
        ("1-idle", ActionPillState(isSessionActive: true)),
        ("2-speaking", ActionPillState(
            isSessionActive: true,
            transcript: "Can you open up the Notes app for me and inside this new note, let's make the title say hello"
        )),
        ("3-speaking-short", ActionPillState(isSessionActive: true, transcript: "Can you Google search Norbert Wiener?")),
        ("4-confirmed", ActionPillState(phase: .running, isSessionActive: true, confirmation: "Opened TextEdit")),
        ("5-confirmed-while-speaking", ActionPillState(
            phase: .running, isSessionActive: true,
            transcript: "and once you're there can you create a new document", confirmation: "Opened TextEdit"
        )),
        ("6-working", ActionPillState(phase: .running, isSessionActive: true, runningStep: "Summarize the page")),
        ("7-failed", ActionPillState(
            phase: .failed("no"), isSessionActive: true,
            failure: failedChecklistLine
        ))
    ]

    private static var failedChecklistLine: String {
        var checklist = ActionChecklist()
        checklist.addDone("Opened Helium")
        checklist.setOpenLine("Summarize the page")
        let message = "Couldn't read the page. No browser tools are enabled."
        checklist.finish(.failed(message: message))
        return ActionPillContent.failureLine(checklist: checklist, message: message)
    }

    func testRenderThePillStatesToPNG() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUPERKEET_RENDER_HUD"] == "1",
                          "Set SUPERKEET_RENDER_HUD=1 to write PNGs under .build/hud-renders/.")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var sheet: [(String, Content)] = []
        for (name, state) in Self.states {
            guard case .pill(let content) = Content.presentation(for: state) else {
                XCTFail("\(name) should be a pill")
                continue
            }
            sheet.append((name, content))
            try render(underNotch(content), as: "pill-\(name)", dark: true)
        }
        try render(VStack(spacing: 0) { ForEach(sheet, id: \.0) { self.underNotch($0.1) } }, as: "pill-all-dark", dark: true)
        try render(VStack(spacing: 0) { ForEach(sheet, id: \.0) { self.underNotch($0.1) } }, as: "pill-all-light", dark: false)
        let expanded = ActionHUDCard(
            header: ActionHUDHeader(icon: .listening, title: "Listening", subtitle: "Press ⌥⇧Space to stop", button: "Stop"),
            onCollapse: {},
            content: {
                ActionHUDBody(transcript: .init(text: "", isRecording: false, placeholder: ActionHUDView.sessionPrompt),
                              lines: [ActionLine(status: .done, title: "Opened TextEdit")])
            }
        )
        try render(expanded.padding(24).background(Color(red: 0.13, green: 0.19, blue: 0.23)), as: "pill-8-expanded-card", dark: true)
    }

    private func underNotch(_ content: Content) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.45, blue: 0.72), Color(red: 0.10, green: 0.32, blue: 0.56)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.bar).frame(height: 37)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color.black)
                .frame(width: 200, height: 37)
            ActionPillView(content: content, onStop: {}, onMore: {})
                .padding(.top, 37 + OverlayGeometry.notchPillGap)
        }
        .frame(width: 700, height: 37 + OverlayGeometry.notchPillGap + ActionPillView.size.height + 14)
        .clipped()
    }

    private func render(_ view: some View, as name: String, dark: Bool) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        var data: Data?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            data = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        let png = try XCTUnwrap(data, "Rendering \(name) produced no image.")
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
