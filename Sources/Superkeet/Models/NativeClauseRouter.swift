import Foundation

/// What the router needs to know about the run so far: which app the command is acting in, and
/// how spoken names resolve to installed, running apps.
struct NativeClauseContext {
    var currentApp: String?
    var resolveApp: (String) -> URL?
    var isRunning: (URL) -> Bool
}

/// Maps one spoken clause to the built-in action that carries it out, or nil when only the
/// planner can. Shared by the live-speech step detector (which runs clauses while the user is
/// still talking) and by the command runner (which recognises those clauses as already done), so
/// both sides agree on what a clause means.
enum NativeClauseRouter {
    /// Resolve final open commands before executing them. Unknown names belong to the current
    /// app when there is one; explicit website requests still go to the browser.
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
        let intent = HeuristicIntentExtractor.intent(for: clause)
        guard intent.scope != .activeTab else { return nil }
        if let action = NativeOpenAction.fastPath(for: intent) {
            switch action {
            case .openApp(let name):
                if context.resolveApp(name) != nil { return action }
                // "open a new note" reads as an open, but nothing installed is called that; it is ⌘N.
                if let recipe = NativeAppRecipe.recipe(for: clause), let target = shortcutTarget(recipe, context: context) {
                    return .pressShortcut(app: target, shortcut: recipe.shortcut)
                }
                return nil
            case .openURL(let url, nil):
                // A bare URL or search goes to the browser an earlier step opened.
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

    /// Text goes to the named app when it is installed and running; a name that is not an app
    /// ("into Body", "in Paris") belongs to the text, so the current app takes the full phrase.
    static func typeTarget(_ recipe: NativeTypeRecipe, context: NativeClauseContext) -> (app: String, text: String)? {
        if case .named(let name) = recipe.target, let url = context.resolveApp(name), context.isRunning(url) {
            return (url.deletingPathExtension().lastPathComponent, recipe.text)
        }
        if let current = context.currentApp { return (current, recipe.fullText) }
        return nil
    }
}
