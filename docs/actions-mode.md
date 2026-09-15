# Actions Mode

Actions Mode turns a spoken command into tool actions instead of text. You speak
a task, Superkeet plans it with an on-device model, calls tools from local MCP
servers, and asks for your approval before anything changes the computer.

Actions Mode is **off by default** and completely separate from dictation. A
normal recording still goes straight to the clipboard.

## Requirements

| Requirement | Why |
|---|---|
| macOS 26 | Provides the on-device Foundation Models framework |
| Apple Intelligence enabled | Supplies the on-device language model that plans tool calls |
| At least one MCP server installed | Provides the tools the plan can call |

If Apple Intelligence is unavailable, the Actions settings tab and onboarding
step explain the issue and the rest of the app continues to work normally.

## How it works

```text
Command Mode hotkey (default ⌥⇧Space)
    └── Speech → Parakeet (local, unchanged)
            └── AgentSessionController
                    ├── MCPClientManager   → local MCP server processes (stdio)
                    ├── On-device model    → plans tool calls
                    ├── ActionApprovalController → approve / deny each call
                    └── ActionAuditStore   → local, redacted log
```

1. Press the **Command Mode** shortcut and speak a task (for example, “open the
   pricing page and summarize it”).
2. Superkeet transcribes locally, then plans with the on-device model.
3. Each tool call is classified as read-only, mutating, or destructive and, by
   default, shown in a floating HUD for approval. A compact HUD stays at the top
   while the action runs so you can see it is still working, and it shows the
   result when the action finishes.
4. Approved calls run against the MCP server; results are truncated and fed back
   to the model until the task is done.
5. Press **Escape** at any time to stop an action.

## Configuring MCP servers

Servers are configured in **Settings ▸ Actions**. The on-disk file is
Claude/Cursor compatible:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest"]
    }
  }
}
```

Stored at `~/Library/Application Support/Superkeet/mcp-servers.json` with
restricted permissions.

### Default servers

Superkeet seeds two servers the first time it runs (both **disabled** until you
enable them, so nothing launches unexpectedly):

| Server | Command | Purpose |
|---|---|---|
| `chrome-devtools` | `npx -y chrome-devtools-mcp@latest` | Drive and inspect Chrome |
| `open-computer-use` | `open-computer-use mcp` | Control macOS apps via the accessibility tree |

If you remove one, use **Add Default Servers** in Settings ▸ Actions to restore
it. Enabling a server makes Superkeet launch and connect to it whenever an action
runs. Chrome DevTools starts a Chrome instance, and computer use needs Screen
Recording and Accessibility access, so leave them off until you need them.

Notes:

- Servers are **user-installed**. Superkeet launches the command you provide as
  a local child process and talks to it over standard input/output.
- Superkeet resolves the login shell `PATH` (so `npx`/`uvx` installed via
  Homebrew work from the GUI app). You can always use an absolute command path.
- Environment variables can be set per server in the edit sheet, one `KEY=VALUE`
  per line.

## Permissions

- Superkeet already needs **Microphone** and **Accessibility**.
- Some MCP servers request their own macOS permissions on first use, such as
  **Screen Recording** (screenshot/automation servers) or **Accessibility**
  (computer-use servers). macOS attributes these to the server process, so you
  may see a separate prompt.

## Safety model

| Control | Default |
|---|---|
| Approval | **Only Ask Before Changes** — read-only tools run automatically; anything that changes state is confirmed |
| Optional | **Ask Before Every Tool** confirms even read-only tools |
| Risk source | MCP tool annotations (`readOnlyHint`, `destructiveHint`), with a conservative name fallback for observation tools (`list_apps`, `get_app_state`, `list_pages`, `take_snapshot`, …) |
| Step budget | 12 tool calls per command |
| Per-tool timeout | 120 seconds |
| Tool result size | 4,000 characters in the audit log, 800 characters fed back to the model |
| Tool count | Up to 40 tools per plan, further limited to what fits the model context |
| Argument size | Up to 64 KB per call |
| URL arguments | Bare domains (for example `youtube.com`) are upgraded to `https://` before a tool runs |
| Browser choice | Naming a browser other than Chrome withholds the Chrome DevTools tools so the named browser is used |
| Audit log | On (`action-audit.log`), arguments and details redacted |

A tool with `readOnlyHint: true` is treated as read-only, as is an observation-style
tool that declares no behavior hints (for example `list_apps` or `get_app_state`).
A `destructiveHint: true` marks a tool destructive; anything that actually changes
state is mutating. An explicit `readOnlyHint: false` always wins over the name
fallback. Approvals show a concise intent (for example, `Run: open -a Helium`) with
full arguments behind **Details**.

## Privacy

- Planning runs **entirely on-device** through Apple Intelligence. Prompts and
  tool results are not sent to a cloud model.
- The audit log lives at
  `~/Library/Application Support/Superkeet/action-audit.log` and redacts
  sensitive-looking argument keys (tokens, passwords, secrets, authorization,
  cookies, and similar) plus bearer/key-value secrets in tool output.

## Known limitations

- **No vision.** The on-device model accepts text only, so it cannot consume
  screenshots. Computer-use servers work only through their accessibility/element
  tree tools, not pixel-based vision.
- **Context window.** The on-device model has a small (4,096-token) context.
  Superkeet measures the real cost of each tool definition and only keeps the
  task-relevant subset that fits, round-robining across enabled servers so each
  one is represented. Tool results are trimmed to 800 characters for the model,
  and if a plan still overflows before running any tool, Superkeet retries with
  a smaller tool set. If it cannot fit, it explains the overflow and suggests a
  narrower request or fewer enabled servers.
- **macOS 26 only.** Actions Mode is unavailable on earlier macOS versions.
- **User-installed tooling.** Superkeet does not bundle Node, Python, or MCP
  servers.
- **Not sandboxed.** The app spawns local processes, so Actions Mode is not
  compatible with a Mac App Store sandbox.

## Troubleshooting

| Symptom | Check |
|---|---|
| “Could not find 'npx'” | Install Node (or use an absolute command path) |
| Server stays “Not connected” | Run **Test** in Settings ▸ Actions and read the error excerpt |
| Action says it needs macOS 26 | Update macOS and enable Apple Intelligence |
| “No MCP tools are available” | Add and enable a server, then **Reconnect All** |
| Tool call is denied | Approve the HUD, or change the approval policy |
