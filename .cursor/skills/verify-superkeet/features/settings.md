# Settings

Settings lets a user inspect setup health, change appearance and shortcuts, choose output and privacy options, configure Actions Mode, and read the About page.

## Sub-features

- `settings-open` opens the Settings window from the menu.
- `settings-general` shows the General tab, usage header, and Setup Checklist.
- `settings-output` shows Output & Privacy copy and the output toggles.
- `settings-advanced` shows the Advanced tab.
- `settings-about` shows version and the privacy line.
- `settings-actions` shows the Actions tab on macOS 26+ when the OS can run Actions Mode.

## How to get to it (user POV)

- Choose `Settings...` in the Superkeet menu.
- Press `,` while the Superkeet menu is open (the menu item key equivalent).

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` is clean.
- Onboarding is completed, or the Setup window is not covering the extra.

- **Open Settings.** Choose `Settings...`. Run `control-superkeet menu click "Settings..."`. `control-superkeet exists --name "General"` exits 0. The window title is empty; the sidebar name `Superkeet` is present.
- **General.** The General tab is selected on open. Run `control-superkeet snapshot --path artifacts/settings/general.ax.txt`. The tree includes `General`, `Setup Checklist` or the check names `Microphone access`, `Speech engine`, `Speech model`, `Input device`, `Runtime directory`, and `Accessibility access`.
- **Output & Privacy.** Choose sidebar row 2. Run `control-superkeet click --row 2`. The heading `Output & Privacy` and the line `Every transcript is copied to the clipboard.` are visible. Toggles named `Remove Filler Words`, `Spoken Correction Commands`, `Paste Automatically`, and `Save History` exist. Do not flip them.
- **Advanced.** Run `control-superkeet click --row 4` (or `--row 3` when Actions is hidden). The heading `Advanced` appears.
- **About.** Sidebar rows have no AX name. Run `control-superkeet click --row 5` (General=1, Output & Privacy=2, Actions=3, Advanced=4, About=5; skip Actions and use 4/5 when that row is hidden). Then `exists --name "About"` is yes. The tree includes `Superkeet`, `Version`, and `100% Private & Offline`.
- **Actions.** After opening Settings, if five outline rows exist, click `--row 3` and confirm the Actions heading. If only four rows exist, report `settings-actions` skipped because the OS hides the tab; do not treat About as a substitute.
- **Proof.** Run `control-superkeet screenshot --path artifacts/settings/about.png` on the About tab and `control-superkeet snapshot --path artifacts/settings/about.ax.txt`. Both identify Superkeet and a `Version` string.

## Gotchas

- The Settings window has no title. `--window "Settings"` will fail. Screenshot the front Superkeet window after opening Settings, or omit `--window`.
- A saved window frame can place Settings off-screen (negative coordinates). `screenshot` moves that window on-screen before capture.
- Sidebar `click --row` must `select` the outline row. A plain AX click leaves the current tab selected.
- Clicking `Launch at Login` or any output toggle mutates the user's real defaults. Restore the previous AX value if a recipe requires a toggle.
- The Actions row is absent below macOS 26. Absence is expected, not a product bug.
- Re-opening Settings while it is already visible only fronts the existing window.
