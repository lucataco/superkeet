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
