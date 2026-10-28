# Settings

Settings lets users inspect setup health, configure shortcuts and output behavior, manage Actions Mode, troubleshoot the engine, and read the app version.

## Sub-features

- `settings-open` opens Settings from the status-item menu.
- `settings-general` shows General, Setup Checklist, shortcuts, and microphone controls.
- `settings-output` shows output and privacy options without changing them.
- `settings-advanced` shows troubleshooting and diagnostics.
- `settings-about` shows the launched app's version and privacy explanation.
- `settings-actions` shows the Actions tab or its availability explanation.

## How to get to it (user POV)

- Choose `Settings...` in the Superkeet status-item menu.
- Use the Settings menu key equivalent. The helper does not send this shortcut, so menu-click proof does not cover keyboard entry.

## Driving it with control-superkeet

Preconditions:

- Complete Launch and Doctor from the skill. Do not have a recording or action in progress.
- Keep only Settings open for the System Events path. For CuaDriver, use `--surface settings` on supported commands.

1. Open the real menu and choose Settings. System Events uses `"$CONTROL" menu click "Settings..."`. CuaDriver uses the fresh-screenshot menu procedure in the skill. Save the action outputs under `$EVIDENCE`.
2. Wait for `General` to exist using the skill's bounded check. Omit `--surface settings` for System Events. A newly launched window can appear after the click returns.
3. Select General explicitly with `"$CONTROL" click --row 1`. Save an AX snapshot to `$EVIDENCE/general.ax.txt`. Under CuaDriver, use `"$CONTROL" snapshot --surface settings --path "$EVIDENCE/general.ax.txt"`. Under System Events, omit the surface selector. Assert `General` and `Setup Checklist` in the tree.
4. Inspect the checklist. An incomplete checklist offers `Show all`. A fully healthy checklist offers `Show details`. Neither label alone proves every recording prerequisite is healthy. Do not change the microphone or shortcuts.
5. Select Output & Privacy with `"$CONTROL" click --row 2`. The snapshot must contain `Output & Privacy` and `Every transcript is copied to the clipboard.` Do not toggle output or history options.
6. Inspect the sidebar rows. With Actions present, Advanced is row 4 and About is row 5. Without Actions, Advanced is row 3 and About is row 4. Select the observed Advanced row and assert `Troubleshooting` in the AX tree.
7. For CuaDriver diagnostics only, run `"$CONTROL" expand --name "Diagnostic details"`. Save `$EVIDENCE/advanced.ax.txt` and assert `Status:` or `Diagnostics:`. System Events has no equivalent helper command. Do not press engine restart, log export, or copy controls during inspection.
8. Select the observed About row. Save `$EVIDENCE/about.ax.txt` and `$EVIDENCE/about.png`. CuaDriver uses `snapshot --surface settings` and `screenshot --surface settings`. System Events uses plain `snapshot` and `screenshot`, each with `--path`.
9. Assert the observed About version matches the launched bundle. Read it with `/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"`. The AX tree must include that `Version` value, `On-device speech recognition`, and the privacy explanation beginning `Your audio and transcripts are processed on your Mac`.
10. For Actions inspection, follow [Actions Mode](actions.md). A visible tab does not prove Apple Intelligence is ready or an action can run.

## Gotchas

- Settings has an empty window title. `--window "Settings"` does not identify it.
- Reopening Settings fronts an existing window and preserves its selected tab.
- `--surface` is a CuaDriver selector, not a universal helper argument.
- CuaDriver's Settings selector can also match another empty-title window. Require Settings labels, not just a selected window ID.
- Offscreen Settings windows are unavailable to CuaDriver. Report the bounds rather than guessing a click location.
- Actions visibility depends on OS/framework support. Its unavailable-model card is valid UI, not a failed tab-opening journey.
