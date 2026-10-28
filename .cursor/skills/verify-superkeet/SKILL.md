---
name: verify-superkeet
description: Drive the Superkeet macOS menu-bar app through Accessibility and prove user-visible behavior. Use when verifying Superkeet UI, settings, history, setup, or recording flows.
---

# Verify Superkeet

Superkeet is a macOS menu-bar app (`LSUIElement`, bundle `com.superkeet.app`). Users touch the status-item menu, Settings, History, Setup, the recording overlay, and (on macOS 26+) the Actions HUD. There is no web UI and no first-party CLI. Drive the real `.app` with `control-superkeet`.

Never drive an instance this run did not start. Superkeet has one UserDefaults domain, one daemon socket (`~/Library/Caches/com.superkeet.app/Runtime/parakeet.sock`), and one menu-bar extra. A second copy corrupts the user's session.

## Launch

Prefer the already-installed bundle. Override it with `SUPERKEET_APP=/path/to/Superkeet.app` or `--app`. Candidates, in order: `$SUPERKEET_APP`, `/Applications/Superkeet.app`, `~/Applications/Superkeet.app`.

```bash
CONTROL=".cursor/skills/verify-superkeet/scripts/control-superkeet"
"$CONTROL" launch
```

If no bundle exists, or the proof must cover uncommitted source, build into the ignored verification directory (never over the user's installed app), then launch that exact bundle:

```bash
INSTALL_DIR="$PWD/.build/verification" CODESIGN_IDENTITY=- ./install.sh
"$CONTROL" launch --app "$PWD/.build/verification/Superkeet.app"
```

`install.sh` requires Swift, Rust/Cargo, and a protocol-1 or protocol-2 `parakeet` engine; it builds the pinned engine when none is available.

Ready when `launch` prints `launched pid=…` and `doctor` prints `doctor ok`. First-run onboarding opens a window titled `Superkeet Setup`; that is still a healthy launch. The speech model (~670 MB) lives at `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3/` and is not re-downloaded by launch.

If Superkeet is already running and `.run/state` does not own that pid, `launch` exits non-zero. Quit the foreign instance yourself, or stop. Do not `killall Superkeet`.

`swift run` is not the verify path: it is unbundled, misses TCC (Microphone / Accessibility), and still shares UserDefaults. There is no supported isolated data-directory override. Verification therefore uses the real local profile read-only where possible; never reset UserDefaults or delete history/model files to manufacture a first-run or empty state.

## Doctor

Run this first whenever anything looks off:

```bash
"$CONTROL" doctor
```

It checks: a verify-owned pid is live, no extra Superkeet processes, bundle path matches launch, the selected driver has its permissions, and (with System Events) a status extra whose AX description starts with `Superkeet` exists. It prints version and `hasCompletedOnboarding`. A foreign instance fails doctor on purpose.

If the host cannot automate System Events (common over SSH), use the installed [CuaDriver](https://github.com/trycua/cua) as the AX backend:

```bash
cua-driver permissions grant
SUPERKEET_VERIFY_DRIVER=cua "$CONTROL" launch --app "$PWD/.build/verification/Superkeet.app"
"$CONTROL" doctor
```

CuaDriver cannot enumerate an `NSStatusItem` menu. In this mode doctor prints `menu-bar extra: visual-check-required`; it does not claim the menu was verified. Window commands use CuaDriver's AX tokens. For the initial menu entry only, capture the desktop, locate Superkeet's waveform and then the desired menu title in the images, and click their **native screenshot pixel** coordinates:

```bash
"$CONTROL" desktop-screenshot --path .cursor/skills/verify-superkeet/artifacts/settings/desktop.png
"$CONTROL" desktop-click --x 2790 --y 40
"$CONTROL" desktop-screenshot --path .cursor/skills/verify-superkeet/artifacts/settings/menu.png
"$CONTROL" desktop-click --x 2920 --y 565
"$CONTROL" windows
```

Prefer the System Events exact-title path whenever available. Do not reuse the example coordinates on another display or after the menu layout changes.

## Drive

Harness: `control-superkeet`. Stable handles are menu titles, window titles, and AX names. Do not click by coordinate or tab order except for the documented CuaDriver status-item fallback and the numbered Settings sidebar rows.

```bash
"$CONTROL" menu dump
"$CONTROL" menu click "Settings..."
"$CONTROL" menu click "History"
"$CONTROL" menu click "Run Setup Again..."
"$CONTROL" windows
"$CONTROL" exists --name "General"
"$CONTROL" click --name "About"
"$CONTROL" click --row 5          # Settings sidebar: 1 General, 2 Output & Privacy, 3 Actions, 4 Advanced, 5 About
"$CONTROL" snapshot --path .cursor/skills/verify-superkeet/artifacts/<feature>/ui.ax.txt
"$CONTROL" screenshot --path .cursor/skills/verify-superkeet/artifacts/<feature>/window.png --window "Superkeet - History"
```

Exact menu titles from `MenuBarManager.swift`: `Start Recording`, `Stop Recording`, `Copy Last Transcript`, `Copy Original Transcript`, `Undo Text Changes and Copy`, `History`, `Settings...` (ASCII dots), `Run Setup Again...`, `Quit Superkeet`. When Actions Mode is on: `Start Listening for Actions` or `Run an Action…` (unicode ellipsis) or `Stop Listening`, plus `Auto-Approve Actions`. Status lines such as `Listening…` / `Recording...` / `Daemon not running` are disabled items — do not click them.

Windows:

- Settings: empty title, hidden titlebar. Identify by AX names `Superkeet`, `General`, `Output & Privacy`, `Advanced`, `About`. On macOS 26+ an `Actions` row is also present.
- History: `Superkeet - History`
- Setup: `Superkeet Setup`

Sidebar tabs in Settings (`SettingsView`): `General`, `Output & Privacy`, `Actions` (hidden below macOS 26), `Advanced`, `About`. Click the row name. `exists` and `click` walk the SwiftUI tree (the Settings window title is empty and labels sit several AX groups deep). General must show `Setup Checklist`; incomplete checks are shown by default and `Show all` reveals the rest. About must show `Version <short> (<build>)`, `On-device speech recognition`, and the privacy explanation beginning `Your audio and transcripts are processed on your Mac`.

Read the feature map under `features/` before driving. Start every recipe from the baseline there. With the CuaDriver backend, `menu dump` / `menu click` are unavailable; use the visual menu entry above, then the same `windows`, `exists`, `click`, `snapshot`, and `screenshot` commands. Features that require textual menu dumps remain unverified in CuaDriver-only mode.

## Evidence

Proof artifacts go in `.cursor/skills/verify-superkeet/artifacts/<feature>/` and survive cleanup.

Standards:

- Exercise the real menu and windows. Do not flip UserDefaults, call internal setters, or talk to the daemon socket.
- Capture the action and the resulting state: menu dump or AX snapshot plus a screenshot that shows Superkeet identity (`Superkeet` in the sidebar, `Superkeet - History`, or `Superkeet Setup`).
- Verify side effects that the user can see (window title, tab heading, empty-state copy). Do not start a recording to "prove" Settings. Do not toggle `Save History`, `Paste Automatically`, or `Launch at Login` unless the recipe says to and you restore the previous value.
- Microphone and the speech engine are production boundaries. Recording recipes may use the real mic; do not mock the engine. Do not send audio files into the UI — the user path is the menu item or shortcut.
- Shortcuts (`⌃Space` and friends) are user-configurable. Prove recording from `Start Recording` in the menu, not from a guessed hotkey.

## Cleanup

```bash
"$CONTROL" cleanup
```

Cleanup closes Superkeet windows this run opened and quits Superkeet only if `.run/state` owns the pid. It never kills by process name. It never deletes artifacts. It never writes UserDefaults or deletes `~/Library/Application Support/Superkeet/`.

If this run did not launch Superkeet, cleanup only clears stale state and leaves the user's instance alone.

## Helpers

`scripts/control-superkeet` and its CuaDriver backend `scripts/cua_superkeet.py` are executable. Invoke the backend through `control-superkeet`, not directly. From the repo root:

```bash
.cursor/skills/verify-superkeet/scripts/control-superkeet --help
.cursor/skills/verify-superkeet/scripts/control-superkeet launch
.cursor/skills/verify-superkeet/scripts/control-superkeet doctor
.cursor/skills/verify-superkeet/scripts/control-superkeet menu click "Settings..."
.cursor/skills/verify-superkeet/scripts/control-superkeet cleanup
```
