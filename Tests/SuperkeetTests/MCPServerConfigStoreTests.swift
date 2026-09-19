import XCTest
@testable import Superkeet

final class InMemoryMCPSecretStore: MCPSecretStoring {
    private(set) var secrets: [String: [String: String]] = [:]

    func secretEnvironment(for name: String) -> [String: String] {
        secrets[name] ?? [:]
    }

    func setSecretEnvironment(_ environment: [String: String], for name: String) {
        secrets[name] = environment
    }

    func removeSecretEnvironment(for name: String) {
        secrets[name] = nil
    }
}

final class MCPServerConfigStoreTests: XCTestCase {

    private func makeURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-servers.json")
    }

    private func makeStore(
        fileURL: URL,
        secrets: MCPSecretStoring = InMemoryMCPSecretStore()
    ) -> MCPServerConfigStore {
        MCPServerConfigStore(fileURL: fileURL, secrets: secrets)
    }

    func testSeedsDefaultServersWhenFileMissing() {
        let store = makeStore(fileURL: makeURL())
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.servers.map(\.trimmedName).sorted(), ["chrome-devtools", "cua-driver"])
        XCTAssertTrue(store.servers.allSatisfy { !$0.enabled }, "Default servers should be disabled until enabled.")
        XCTAssertEqual(store.missingDefaultServerCount, 0)
        XCTAssertEqual(store.servers.first { $0.name == "chrome-devtools" }?.args,
                       ["-y", "chrome-devtools-mcp@latest", "--autoConnect"])
    }

    func testSaveReloadRoundTrip() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secrets = InMemoryMCPSecretStore()
        let store = makeStore(fileURL: url, secrets: secrets)
        let server = MCPServerConfiguration(
            name: "custom",
            command: "npx",
            args: ["-y", "server-files"],
            env: ["TOKEN": "value"],
            enabled: true
        )
        store.add(server)

        let reloaded = makeStore(fileURL: url, secrets: secrets)
        let loaded = reloaded.servers.first { $0.trimmedName == "custom" }
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.trimmedCommand, "npx")
        XCTAssertEqual(loaded?.args, ["-y", "server-files"])
        XCTAssertEqual(loaded?.env, ["TOKEN": "value"])
        XCTAssertEqual(loaded?.enabled, true)
        XCTAssertEqual(loaded?.transport, .stdio)
    }

    func testSensitiveEnvIsStoredOutsideTheJSONFile() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secrets = InMemoryMCPSecretStore()
        let store = makeStore(fileURL: url, secrets: secrets)
        store.add(
            MCPServerConfiguration(
                name: "custom",
                command: "npx",
                env: ["API_TOKEN": "super-secret", "LOG_LEVEL": "debug"]
            )
        )

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("super-secret"), "Secret values must not be written to disk.")
        XCTAssertTrue(contents.contains("debug"))
        XCTAssertEqual(secrets.secrets["custom"], ["API_TOKEN": "super-secret"])

        let reloaded = makeStore(fileURL: url, secrets: secrets)
        XCTAssertEqual(
            reloaded.servers.first { $0.trimmedName == "custom" }?.env,
            ["API_TOKEN": "super-secret", "LOG_LEVEL": "debug"]
        )
    }

    func testSecretsAreNotLoadedWithoutTheSecretStore() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = makeStore(fileURL: url)
        store.add(MCPServerConfiguration(name: "custom", command: "npx", env: ["TOKEN": "super-secret"]))

        let reloaded = makeStore(fileURL: url)
        XCTAssertEqual(reloaded.servers.first { $0.trimmedName == "custom" }?.env, [:])
    }

    func testRenamingServerDropsOldSecret() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secrets = InMemoryMCPSecretStore()
        let store = makeStore(fileURL: url, secrets: secrets)
        let server = MCPServerConfiguration(name: "old", command: "npx", env: ["TOKEN": "super-secret"])
        store.add(server)

        var renamed = server
        renamed.name = "new"
        store.update(renamed)

        XCTAssertNil(secrets.secrets["old"])
        XCTAssertEqual(secrets.secrets["new"], ["TOKEN": "super-secret"])
    }

    func testRemovingServerDropsItsSecret() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secrets = InMemoryMCPSecretStore()
        let store = makeStore(fileURL: url, secrets: secrets)
        let server = MCPServerConfiguration(name: "custom", command: "npx", env: ["TOKEN": "super-secret"])
        store.add(server)

        store.remove(id: server.id)
        XCTAssertNil(secrets.secrets["custom"])
    }

    func testAddDefaultServersAppendsOnlyMissing() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = makeStore(fileURL: url)
        guard let cuaDriver = store.servers.first(where: { $0.trimmedName == "cua-driver" }),
              var chrome = store.servers.first(where: { $0.trimmedName == "chrome-devtools" }) else {
            return XCTFail("Expected seeded default servers.")
        }

        store.remove(id: cuaDriver.id)
        chrome.command = "/custom/chrome"
        store.update(chrome)
        XCTAssertEqual(store.missingDefaultServerCount, 1)

        store.addDefaultServers()

        XCTAssertEqual(store.missingDefaultServerCount, 0)
        XCTAssertEqual(store.servers.map(\.trimmedName).sorted(), ["chrome-devtools", "cua-driver"])
        XCTAssertEqual(store.servers.first { $0.trimmedName == "cua-driver" }?.commandSummary, "cua-driver mcp")
        XCTAssertEqual(
            store.servers.first { $0.trimmedName == "chrome-devtools" }?.trimmedCommand,
            "/custom/chrome",
            "Existing servers must not be overwritten."
        )
    }

    func testFileUsesClaudeCompatibleShape() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = makeStore(fileURL: url)
        store.add(MCPServerConfiguration(name: "files", command: "npx", args: ["-y", "server-files"]))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        let entry = servers?["files"] as? [String: Any]
        XCTAssertEqual(entry?["command"] as? String, "npx")
        XCTAssertEqual(entry?["args"] as? [String], ["-y", "server-files"])
    }

    func testRejectsDuplicateNames() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = makeStore(fileURL: url)
        store.add(MCPServerConfiguration(name: "dup", command: "npx"))
        store.add(MCPServerConfiguration(name: "Dup", command: "npx"))

        XCTAssertEqual(store.servers.filter { $0.trimmedName.lowercased() == "dup" }.count, 1)
        XCTAssertEqual(store.errorMessage, MCPServerConfigError.duplicateName("Dup").localizedDescription)
    }

    func testValidationRejectsEmptyFields() {
        XCTAssertThrowsError(
            try MCPServerConfigStore.validate([MCPServerConfiguration(name: "", command: "npx")])
        ) { error in
            XCTAssertEqual(error as? MCPServerConfigError, .emptyName)
        }
        XCTAssertThrowsError(
            try MCPServerConfigStore.validate([MCPServerConfiguration(name: "x", command: "  ")])
        ) { error in
            XCTAssertEqual(error as? MCPServerConfigError, .emptyCommand)
        }
    }

    func testRemoveAndEnable() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = makeStore(fileURL: url)
        let server = MCPServerConfiguration(name: "browser", command: "npx")
        store.add(server)

        XCTAssertEqual(store.enabledServers.map(\.trimmedName), ["browser"])
        store.setEnabled(false, for: server.id)
        XCTAssertEqual(store.servers.first { $0.id == server.id }?.enabled, false)
        XCTAssertTrue(store.enabledServers.isEmpty)

        store.remove(id: server.id)
        XCTAssertFalse(store.servers.contains { $0.id == server.id })
    }
}
