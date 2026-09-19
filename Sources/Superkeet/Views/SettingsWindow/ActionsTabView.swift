import SwiftUI
import AppKit

struct ActionsTabView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = MCPServerConfigStore.shared
    @ObservedObject private var manager = MCPClientManager.shared

    @State private var editorRequest: MCPServerEditorRequest?
    @State private var auditEntries: [ActionAuditEntry] = []
    @State private var showingAuditLog = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "Actions",
                subtitle: "Let a spoken command plan and run tools from local MCP servers, with your approval."
            )

            Form {
                Section {
                    Toggle(isOn: $settings.actionsEnabled) {
                        rowLabel(
                            "Enable Actions Mode",
                            "Adds a Run an Action shortcut that turns speech into tool actions instead of text"
                        )
                    }
                    availabilityCard
                } header: {
                    Text("Actions Mode")
                } footer: {
                    Text("Actions Mode is separate from dictation. Normal recordings keep going straight to the clipboard.")
                }

                Section {
                    if store.servers.isEmpty {
                        Text("No MCP servers configured yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.servers) { server in
                            serverRow(server)
                        }
                    }
                    HStack {
                        Button("Add MCP Server…") {
                            editorRequest = MCPServerEditorRequest(editingID: nil, draft: MCPServerDraft())
                        }
                        if !store.servers.isEmpty {
                            Button("Reconnect All") {
                                Task { await manager.connectAllEnabled() }
                            }
                        }
                        if store.missingDefaultServerCount > 0 {
                            Button("Add Default Servers") {
                                store.addDefaultServers()
                            }
                        }
                    }
                } header: {
                    Text("MCP Servers")
                } footer: {
                    if let error = store.errorMessage {
                        Text(error).foregroundStyle(.orange)
                    }
                    Text("Superkeet launches these local processes and talks to them over standard input/output. Servers must be installed on this Mac (for example, npx or an absolute path). Some servers prompt for additional macOS permissions such as Accessibility or Screen Recording on first use.")
                    Text("Test checks the connection. Enable a server with its toggle to make its tools available to Actions Mode.")
                }

                InstantAppLaunchSettingsView()

                Section {
                    Picker(selection: $settings.actionApprovalPolicy) {
                        ForEach(ActionApprovalPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    } label: {
                        rowLabel("Approval", settings.actionApprovalPolicy.subtitle)
                    }
                    Toggle(isOn: $settings.actionAuditEnabled) {
                        rowLabel("Keep Action Log", "Record tool calls locally for review")
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Step, timeout, and deadline limits are under Advanced.")
                }

                Section {
                    DisclosureGroup("Recent Activity", isExpanded: $showingAuditLog) {
                        if auditEntries.isEmpty {
                            Text("No actions recorded yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(auditEntries.suffix(15).reversed().enumerated()), id: \.offset) { _, entry in
                                    auditRow(entry)
                                }
                            }
                            .padding(.top, 4)
                        }
                        HStack {
                            Button("Refresh") { loadAudit() }
                            Button("Reveal Log in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([ActionAuditStore.shared.logFileURL])
                            }
                            Button("Clear Log") {
                                ActionAuditStore.shared.clear()
                                loadAudit()
                            }
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Action Log")
                } footer: {
                    Text("Audit entries are stored locally at action-audit.log. Sensitive-looking argument fields are redacted.")
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $editorRequest) { request in
            MCPServerSheet(
                editingID: request.editingID,
                initialDraft: request.draft,
                onSave: { saveServer($0) }
            )
        }
        .onAppear { loadAudit() }
    }

    private func loadAudit() {
        auditEntries = ActionAuditStore.shared.entries()
    }

    @ViewBuilder
    private var availabilityCard: some View {
        let availability = AppleIntelligenceAvailability.current
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: availability.isAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(availability.isAvailable ? .green : .orange)
            Text(availability.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func serverRow(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.trimmedName)
                        .font(.system(size: 13, weight: .medium))
                    Text(server.commandSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: enabledBinding(for: server))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button(manager.state(for: server.id).isConnected ? "Reconnect" : "Test") {
                    Task { await manager.connect(server) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Edit") {
                    editorRequest = MCPServerEditorRequest(editingID: server.id, draft: MCPServerDraft(server: server))
                }
                .controlSize(.small)
                Button("Remove") {
                    Task {
                        await manager.disconnect(server.id)
                        store.remove(id: server.id)
                    }
                }
                .controlSize(.small)
            }

            connectionStatus(for: server)

            let tools = manager.tools(for: server.id)
            if !tools.isEmpty {
                DisclosureGroup("\(tools.count) tool\(tools.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tools) { tool in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                riskBadge(tool.risk)
                                Text(tool.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                if let description = tool.description, !description.isEmpty {
                                    Text(description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func connectionStatus(for server: MCPServerConfiguration) -> some View {
        switch manager.state(for: server.id) {
        case .disconnected:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func auditRow(_ entry: ActionAuditEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.timestamp, style: .time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(entry.serverName)/\(entry.toolName)")
                .font(.system(size: 11, weight: .medium))
            Text(entry.outcome)
                .font(.system(size: 10))
                .foregroundStyle(entry.outcome == "succeeded" ? .green : .orange)
            Text(entry.arguments)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func riskBadge(_ risk: ActionToolRisk) -> some View {
        Text(risk.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color(for: risk))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color(for: risk).opacity(0.12))
            .clipShape(Capsule())
    }

    private func color(for risk: ActionToolRisk) -> Color {
        switch risk {
        case .readOnly: return .green
        case .mutating: return .orange
        case .destructive: return .red
        }
    }

    private func enabledBinding(for server: MCPServerConfiguration) -> Binding<Bool> {
        Binding(
            get: { server.enabled },
            set: { store.setEnabled($0, for: server.id) }
        )
    }

    private func saveServer(_ draft: MCPServerDraft) -> String? {
        let configuration = draft.configuration
        let existing = store.servers.map { $0.id == configuration.id ? configuration : $0 }
        do {
            try MCPServerConfigStore.validate(existing)
        } catch {
            return error.localizedDescription
        }
        if draft.id == nil {
            store.add(configuration)
        } else {
            store.update(configuration)
        }
        if let message = store.errorMessage {
            store.clearError()
            return message
        }
        return nil
    }

    private func rowLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct MCPServerEditorRequest: Identifiable {
    let id = UUID()
    let editingID: UUID?
    let draft: MCPServerDraft
}

private struct MCPServerSheet: View {
    let editingID: UUID?
    let onSave: (MCPServerDraft) -> String?

    @State private var draft: MCPServerDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(editingID: UUID?, initialDraft: MCPServerDraft, onSave: @escaping (MCPServerDraft) -> String?) {
        self.editingID = editingID
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingID == nil ? "Add MCP Server" : "Edit MCP Server")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $draft.name, prompt: Text("chrome-devtools"))
                TextField("Command", text: $draft.command, prompt: Text("npx"))
                TextField("Arguments", text: $draft.argsText, prompt: Text("-y chrome-devtools-mcp@latest --autoConnect"))
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("KEY=VALUE per line", text: $draft.envText, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(size: 11, design: .monospaced))
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editingID == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.configuration.isRunnable)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        if let message = onSave(draft) {
            error = message
        } else {
            dismiss()
        }
    }
}

struct MCPServerDraft {
    var id: UUID?
    var name = ""
    var command = ""
    var argsText = ""
    var envText = ""
    var enabled = true
    var transport: MCPTransportKind = .stdio

    init() {}

    init(server: MCPServerConfiguration) {
        self.id = server.id
        self.name = server.name
        self.command = server.command
        self.argsText = server.args.joined(separator: " ")
        self.envText = server.env
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        self.enabled = server.enabled
        self.transport = server.transport
    }

    var configuration: MCPServerConfiguration {
        MCPServerConfiguration(
            id: id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            args: argsText.split(whereSeparator: \.isWhitespace).map(String.init),
            env: MCPEnvironmentParser.parse(envText),
            enabled: enabled,
            transport: transport
        )
    }
}
