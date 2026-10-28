# Actions Mode

Current Actions Mode can listen for spoken commands, run native app/URL/typing operations, and use optional local MCP tools with an approval policy. Settings inspection and real action execution require separate proofs.

## Sub-features

- `actions-availability` shows Actions settings or a model-availability explanation.
- `actions-policy` displays enablement, Approval, and Keep listening between commands.
- `actions-tools` displays configured MCP servers and their connection state without starting a new connection.
- `actions-diagnostics` displays action logging, Instant App Launch, and execution limits.
- `actions-listening` shows live words and accepts multiple commands in a listening session.
- `actions-approval` honors plan and per-tool approval or denial.
- `actions-execution` produces the requested state in the intended app or tab.
- `actions-stop` stops pending work through the user controls.

## How to get to it (user POV)

- Open Settings and select Actions on a supported OS/framework build.
- Choose `Try Actions Mode…` when Actions is off, or enable Actions in Settings.
- Choose the current menu entry `Start Listening for Actions` or `Run an Action…` when enabled.
- Use the configured Run an Action or Hold to Run an Action shortcut.
- Stop through `Stop Listening`, `Stop Action`, the HUD's Stop control, or Escape as applicable.

## Driving it with control-superkeet

Preconditions:

- For inspection, complete the Settings recipe and leave recording/actions idle.
- For execution, require a disposable macOS account, known spoken input, approved permissions, the actual configured policy, and disposable target documents/tabs. Missing prerequisites block execution proof.
- Do not enable Actions or a server, reconnect/test MCP, approve work, change policy, remove a server, or clear the log during inspection. Those operations can launch processes or change persistent state.

1. Select Actions when the observed Settings sidebar contains it. Its current row is 3. Run `"$CONTROL" click --row 3`, then save `$EVIDENCE/actions.ax.txt` and `$EVIDENCE/actions.png`. Add `--surface settings` to snapshot/screenshot only under CuaDriver.
2. Assert the Actions heading or the displayed availability explanation. Tab visibility depends on OS/framework support. Apple Intelligence can still be unavailable. If Actions is absent, report the availability precondition rather than selecting another row and claiming success.
3. Inspect enablement and any visible `Approval` and `Keep listening between commands` controls. These controls depend on Actions being enabled. Record the current state; do not toggle it to expose more controls.
4. Inspect `MCP Servers`, server connection labels, `Instant App Launch`, `Keep Action Log`, and `Action Log` when shown. A server's Connected label does not prove that an action can access the intended application. Do not press Test, Reconnect, or a speech-model download control.
5. Select Advanced using the observed row order. Inspect `Actions Mode Limits` and the displayed step, timeout, and deadline values. Snapshot `$EVIDENCE/actions-advanced.ax.txt`. Do not change the limits.
6. For listening/execution, enter through the actual menu or configured shortcut in the disposable account. Capture the start action, live transcript, approval state, and actual target state after completion. An app-open test must observe the intended app/window. A typing test must observe exact text in the intended document. A search test must observe the intended query/tab, not just an audit row.
7. Test denial and stop on that same isolated path. Observe that the denied or pending mutation did not occur. Effects already delivered can remain. Do not claim rollback from a dismissed HUD.
8. The wrapper has no dedicated Actions HUD selector, speech-input generator, or configurable-shortcut sender. Mark the affected execution journeys BLOCKED until a suitable native driver and fixture exist. Do not select an empty-title HUD as Settings, bypass the UI with controller calls, or infer execution from this inspection.

## Gotchas

- Current listening sessions already exist. They stop/finalize/rearm recording takes. This is not proof of the proposed ground-up continuous-capture prototype.
- An empty-title HUD can collide with the CuaDriver Settings selector. Require Settings identity labels before inspecting controls.
- Changing auto-approval affects real desktop mutations. Preserve policy and do not enable broader approval to make a test pass.
- Model availability, microphone permission, or missing MCP tooling can block different journeys. Report the specific unmet prerequisite.
- Action logs and snapshots can contain private content. Keep them local unless reviewed for sharing.
- `DemoActionsLiveTests` uses fake action executors. Its success does not establish Notes/browser completion.
