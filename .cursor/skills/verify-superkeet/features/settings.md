# Settings

Settings lets a user inspect setup health, change appearance, shortcuts, and the microphone, choose output and privacy options, configure Actions Mode, troubleshoot the speech engine, and read the About page.

## Sub-features

- `settings-open` opens the Settings window from the menu.
- `settings-general` shows the General tab, usage header, Setup Checklist, Shortcuts, and the Microphone picker.
- `settings-output` shows Output & Privacy copy and the output toggles.
- `settings-advanced` shows the Advanced tab, ending with the Troubleshooting section.
- `settings-about` shows version and the privacy line.
- `settings-actions` shows the Actions tab on macOS 26+ when the OS can run Actions Mode.

## How to get to it (user POV)

- Choose `Settings...` in the Superkeet menu.
- Press `,` while the Superkeet menu is open (the menu item key equivalent).

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` is clean.
- Onboarding is completed, or the Setup window is not covering the extra.

- **Open Settings (System Events).** Choose `Settings...`. Run `control-superkeet menu click "Settings..."`. `control-superkeet exists --name "General"` exits 0. The window title is empty; the sidebar name `Superkeet` is present.
- **Open Settings (CuaDriver fallback).** Run `control-superkeet desktop-screenshot --path artifacts/settings/desktop.png`, locate the waveform, and use `desktop-click --x N --y N` in native screenshot pixels. Capture `artifacts/settings/menu.png` the same way, locate `Settings...`, and click it. Then `control-superkeet exists --name "General"` must exit 0. The example coordinates in `SKILL.md` are not reusable proof.
- **General.** The General tab is selected on open. Run `control-superkeet snapshot --surface settings --path artifacts/settings/general.ax.txt`. The tree includes `General` and `Setup Checklist`. Incomplete checks are visible by default; choose `Show all` before expecting all of `Microphone access`, `Speech engine`, `Speech model`, `Input device`, `Runtime directory`, and `Accessibility access`.
- **Microphone (General).** The `Microphone` heading sits after `Shortcuts`. It holds the `Microphone` pop-up (value `System Default` unless the operator chose a device) and `Refresh Devices`. Opening the pop-up is safe; press Escape to close it. Do not choose a different device.
- **Output & Privacy.** Choose sidebar row 2. Run `control-superkeet click --row 2`. The heading `Output & Privacy` and the line `Every transcript is copied to the clipboard.` are visible. Toggles named `Remove Filler Words`, `Spoken Correction Commands`, `Paste Automatically`, and `Save History` exist. Do not flip them.
- **Advanced.** Run `control-superkeet click --row 4` (or `--row 3` when Actions is hidden). The heading `Advanced` appears.
- **Diagnostic details (CuaDriver).** Run `control-superkeet expand --name "Diagnostic details"`. It prints `expanded Diagnostic details in window …` or `Diagnostic details already expanded in window …`. Then `control-superkeet snapshot --surface settings --path artifacts/settings/advanced-diagnostics.ax.txt` contains `Status:`. The system-events driver has no `expand`. See SKILL.md, Disclosures. `Audio Input` is not on this tab. The last section is `Troubleshooting`, with `Refresh`, `Copy Diagnostics`, `Export Logs…`, and `Restart Speech Engine` (or `Start Speech Engine` when the engine is stopped). Confirm the buttons exist; do not press them unless the recipe is about the engine.
- **About.** Sidebar rows have no AX name. Run `control-superkeet click --row 5` (General=1, Output & Privacy=2, Actions=3, Advanced=4, About=5; skip Actions and use 4/5 when that row is hidden). Then `exists --name "About"` is yes. The tree includes `Superkeet`, `Version`, `On-device speech recognition`, and `Your audio and transcripts are processed on your Mac`.
- **Actions.** After opening Settings, if five outline rows exist, click `--row 3` and confirm the Actions heading. If only four rows exist, report `settings-actions` skipped because the OS hides the tab; do not treat About as a substitute.
- **Proof.** Run `control-superkeet screenshot --surface settings --path artifacts/settings/about.png` on the About tab and `control-superkeet snapshot --surface settings --path artifacts/settings/about.ax.txt`. Both identify Superkeet and a `Version` string. Keep the menu-entry image/action output alongside them so the proof includes the user action as well as the resulting tab.

## Gotchas

- The Settings window has no title. `--window "Settings"` will fail. Use `--surface settings`.
- A saved window frame can place Settings off-screen (negative coordinates). With System Events, `screenshot` moves that window on-screen before capture. CuaDriver ignores offscreen windows, so `windows` shows `on_screen=False` and the surface lookup fails. Report it if the window stays off-screen.
- Sidebar `click --row` must `select` the outline row. A plain AX click leaves the current tab selected.
- Clicking `Launch at Login` or any output toggle mutates the user's real defaults. Restore the previous AX value if a recipe requires a toggle.
- The Actions row is absent below macOS 26. Absence is expected, not a product bug.
- CuaDriver cannot enumerate the status-item menu. Its desktop-click coordinates are only the menu-entry fallback and must come from fresh native screenshots; all sidebar changes still use AX row tokens. `expand` is the only other pixel click, and it is a foreground click.
- Re-opening Settings while it is already visible only fronts the existing window.
- To see sections below the fold under CuaDriver, scroll the Form with `cua-driver call scroll '{"pid":N,"direction":"down","amount":6,"by":"line","x":500,"y":420}'`, then take a fresh screenshot.
- Form footers render right-aligned in source builds on this host, including an unchanged `origin/main` build. The released 1.9.3 zip renders them left-aligned. Compare against a same-toolchain build before reporting it.
