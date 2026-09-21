import Foundation

enum DevelopmentEngineSelection: Equatable {
    case executable(URL)
    case source(URL, needsClone: Bool)

    var binaryURL: URL {
        switch self {
        case .executable(let url): return url
        case .source(let url, _): return url.appendingPathComponent("target/release/parakeet")
        }
    }
}

enum DevelopmentEngineLocator {
    static let repositoryURL = "https://github.com/lucataco/parakeet-cli.git"
    static let repositoryRef = "v0.1.8"

    static func select(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        systemSearchPaths: [String] = ["/opt/homebrew/bin/parakeet", "/usr/local/bin/parakeet"],
        fileManager: FileManager = .default
    ) throws -> DevelopmentEngineSelection {
        func url(_ path: String) -> URL {
            let expanded = path == "~" || path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL
        }
        func sourceSelection(_ directory: URL) -> DevelopmentEngineSelection? {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Cargo.toml").path) {
                return .source(URL(fileURLWithPath: directory.path, isDirectory: true), needsClone: false)
            }
            for profile in ["release", "debug"] {
                let binary = directory.appendingPathComponent("target/\(profile)/parakeet")
                if fileManager.isExecutableFile(atPath: binary.path) { return .executable(binary) }
            }
            return nil
        }

        for key in ["PARAKEET_BINARY_PATH", "PARAKEET_CLI_PATH"] {
            if let path = environment[key], !path.isEmpty {
                let binary = url(path)
                guard fileManager.isExecutableFile(atPath: binary.path) else {
                    throw DevelopmentParakeetBootstrapError.message("\(key) points to a missing or non-executable engine: \(binary.path)")
                }
                return .executable(binary)
            }
        }
        if let path = environment["PARAKEET_SOURCE_DIR"], !path.isEmpty {
            let directory = url(path)
            guard let selection = sourceSelection(directory) else {
                throw DevelopmentParakeetBootstrapError.message("PARAKEET_SOURCE_DIR contains neither Cargo.toml nor a built engine: \(directory.path)")
            }
            return selection
        }

        let checkout = URL(fileURLWithPath: url(".build/parakeet-cli-\(repositoryRef)").path, isDirectory: true)
        for directory in [url("../../Formulae/parakeet-cli"), checkout, url(".build/parakeet-cli"),
                          url("../parakeet-cli"), url("\(homeDirectory)/Code/CLIs/parakeet-cli")] {
            if let selection = sourceSelection(directory) { return selection }
        }
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/parakeet" }
        for path in ["\(homeDirectory)/.cargo/bin/parakeet"] + systemSearchPaths + pathCandidates {
            let binary = url(path)
            if fileManager.isExecutableFile(atPath: binary.path) { return .executable(binary) }
        }
        return .source(checkout, needsClone: true)
    }
}
