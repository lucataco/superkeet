import Foundation

struct NativeClauseContext {
    var currentApp: String?
    var resolveApp: (String) -> URL?
    var isRunning: (URL) -> Bool
}

enum NativeClauseRouter {
    static func resolvingOpen(_ action: NativeOpenAction, context: NativeClauseContext) -> NativeOpenAction? {
        var resolved = action
        if case .openApp(let name) = action, context.resolveApp(name) == nil {
            let target = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let isWebsite = target.range(of: #"\b(?:website|site|page)\z"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard isWebsite || context.currentApp == nil,
                  let url = NativeOpenAction.luckySearchURL(for: target) else { return nil }
            resolved = .openURL(url: url, browser: nil)
        }
        if case .openURL(let url, nil) = resolved, let browser = context.currentApp, ActionIntentPolicy.isBrowserName(browser) {
            return .openURL(url: url, browser: browser)
        }
        return resolved
    }

    static func action(for clause: String, context: NativeClauseContext) -> NativeOpenAction? {
        if let action = directAction(for: clause, context: context) { return action }
        var tried: Set<String> = [clause]
        for candidate in fallbackReadings(of: clause) where tried.insert(candidate.text).inserted {
            guard let action = directAction(for: candidate.text, context: context) else { continue }
            if candidate.opensOnly, action.actsInsideApp { continue }
            return action
        }
        return nil
    }

    private static func fallbackReadings(of clause: String) -> [(text: String, opensOnly: Bool)] {
        var readings: [String] = []
        let stripped = CommandLeadIn.strip(clause)
        if !stripped.isEmpty { readings.append(stripped) }
        if let request = CommandClauses.requestSuffix(clause) {
            let requestStripped = CommandLeadIn.strip(request)
            if !requestStripped.isEmpty { readings.append(requestStripped) }
        }
        var result = readings.map { (text: $0, opensOnly: false) }
        // Typing and shortcuts keep every word: "type nice" must still type "nice".
        for reading in [clause] + readings {
            let calmer = CommandLeadIn.stripTrailingReactions(reading)
            if calmer != reading, !calmer.isEmpty { result.append((CommandLeadIn.strip(calmer), true)) }
        }
        return result.filter { !$0.text.isEmpty }
    }

    private static func directAction(for clause: String, context: NativeClauseContext) -> NativeOpenAction? {
        let intent = HeuristicIntentExtractor.intent(for: clause)
        guard intent.scope != .activeTab else { return nil }
        if let action = NativeOpenAction.fastPath(for: intent) {
            switch action {
            case .openApp(let name):
                if context.resolveApp(name) != nil { return action }
                if let recipe = NativeAppRecipe.recipe(for: clause), let target = shortcutTarget(recipe, context: context) {
                    return .pressShortcut(app: target, shortcut: recipe.shortcut)
                }
                return nil
            case .openURL(let url, nil):
                if let browser = context.currentApp, ActionIntentPolicy.isBrowserName(browser) {
                    return .openURL(url: url, browser: browser)
                }
                return action
            default:
                return action
            }
        }
        if let recipe = NativeAppRecipe.recipe(for: clause), let target = shortcutTarget(recipe, context: context) {
            return .pressShortcut(app: target, shortcut: recipe.shortcut)
        }
        if let recipe = NativeTypeRecipe.recipe(for: clause), let target = typeTarget(recipe, context: context) {
            return .typeText(app: target.app, text: target.text)
        }
        return nil
    }

    static func shortcutTarget(_ recipe: NativeAppRecipe, context: NativeClauseContext) -> String? {
        switch recipe.target {
        case .named(let name):
            guard let url = context.resolveApp(name), context.isRunning(url) else { return nil }
            return url.deletingPathExtension().lastPathComponent
        case .current:
            return context.currentApp
        }
    }

    static func typeTarget(_ recipe: NativeTypeRecipe, context: NativeClauseContext) -> (app: String, text: String)? {
        if case .named(let name) = recipe.target, let url = context.resolveApp(name), context.isRunning(url) {
            return (url.deletingPathExtension().lastPathComponent, recipe.text)
        }
        if let current = context.currentApp { return (current, recipe.fullText) }
        return nil
    }
}
