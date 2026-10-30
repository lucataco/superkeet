import AppKit
import SwiftUI
import XCTest
@testable import Superkeet

@MainActor
final class ActionHUDRenderTests: XCTestCase {
    private static let command = "Can you open up TextEdit for me? And once you're there, can you create a new document? And let's make the title say hello."

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/hud-renders", isDirectory: true)
    }

    func testRenderTheThreeCardsToPNG() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUPERKEET_RENDER_HUD"] == "1",
                          "Set SUPERKEET_RENDER_HUD=1 to write PNGs under .build/hud-renders/.")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try render(listeningWithTwoEarlyActions(), as: "1-listening")
        try render(finishedWithThreeActions(), as: "2-finished")
        try render(plannerStepFailed(), as: "3-failed")
    }

    private func listeningWithTwoEarlyActions() throws -> some View {
        let textEdit = NativeLaunchedApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 4039, windowReady: false)
        let newDocument = SpeculativeStep(
            index: 1, clause: "can you create a new document",
            action: .pressShortcut(app: "TextEdit", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))), sequence: 5
        )
        let early = ActionLine.early(
            activity: .launched(textEdit),
            steps: [.done(SpeculativeStepResult(step: newDocument, output: "Pressed ⌘N in TextEdit (pid 4039).", failure: nil))]
        )
        let heard = "Can you open up TextEdit for me? And once you're there, can you create a new document? And let's make the ti"
        return ActionHUDCard(
            header: ActionHUDHeader(icon: .listening, title: "Listening…", subtitle: "Press ⌥ Space to stop", button: "Stop"),
            content: {
                ActionHUDBody(transcript: .init(text: heard, isRecording: true, placeholder: "Say a command…"), lines: early)
            }
        )
    }

    private func finishedWithThreeActions() throws -> some View {
        var checklist = ActionChecklist()
        checklist.addDone("Opened TextEdit")
        checklist.addDone(NativeOpenAction.pressShortcut(app: "TextEdit", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"])))
            .lineDoneTitle(clause: "can you create a new document"))
        let typing = NativeOpenAction.typeText(app: "TextEdit", text: "hello")
        checklist.setOpenLine(typing.lineTitle())
        checklist.settleOpenLine(title: typing.lineDoneTitle())
        checklist.finish(.succeeded)
        let message = "Opened TextEdit (pid 4039, com.apple.TextEdit). No window has appeared yet. Typed “hello” in TextEdit (pid 4039)."
        return ActionHUDCard(
            header: ActionHUDHeader(icon: .done, title: "Done", subtitle: "“\(Self.command)”", button: "Dismiss"),
            content: {
                ActionHUDBody(note: checklist.outcomeText(message: message, succeeded: true).map(ActionHUDBody.Note.result),
                              lines: checklist.lines)
            }
        )
    }

    private func plannerStepFailed() -> some View {
        let browser = ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(), serverName: "chrome-devtools", name: "get_browser_state", title: nil,
            description: nil, risk: .readOnly, inputSchemaJSON: "{}"
        ))
        var checklist = ActionChecklist()
        checklist.addDone("Opened Helium")
        checklist.setOpenLine(ActionLineText.clause("and summarize the page."))
        checklist.apply(.toolStarted(browser))
        let message = "Couldn't read the page. No browser tools are enabled."
        checklist.apply(.toolFailed(browser, message))
        checklist.finish(.failed(message: message))
        return ActionHUDCard(
            header: ActionHUDHeader(icon: .failed, title: checklist.failureTitle, subtitle: "“Open Helium and summarize the page.”", button: "Dismiss"),
            content: {
                ActionHUDBody(note: checklist.outcomeText(message: message, succeeded: false).map(ActionHUDBody.Note.problem),
                              lines: checklist.lines)
            }
        )
    }

    private func render(_ card: some View, as name: String) throws {
        let framed = card
            .padding(24)
            .background(LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.23), Color(red: 0.23, green: 0.18, blue: 0.27)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        var data: Data?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            data = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        let png = try XCTUnwrap(data, "Rendering \(name) produced no image.")
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
