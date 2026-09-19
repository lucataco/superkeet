import XCTest
@testable import Superkeet

@MainActor
final class MCPServerConfigMigrationTests: XCTestCase {
    private let legacyArgs = ["-y", "chrome-devtools-mcp@latest"]

    private func file(document: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("servers.json")
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        return file
    }

    private func legacyEntry(enabled: Bool = false) -> [String: Any] {
        ["command": "npx", "args": legacyArgs, "enabled": enabled]
    }

    func testMigratesOnlyDefaultArgumentsAndPreservesEnabledChoice() throws {
        for enabled in [false, true] {
            let file = try file(document: ["mcpServers": ["chrome-devtools": legacyEntry(enabled: enabled)]])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let store = MCPServerConfigStore(fileURL: file, secrets: InMemoryMCPSecretStore())
            let chrome = try XCTUnwrap(store.servers.first)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(chrome.args, legacyArgs + ["--autoConnect"])
            XCTAssertEqual(chrome.enabled, enabled)
            let persisted = try JSONDecoder().decode(MCPServersDocument.self, from: Data(contentsOf: file))
            XCTAssertEqual(persisted.mcpServers["chrome-devtools"]?.args, chrome.args)
            XCTAssertEqual(persisted.mcpServers["chrome-devtools"]?.enabled, enabled)
        }
    }

    func testMigrationIsIdempotentAndPreservesUnrelatedJSONAndSecrets() throws {
        let custom: [String: Any] = ["command": "/custom/helper", "args": ["serve"], "cwd": "/custom/work", "enabled": true]
        let file = try file(document: ["metadata": ["keep": "me"], "mcpServers": ["chrome-devtools": legacyEntry(), "custom": custom]])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let secrets = InMemoryMCPSecretStore()
        secrets.setSecretEnvironment(["API_TOKEN": "fixture-secret"], for: "custom")
        var writes = 0
        let store = MCPServerConfigStore(fileURL: file, secrets: secrets, migrationWriter: { data, url in
            writes += 1
            try data.write(to: url, options: .atomic)
        })
        let migrated = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        let entries = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(entries["custom"])), NSDictionary(dictionary: custom))
        XCTAssertEqual(root["metadata"] as? [String: String], ["keep": "me"])
        XCTAssertEqual(secrets.secrets["custom"], ["API_TOKEN": "fixture-secret"])
        XCTAssertFalse(String(data: migrated, encoding: .utf8)?.contains("fixture-secret") == true)
        store.load()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try Data(contentsOf: file), migrated)
        XCTAssertEqual(store.servers.first { $0.name == "chrome-devtools" }?.args.filter { $0 == "--autoConnect" }.count, 1)
    }

    func testCustomizedDefaultEntriesAreNotRewritten() throws {
        let changes: [[String: Any]] = [
            ["command": "/custom/bin/npx"],
            ["args": legacyArgs + ["--channel", "canary"]],
            ["args": legacyArgs + ["--browserUrl=http://localhost:9222"]],
            ["args": legacyArgs + ["--autoConnect=false"]],
            ["args": legacyArgs + ["--autoConnect"]],
            ["args": ["chrome-devtools-mcp@latest", "-y"]],
            ["args": ["-y", "chrome-devtools-mcp@0.1.0"]],
            ["env": ["CHROME_PROFILE": "Work"]],
            ["cwd": "/custom/work"],
            ["transport": "http"]
        ]
        for change in changes {
            let entry = legacyEntry().merging(change) { _, new in new }
            let file = try file(document: ["mcpServers": ["chrome-devtools": entry]])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let original = try Data(contentsOf: file)
            let store = MCPServerConfigStore(fileURL: file, secrets: InMemoryMCPSecretStore(), migrationWriter: { _, _ in
                XCTFail("Customized entry must not migrate: \(change)")
            })
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.servers.first?.args, entry["args"] as? [String])
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testRenamedAndMissingDefaultsAreNotAddedOrMigrated() throws {
        for name in ["Chrome_DevTools", "chrome-devtools-work", "custom"] {
            let file = try file(document: ["mcpServers": [name: legacyEntry()]])
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let original = try Data(contentsOf: file)
            let store = MCPServerConfigStore(fileURL: file, secrets: InMemoryMCPSecretStore())
            XCTAssertEqual(store.servers.map(\.name), [name])
            XCTAssertEqual(store.servers.first?.args, legacyArgs)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testSecretEnvironmentCountsAsCustomization() throws {
        let file = try file(document: ["mcpServers": ["chrome-devtools": legacyEntry()]])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try Data(contentsOf: file)
        let secrets = InMemoryMCPSecretStore()
        secrets.setSecretEnvironment(["API_TOKEN": "fixture-secret"], for: "chrome-devtools")
        let store = MCPServerConfigStore(fileURL: file, secrets: secrets)
        XCTAssertEqual(store.servers.first?.args, legacyArgs)
        XCTAssertEqual(store.servers.first?.env, ["API_TOKEN": "fixture-secret"])
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(secrets.secrets["chrome-devtools"], ["API_TOKEN": "fixture-secret"])
    }

    func testMigrationWriteFailureRetainsLoadedConfigurationAndOriginalFile() throws {
        let file = try file(document: ["mcpServers": ["chrome-devtools": legacyEntry(enabled: true)]])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try Data(contentsOf: file)
        let store = MCPServerConfigStore(fileURL: file, secrets: InMemoryMCPSecretStore(), migrationWriter: { _, _ in
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Write refused"])
        })
        XCTAssertTrue(store.errorMessage?.contains("Write refused") == true)
        XCTAssertEqual(store.servers.first?.args, legacyArgs)
        XCTAssertEqual(store.servers.first?.enabled, true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
