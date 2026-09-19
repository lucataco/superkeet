import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum ActionErrorHandling {
    static func isCancellation(_ error: Error) -> Bool {
        causes(of: error).contains { cause in
            if cause is CancellationError || cause as? ActionExecutionError == .cancelled { return true }
            let cocoa = cause as NSError
            return (cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled)
                || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError)
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if isCancellation(error) { return ActionExecutionError.cancelled.localizedDescription }
        let cause = causes(of: error).last ?? error
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let generation = cause as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation {
            return "That request needed more context than the on-device model allows. Try a narrower request, or turn off extra MCP servers."
        }
        #endif
        return cause.localizedDescription
    }

    private static func causes(of error: Error) -> [Error] {
        var causes: [Error] = []
        var current = error
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<16 {
            causes.append(current)
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), let tool = current as? LanguageModelSession.ToolCallError {
                current = tool.underlyingError
                continue
            }
            #endif
            let cocoa = current as NSError
            guard visited.insert(ObjectIdentifier(cocoa)).inserted,
                  let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            current = underlying
        }
        return causes
    }
}
