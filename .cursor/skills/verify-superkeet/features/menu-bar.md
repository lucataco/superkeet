# Menu bar

The Superkeet status item exposes recording, transcript recovery, Actions Mode, History, Settings, Setup, and Quit.

## Sub-features

- `menu-open` exposes the menu and current status.
- `menu-permissions` offers Accessibility setup when shortcuts are unavailable.
- `menu-record` switches between recording start, pending-start cancellation, and stop controls.
- `menu-recover` exposes transcript copy and recovery actions.
- `menu-actions` exposes current Actions entry and stop controls.
- `menu-windows` opens History, Settings, and Setup.
- `menu-quit` exits the owned app through its menu.

## How to get to it (user POV)

- Click the Superkeet waveform, microphone, or working icon in the menu bar.
- Activate the status item through Accessibility.

## Driving it with control-superkeet

Preconditions:

- Complete Launch and Doctor. Wait for the actual status item to appear before selecting coordinates.
- System Events must have AppleEvent and Accessibility access for textual menu enumeration.

1. Under System Events, run `"$CONTROL" menu dump > "$EVIDENCE/menu.txt"`. Assert `History`, `Settings...`, `Run Setup Again...`, and `Quit Superkeet`. Under CuaDriver, use the fresh desktop screenshot and click procedure, saving `$EVIDENCE/menu.png` and the click output. That proves only the visual entry.
2. When idle, expect `Start Recording`. During recording, expect `Stop Recording`. During a pending start, expect `Cancel Starting Recording`. Do not change recording state during this inspection.
3. Inspect the disabled status line. It can report `Shortcuts are off. Turn on Accessibility.`, `Recording…`, `Listening…`, or transcription/action progress. Do not click a status row.
4. Inspect recovery entries. `Copy Last Transcript`, `Copy Original Transcript`, and `Undo Text Changes and Copy` can be disabled. Their presence does not prove clipboard behavior.
5. When Actions is enabled, inspect `Auto-Approve Actions` and the state-dependent entry `Start Listening for Actions`, `Stop Listening`, or `Run an Action…`. Supported systems can show `Try Actions Mode…` when Actions is off. Do not toggle the approval policy during inspection.
6. Use the corresponding feature recipe for each window entry. Save its menu action and resulting window evidence.
7. For a user-menu quit proof, choose `Quit Superkeet` only at the end of the run. System Events uses `"$CONTROL" menu click "Quit Superkeet"`. CuaDriver uses its observed menu row. Confirm the recorded app and engine exit, then run cleanup to clear stale ownership state. Signal-based cleanup alone does not prove menu quit.

## Gotchas

- `Settings...` and `Run Setup Again...` use ASCII dots. Actions titles can use the Unicode ellipsis.
- CuaDriver cannot provide a textual status-item menu dump. Mark that entry point unverified instead of substituting a screenshot for the textual recipe.
- The status icon may appear after launch returns. Observe it before clicking.
- Recovery actions can change the clipboard. Use a disposable known transcript before testing their effect.
- Icon color alone does not prove a recording or action state. Capture the relevant menu text or HUD as well.
