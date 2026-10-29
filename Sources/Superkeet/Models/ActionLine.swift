import Foundation

struct ActionLine: Equatable, Sendable {
    enum Status: Hashable, Sendable {
        case running
        case done
        case failed(reason: String?)
        case denied
    }

    var status: Status
    var title: String

    var reason: String? {
        switch status {
        case .failed(let reason): return reason
        case .denied: return "Not approved"
        case .running, .done: return nil
        }
    }
}

extension Array where Element == ActionLine {
    func folded(limit: Int) -> (hidden: Int, lines: [ActionLine]) {
        guard limit > 0, count > limit else { return (0, self) }
        return (count - limit, Array(suffix(limit)))
    }
}

enum ActionLineText {
    static let maximumReasonLength = 140

    static func clause(_ text: String) -> String {
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?"))
        var title = CommandLeadIn.trim(text).trimmingCharacters(in: punctuation)
        if title.isEmpty { title = text.trimmingCharacters(in: punctuation) }
        return capitalized(title)
    }

    static func plain(_ output: String) -> String {
        var text = output.replacingOccurrences(of: #"\s*\(pid \d+(?:, [^)]*)?\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*(?:Its window is on screen\.|No window has appeared yet\.)"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reason(from message: String) -> String? {
        var text = plain(message).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let end = text.range(of: #"[.!?](?=\s|\z)"#, options: .regularExpression) {
            text = String(text[..<end.upperBound])
        }
        let codes = [
            #"\s*\([^)]*\b(?:error|code|domain)\b[^)]*\)"#,
            #"\s*\(-?\d+\)"#,
            #"\s*\bcom\.[\w.-]+"#,
            #"\s*\b[a-z]+(?:_[a-z0-9]+)+\b"#
        ]
        for pattern in codes {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.contains(where: \.isLetter) else { return nil }
        return text.count > maximumReasonLength ? String(text.prefix(maximumReasonLength)) + "…" : text
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension NativeOpenAction {
    func lineTitle(clause: String? = nil) -> String {
        switch self {
        case .openApp(let name):
            return "Open \(name)"
        case .openURL(let url, let browser):
            let place = browser.map { " in \($0)" } ?? ""
            if let query = Self.webSearchQuery(from: url.absoluteString) { return "Search for “\(query)”\(place)" }
            return "Open \(Self.displayAddress(url))\(place)"
        case .pressShortcut(let app, let shortcut):
            return recipe(for: clause, shortcut: shortcut)?.lineTitle(in: app) ?? "Press \(shortcut.displayName) in \(app)"
        case .typeText(_, let text):
            return "Type “\(NativeActionExecutor.clip(text, limit: 40))”"
        }
    }

    func lineDoneTitle(clause: String? = nil, output: String? = nil) -> String {
        switch self {
        case .openApp(let name):
            return "Opened \(output.flatMap { NativeLaunchedApp(summary: $0) }?.name ?? name)"
        case .openURL(let url, let browser):
            let place = browser.map { " in \($0)" } ?? ""
            if let query = Self.webSearchQuery(from: url.absoluteString) { return "Searched for “\(query)”\(place)" }
            return "Opened \(Self.displayAddress(url))\(place)"
        case .pressShortcut(let app, let shortcut):
            return recipe(for: clause, shortcut: shortcut)?.lineTitle(in: app) ?? "Pressed \(shortcut.displayName) in \(app)"
        case .typeText(_, let text):
            return "Typed “\(NativeActionExecutor.clip(text, limit: 40))”"
        }
    }

    private static func displayAddress(_ url: URL) -> String {
        guard var host = url.host else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return url.path.count > 1 ? host + url.path : host
    }

    private func recipe(for clause: String?, shortcut: KeyboardShortcut) -> NativeAppRecipe? {
        guard let clause else { return nil }
        return [clause, CommandLeadIn.strip(clause)]
            .compactMap { NativeAppRecipe.recipe(for: $0) }
            .first { $0.shortcut == shortcut }
    }
}

extension NativeAppRecipe {
    func lineTitle(in app: String) -> String {
        for prefix in ["create a new ", "open a new "] where description.hasPrefix(prefix) {
            return "New " + description.dropFirst(prefix.count)
        }
        if description == "quit" { return "Quit \(app)" }
        return "\(ActionLineText.capitalized(description)) in \(app)"
    }
}

extension SpeculativeLaunchResult {
    var doneLineTitle: String {
        "\(action.isActivation ? "Switched to" : "Opened") \(appName)"
    }
}

extension ActionLine {
    static func early(
        activity: SpeculativeLaunchCoordinator.Activity?, steps: [SpeculativeLaunchCoordinator.StepActivity]
    ) -> [ActionLine] {
        var lines: [ActionLine] = []
        switch activity {
        case .launching(let name):
            lines.append(ActionLine(status: .running, title: "Open \(name)"))
        case .launched(let app):
            lines.append(ActionLine(status: .done, title: "Opened \(app.name)"))
        case .failed(let name, let message):
            lines.append(ActionLine(status: .failed(reason: ActionLineText.reason(from: message)), title: "Open \(name)"))
        case nil:
            break
        }
        return lines + steps.map(ActionLine.init(stepActivity:))
    }

    init(stepActivity: SpeculativeLaunchCoordinator.StepActivity) {
        let step = stepActivity.step
        switch stepActivity {
        case .running:
            self.init(status: .running, title: step.action.lineTitle(clause: step.clause))
        case .done(let result):
            self.init(status: .done, title: step.action.lineDoneTitle(clause: step.clause, output: result.output))
        case .failed(let result):
            self.init(status: .failed(reason: result.failure.flatMap(ActionLineText.reason(from:))),
                      title: step.action.lineTitle(clause: step.clause))
        }
    }
}
