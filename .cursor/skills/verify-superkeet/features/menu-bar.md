# Menu bar

The Superkeet status item is the home surface. A user opens it to see status, start or stop recording, recover the last transcript, open History or Settings, re-run setup, and quit.

## Sub-features

- `menu-open` shows the extra and a disabled status line.
- `menu-record` offers `Start Recording` when idle, or `Stop Recording` while a take is running.
- `menu-recover` lists `Copy Last Transcript`, `Copy Original Transcript`, and `Undo Text Changes and Copy`.
- `menu-actions` shows Actions items only when Actions Mode is on.
- `menu-windows` opens History, Settings, and Setup from the menu.
- `menu-quit` quits Superkeet.

## How to get to it (user POV)

- Click the waveform (or mic / wand) extra in the menu bar.
- VoiceOver / Accessibility can activate the extra named `Superkeet`.

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` reports `menu-bar extra: yes`.
- No Settings, History, or Setup window needs to be open.

- **Open menu.** Show the extra. Run `control-superkeet menu dump`. Output includes `Start Recording` or `Stop Recording`, `History`, `Settings...`, `Run Setup Again...`, and `Quit Superkeet`.
- **Idle recording control.** With no take in progress, `Start Recording` is present and `Stop Recording` is not.
- **Recovery items.** The dump includes `Copy Last Transcript`, `Copy Original Transcript`, and `Undo Text Changes and Copy`. Disabled rows are still listed.
- **Actions items.** If the dump includes `Auto-Approve Actions`, it also includes exactly one of `Start Listening for Actions`, `Stop Listening`, or `Run an Action…`. If Actions Mode is off, none of those titles appear.
- **Status line.** The first printed title is a status such as `Listening…`, `Recording...`, `Transcribing…`, `Daemon not running`, `Hotkeys not active — grant Accessibility`, or a session status. Do not click it.
- **Proof.** Write the dump to `artifacts/menu-bar/menu.txt`. The file contains `History`, `Settings...`, and `Quit Superkeet`.

## Gotchas

- `Settings...` and `Run Setup Again...` use ASCII dots. `Run an Action…` uses a unicode ellipsis. A title mismatch fails the click.
- The extra's AX name is empty. Find it by description (`Superkeet` or `Superkeet: Ready`). It is usually menu bar 1 item 1, not menu bar 2.
- Icon tint (red / orange / blue / purple) is not an AX name. Prove state from menu titles, not from a screenshot of the extra alone.
- `Quit Superkeet` ends the verify instance. Do not choose it until cleanup.
