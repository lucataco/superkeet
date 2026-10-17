import XCTest
import FoundationModels
@testable import Superkeet

final class ActionErrorHandlingTests: XCTestCase {
    func testCancellationRecognizesTypesAndDomainsRatherThanMessageText() {
        let cancellations: [Error] = [CancellationError(), ActionExecutionError.cancelled,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        for error in cancellations { XCTAssertTrue(ActionErrorHandling.isCancellation(error)) }
        for error in [ActionExecutionError.timedOut, .approvalDenied("fixture")] {
            XCTAssertFalse(ActionErrorHandling.isCancellation(error))
        }
        XCTAssertFalse(ActionErrorHandling.isCancellation(NSError(domain: "fixture", code: NSURLErrorCancelled)))
        XCTAssertFalse(ActionErrorHandling.isCancellation(NativeOpenActionError.openFailed("cancelled-looking message")))
    }

    func testOrdinaryToolFailuresBecomeModelResults() throws {
        let failure = try XCTUnwrap(ActionErrorHandling.modelResult(
            for: MCPConnectionError.toolReportedError("No element with index 7"), mutating: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failure.utf8)) as? [String: String])
        XCTAssertEqual(object["status"], "error")
        XCTAssertEqual(object["code"], "tool_failed")
        XCTAssertTrue(object["error"]?.contains("No element with index 7") == true)

        let tooLarge = try XCTUnwrap(ActionErrorHandling.modelResult(for: ActionExecutionError.argumentsTooLarge, mutating: false))
        XCTAssertTrue(tooLarge.contains("\"code\":\"arguments_too_large\""))

        let long = String(repeating: "x", count: ActionResultText.modelLimit * 2)
        let truncated = try XCTUnwrap(ActionErrorHandling.modelResult(for: NativeOpenActionError.openFailed(long), mutating: false))
        XCTAssertLessThan(truncated.count, long.count)
    }

    func testTimedOutChangesAreReportedAsUnknownAndNotToBeRepeated() throws {
        let change = try XCTUnwrap(ActionErrorHandling.modelResult(for: ActionExecutionError.timedOut, mutating: true))
        XCTAssertTrue(change.contains("\"code\":\"timed_out\""))
        XCTAssertTrue(change.contains("may or may not have happened"))
        XCTAssertTrue(change.contains("Do not repeat it"))
        let read = try XCTUnwrap(ActionErrorHandling.modelResult(for: ActionExecutionError.timedOut, mutating: false))
        XCTAssertTrue(read.contains("result is unknown"))
        XCTAssertFalse(read.contains("Do not repeat it"))
    }

    func testRunEndingFailuresStillThrow() {
        let limits: [ActionExecutionError] = [.cancelled, .approvalDenied("Open App"), .planDenied,
                                              .stepBudgetExceeded, .runDeadlineExceeded(seconds: 60), .noTools]
        let fatal: [Error] = limits + [CancellationError(), NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)]
        for error in fatal {
            XCTAssertNil(ActionErrorHandling.modelResult(for: error, mutating: true), "\(error)")
        }
    }

    @available(macOS 26.0, *)
    func testWrappedToolErrorsAreClassifiedByTheirCause() throws {
        let tool = try XCTUnwrap(MCPToolBridge(spec: NativeOpenAction.tools[0], execute: { _, _ in "unused" }))
        let denied = LanguageModelSession.ToolCallError(tool: tool, underlyingError: ActionExecutionError.approvalDenied("Open App"))
        XCTAssertNil(ActionErrorHandling.modelResult(for: denied, mutating: true))
        let timedOut = LanguageModelSession.ToolCallError(tool: tool, underlyingError: ActionExecutionError.timedOut)
        XCTAssertTrue(ActionErrorHandling.modelResult(for: timedOut, mutating: false)?.contains("timed_out") == true)
    }

    func testNSErrorUnderlyingCancellationIsPreserved() {
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: CancellationError()])
        XCTAssertTrue(ActionErrorHandling.isCancellation(wrapped))
        XCTAssertEqual(ActionErrorHandling.userFacingMessage(for: wrapped), ActionExecutionError.cancelled.localizedDescription)
    }

    @available(macOS 26.0, *)
    func testNestedFoundationToolErrorsUnwrapCancellationAndOrdinaryFailures() throws {
        let tool = try XCTUnwrap(MCPToolBridge(spec: NativeOpenAction.tools[0], execute: { _, _ in "unused" }))
        let wrapped = LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())
        let nested = LanguageModelSession.ToolCallError(tool: tool, underlyingError: wrapped)
        XCTAssertTrue(ActionErrorHandling.isCancellation(nested))
        let denial = ActionExecutionError.approvalDenied("Open App")
        let denied = LanguageModelSession.ToolCallError(tool: tool, underlyingError: denial)
        XCTAssertFalse(ActionErrorHandling.isCancellation(denied))
        XCTAssertEqual(ActionErrorHandling.userFacingMessage(for: denied), denial.localizedDescription)
    }

    @available(macOS 26.0, *)
    func testWrappedContextOverflowKeepsUsefulMessage() throws {
        let tool = try XCTUnwrap(MCPToolBridge(spec: NativeOpenAction.tools[0], execute: { _, _ in "unused" }))
        let overflow = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "fixture"))
        let wrapped = LanguageModelSession.ToolCallError(tool: tool, underlyingError: overflow)
        XCTAssertFalse(ActionErrorHandling.isCancellation(wrapped))
        XCTAssertTrue(ActionErrorHandling.userFacingMessage(for: wrapped).contains("Try a narrower request"))
    }

    func testCyclicNSErrorChainTerminates() {
        XCTAssertFalse(ActionErrorHandling.isCancellation(CyclicError()))
    }

    private final class CyclicError: NSError, @unchecked Sendable {
        init() { super.init(domain: "cycle", code: 1, userInfo: nil) }
        required init?(coder: NSCoder) { super.init(coder: coder) }
        override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
    }
}
