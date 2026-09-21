---
name: verify-superkeet
description: Drive the Superkeet macOS menu-bar app through Accessibility and prove user-visible behavior. Use when verifying Superkeet UI, settings, history, setup, or recording flows.
---

# Verify Superkeet

Superkeet is a macOS menu-bar app (`LSUIElement`, bundle `com.superkeet.app`). Users touch the status-item menu, Settings, History, Setup, the recording overlay, and (on macOS 26+) the Actions HUD. There is no web UI and no first-party CLI. Drive the real `.app` with `control-superkeet`.

Never drive an instance this run did not start. Superkeet has one UserDefaults domain, one daemon socket (`~/Library/Caches/com.superkeet.app/Runtime/parakeet.sock`), and one menu-bar extra. A second copy corrupts the user's session.

## Launch

Prefer the already-installed bundle. Do not run `./install.sh` as part of a verify run — that overwrites the user's app.

```bash
CONTROL=".cursor/skills/verify-superkeet/scripts/control-superkeet"
"$CONTROL" launch
```

Override the bundle with `SUPERKEET_APP=/path/to/Superkeet.app` or `--app`. Candidates, in order: `$SUPERKEET_APP`, `/Applications/Superkeet.app`, `~/Applications/Superkeet.app`.

Ready when `launch` prints `launched pid=…` and `doctor` prints `doctor ok`. First-run onboarding opens a window titled `Superkeet Setup`; that is still a healthy launch. The speech model (~670 MB) lives at `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3/` and is not re-downloaded by launch.

If Superkeet is already running and `.run/state` does not own that pid, `launch` exits non-zero. Quit the foreign instance yourself, or stop. Do not `killall Superkeet`.

To verify uncommitted source changes, the operator installs a current bundle first (`./install.sh`), then this skill launches that bundle. `swift run` is not the verify path: it is unbundled, misses TCC (Microphone / Accessibility), and still shares UserDefaults.

## Doctor

Run this first whenever anything looks off:

```bash
"$CONTROL" doctor
```

It checks: a verify-owned pid is live, no extra Superkeet processes, bundle path matches launch, System Events can see the process, and a status extra whose AX description starts with `Superkeet` exists (usually menu bar 1 on this LSUIElement). It prints version and `hasCompletedOnboarding`. A foreign instance fails doctor on purpose.

## Drive

Harness: `control-superkeet`. Stable handles are menu titles, window titles, and AX names. Do not click by coordinate or tab order.

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

Sidebar tabs in Settings (`SettingsView`): `General`, `Output & Privacy`, `Actions` (hidden below macOS 26), `Advanced`, `About`. Click the row name. `exists` and `click` walk the SwiftUI tree (the Settings window title is empty and labels sit several AX groups deep). General must show `Setup Checklist` items `Microphone access`, `Speech engine`, `Speech model`, `Input device`, `Runtime directory`, `Accessibility access`. About must show `Version <short> (<build>)` and `100% Private & Offline`.

Read the feature map under `features/` before driving. Start every recipe from the baseline there.

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

`scripts/control-superkeet` is executable. From the repo root:

```bash
.cursor/skills/verify-superkeet/scripts/control-superkeet --help
.cursor/skills/verify-superkeet/scripts/control-superkeet launch
.cursor/skills/verify-superkeet/scripts/control-superkeet doctor
.cursor/skills/verify-superkeet/scripts/control-superkeet menu click "Settings..."
.cursor/skills/verify-superkeet/scripts/control-superkeet cleanup
```
