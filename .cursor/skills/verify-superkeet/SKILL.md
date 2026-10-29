---
name: verify-superkeet
description: Launch and drive Superkeet's native macOS menu-bar app through Accessibility, capture UI evidence, and clean up owned processes. Use for Settings, History, Setup, recording, and current Actions Mode verification.
---

# Verify Superkeet

Use the existing `control-superkeet` helper. Superkeet is an AppKit/SwiftUI menu-bar app, not a browser app. Its speech engine is a child CLI, not a substitute for driving the user interface.

Read [the feature map](features/README.md) before selecting a journey. The proposed continuous Actions prototype is not implemented by this skill. Pi discovers the same files through `.pi/skills/verify-superkeet`, a symlink to this directory. Use `/reload` after changes, then `/skill:verify-superkeet`.

## Launch

Run from the repository root in one shell. Use a fresh ownership directory for every run.

```bash
export PATH="$HOME/.local/bin:$PATH"
CONTROL="$PWD/.cursor/skills/verify-superkeet/scripts/control-superkeet"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
export SUPERKEET_VERIFY_STATE_DIR="$PWD/.cursor/skills/verify-superkeet/.run/$RUN_ID"
export SUPERKEET_VERIFY_ARTIFACTS="$PWD/.cursor/skills/verify-superkeet/artifacts/$RUN_ID"
EVIDENCE="$SUPERKEET_VERIFY_ARTIFACTS"
mkdir -p "$EVIDENCE"
```

Check `pgrep -x Superkeet` and `pgrep -x parakeet` before building or launching. If either finds an existing app or engine, stop and identify its owner. Do not stop a foreign process, reuse another run's state directory, or launch two verification runs on one desktop.

There is no supported disposable-profile override. Worktrees still share the defaults domain `com.superkeet.app`, runtime socket, model, history, and MCP configuration. Use a disposable macOS account for recording, Actions execution, onboarding completion, or settings changes. On an established profile, limit this skill to inspection and window navigation.

Launch itself is not mutation-free. It may update app storage, start the daemon, prewarm microphone input, and connect enabled MCP servers. An installed model is reused. A missing model may download automatically, including while Setup is open. If those startup effects are unacceptable, stop before launch.

For source verification, build a separate bundle rather than overwrite the installed application.

```bash
INSTALL_DIR="$PWD/.build/verification" CODESIGN_IDENTITY=- ./install.sh > "$EVIDENCE/build.log" 2>&1 || exit 1
APP="$PWD/.build/verification/Superkeet.app"
codesign --verify --deep --strict "$APP" || exit 1
git rev-parse HEAD > "$EVIDENCE/source-sha.txt"
shasum -a 256 "$APP/Contents/MacOS/Superkeet" "$APP/Contents/Resources/bin/parakeet" > "$EVIDENCE/binary-sha256.txt"
```

`install.sh` builds release Swift code and builds a local or pinned Parakeet engine when needed. It requires Xcode command-line tools and Rust/Cargo for an engine source build. `PARAKEET_CLI_PATH` can select an existing engine, but record its hash and do not assume it matches a checkout. The app accepts engine protocols 1 and 2. The script assembles a temporary `Superkeet.app` in the checkout before copying it to `INSTALL_DIR`.

Ad-hoc signing avoids requiring an unlocked signing key. It can require fresh Microphone or Accessibility permission for the test app. Never reset TCC or change grants automatically. To verify an installed release instead, set `APP` to that exact existing bundle and record its version and hashes. That does not verify the current source.

### Select a desktop driver

For System Events, use this read-only preflight. A denied AppleEvent is a blocker, not an empty UI tree.

```bash
export SUPERKEET_VERIFY_DRIVER=system-events
osascript -e 'tell application "System Events" to get UI elements enabled'
```

Alternatively, use an installed CuaDriver with its own Accessibility and Screen Recording grants.

```bash
export SUPERKEET_VERIFY_DRIVER=cua
cua-driver permissions status --json > "$EVIDENCE/driver-permissions.json"
```

If CuaDriver is not running, `status` reports unknown. Start it with `open -a CuaDriver --args serve` only after confirming there is no existing driver process. Recheck permission status until it reports the daemon's identity, or stop after ten seconds. Record its PID, executable, and start time if this run started it. Do not run `permissions grant` unattended. Missing grants require the operator.

CuaDriver cannot enumerate Superkeet's status-item menu. Its menu entry requires fresh screenshot coordinates. All later window interactions use AX handles. Never reuse coordinates from an earlier run.

### Start the owned app

```bash
"$CONTROL" launch --app "$APP" > "$EVIDENCE/launch.txt" 2>&1
"$CONTROL" doctor > "$EVIDENCE/doctor.txt" 2>&1
```

`launched pid=` proves process launch only. `doctor ok` proves the checks below, not microphone readiness, model availability, or a usable Settings window. Wait for the journey's actual window and labels before driving it.

A fresh macOS profile opens `Superkeet Setup`. Follow the first-run branch of [Setup](features/setup.md) in that disposable account, grant required permissions through the operator, choose the intended output behavior, and wait for the model/setup checks needed by the journey. Closing the initial Setup window skips onboarding, persists completion, and starts services. It is not a harmless cancellation. No application login is required. Do not reset an established profile to manufacture this state. A proof using an existing profile does not verify fresh-profile provisioning.

On any failed attempt, run Cleanup before retrying. Preserve that attempt's evidence and use a new run ID for the retry.

## Doctor

Run this read-only check whenever a drive behaves unexpectedly.

```bash
"$CONTROL" doctor
```

It checks the recorded PID is live, rejects extra Superkeet processes, compares the bundle path when LaunchServices supplies one, and checks the selected driver. It prints the bundle version and onboarding flag. System Events also locates the status item. CuaDriver reports `visual-check-required` instead.

The helper's launch and drive paths do not validate executable/start-time identity as strictly as cleanup. Use a fresh state directory and compare the current PID's executable and start time with `EXEC` and `START` in this run's state before driving after a failure. Stop on a mismatch. Do not treat a live reused PID as ownership.

For build provenance, compare the bundle version with `Resources/Info.plist` and use the saved executable hashes. The version alone cannot identify an uncommitted build.

## Drive

Readiness is specific to the journey. In CuaDriver mode, opening Settings can return before the window exists. After clicking the real menu item, wait for the expected AX label with a bounded check.

```bash
for attempt in $(seq 1 20); do
    "$CONTROL" exists --surface settings --name General > "$EVIDENCE/settings-ready.txt" 2>&1 && break
    sleep 0.5
done
"$CONTROL" exists --surface settings --name General
```

The final check must pass. This limits retry count, not elapsed time. Each CuaDriver tool call has a 45-second timeout, and one observation can make several calls. On a stalled driver, abort the attempt and clean up instead of waiting through every retry. Otherwise save `windows`, capture the desktop, clean up, and report the failed readiness check. Do not replace the check with a fixed delay or accept an empty snapshot.

### Use the commands supported by the selected driver

| Operation | System Events | CuaDriver |
|---|---|---|
| Open menu or select its exact title | `menu dump`, `menu click "Settings..."` | `desktop-screenshot`, then `desktop-click` from that fresh image |
| List windows | `windows` | `windows` |
| Find a label | `exists --name General` | `exists --surface settings --name General` |
| Select Settings row | `click --row 1` | `click --surface settings --row 1` |
| Save AX tree | `snapshot --path "$EVIDENCE/general.ax.txt"` | `snapshot --surface settings --path "$EVIDENCE/general.ax.txt"` |
| Capture Settings | `screenshot --path "$EVIDENCE/general.png"` | `screenshot --surface settings --path "$EVIDENCE/general.png"` |
| Close named window | `close-window --title "Superkeet - History"` | `close-window --window "Superkeet - History"` |
| Expand diagnostic disclosure | Not supported | `expand --name "Diagnostic details"` |

System Events `exists` and named `click` search all app windows. Its snapshot includes all app windows. None accepts `--surface`. Row clicking targets window 1. Keep only the intended window open so a label in another window cannot satisfy readiness or receive a click. Its screenshot command accepts `--window`, but falls back to the first window if the title is absent. Verify the window identity in the image. Its `close-window` accepts `--title`.

CuaDriver accepts `--surface settings`, `--surface history`, `--surface setup`, or an exact `--window` title. Settings has an empty title. Without a selector, it chooses the largest on-screen window. This does not exclude every overlay or HUD. Avoid driving Settings during recording or Actions execution, and require Settings labels in the snapshot.

### Enter Settings through the real menu

With System Events, use `"$CONTROL" menu click "Settings..."`.

With CuaDriver, capture the desktop and locate the Superkeet waveform in the original PNG. Set shell variables `X` and `Y` to that observed center in native pixels, then run the click below. Capture the opened menu as `$EVIDENCE/menu.png`, observe the `Settings...` row, and repeat with its newly observed coordinates. Save the two click outputs separately. Never fill those variables from an old screenshot.

```bash
"$CONTROL" desktop-screenshot --path "$EVIDENCE/desktop.png"
"$CONTROL" desktop-click --x "$X" --y "$Y" > "$EVIDENCE/open-menu.json"
"$CONTROL" desktop-screenshot --path "$EVIDENCE/menu.png"
```

If the image viewer downscales the PNG, convert displayed coordinates back to native pixels before clicking. Re-capture if the menu moved. A click returning `effect: unverifiable` needs the resulting UI observation before it counts as success. After selecting Settings, run the bounded readiness check above and save `"$CONTROL" windows > "$EVIDENCE/windows.txt"`.

Use the exact Settings row order observed in the current AX tree. When Actions is present, rows are General 1, Output & Privacy 2, Actions 3, Advanced 4, About 5. When Actions is absent, Advanced is 3 and About is 4. Reopening Settings preserves an existing selection, so select General explicitly rather than assuming it.

`Settings...` and `Run Setup Again...` use ASCII dots. Other menu labels may use the Unicode ellipsis. Copy the actual source/UI label when calling `menu click`.

The helper has no generic text-entry, clipboard assertion, configurable-shortcut sender, or dedicated Actions HUD selector. Feature recipes mark those journeys as blocked when the required driver capability or fixture is absent. A Settings inspection is not proof of recording or action execution.

For CuaDriver's `Diagnostic details` disclosure, use `expand` only after selecting Advanced. It validates nearby AX labels and geometry, performs a foreground click, then reads back `Status:` or `Diagnostics:`. This is a guarded layout-derived click, not a native AX disclosure action. Report failure if the layout no longer matches.

## Evidence

Write every artifact under `$EVIDENCE`, which is outside the ownership-state directory and survives cleanup. Never use a bare `artifacts/` path from the repository root.

Capture the actual entry action and resulting state. A Settings proof needs the menu/click evidence, General and About AX snapshots, and identity-bearing window screenshots. Verify About's version against the launched bundle. Observe a changed tab or opened window rather than trusting the click response.

For mutations, verify the real side effect as well as visible status. Recording needs the intended transcript on the clipboard or in History. Actions need the target app/document/tab state. A posted keystroke, audit success row, or successful model response is insufficient. Do not invoke internal setters or send daemon commands to bypass the menu/shortcut path. The existing opt-in demo audio test uses fake action executors and is not desktop proof.

Keep raw audio, transcripts, History, audit details, and full-desktop screenshots local unless the operator authorizes sharing. Crop or redact unrelated desktop content before attaching evidence to a PR. Do not alter the original local evidence.

Record the feature IDs and entry points actually driven. Record blocked and untested paths separately. Tests of helper fixtures are not live-app coverage.

An established-profile Settings smoke uses existing onboarding state, a cached model, and the driver's existing TCC grants. A fresh account does not have these. List them in the report and leave fresh provisioning, microphone capture, and Actions execution unverified until separately exercised.

## Cleanup

```bash
"$CONTROL" cleanup > "$EVIDENCE/cleanup.txt" 2>&1
```

Cleanup compares the recorded executable and start time before signaling the owned PID. It waits up to five seconds after SIGTERM, then can SIGKILL that same PID. Superkeet's shutdown deadline can be longer, so inspect the recorded child engine PID afterward. Do not claim complete teardown solely from the helper's exit code.

Before cleanup, record the engine PID, executable, and start time for the launched bundle. After cleanup, verify both app and engine exited. If an owned child survives, signal it only after rechecking that identity. Never use `killall`, `pkill`, or a process name to terminate it. Leave unrelated engines alone.

If this run started CuaDriver, stop only that recorded driver PID after validating its executable and start time. Leave a pre-existing driver running. This skill does not manage or alter its permission policy.

Check that screenshots, AX snapshots, action logs, and cleanup logs still exist. Cleanup removes only the state file. Do not remove the evidence, history, models, defaults, MCP configuration, or the installed application. The scratch verification bundle may remain for another proof. Do not reset TCC.

## Helpers

Both helpers are executable. Invoke the CuaDriver adapter through the wrapper rather than directly.

```bash
"$CONTROL" --help
"$CONTROL" launch --app "$APP"
"$CONTROL" doctor
"$CONTROL" windows
"$CONTROL" cleanup
python3 -m unittest discover -s .cursor/skills/verify-superkeet/scripts -p 'test_*.py'
```

The helper tests cover window selection, AX reads, disclosure checks, and PID identity during cleanup. They start stand-in processes named `Superkeet`, so run them outside a live verification session. The repository's ordinary `scripts/test_*.py` discovery does not include these tests.

After UI or workflow changes, use `/maintain-verification-skill` to update this skill and its feature map. In pi, invoke the installed skill as `/skill:maintain-verification-skill`.
