# Recording

Recording captures microphone speech, transcribes it locally, and copies or pastes the result according to the user's settings.

## Sub-features

- `record-start` starts a take through the menu.
- `record-stop` stops the take and reaches a result.
- `record-cancel` cancels pending or active capture without keeping a result.
- `record-toggle` uses the configured toggle shortcut.
- `record-hold` uses the configured push-to-talk shortcut.
- `record-outcome` proves the expected transcript and visible completion status.

## How to get to it (user POV)

- Choose `Start Recording`, then `Stop Recording`, in the status-item menu.
- Press the configured Toggle Recording shortcut.
- Hold and release the configured Push to Talk shortcut.
- Press Escape to cancel capture.

## Driving it with control-superkeet

Preconditions:

- Use a disposable macOS account and a known speech fixture delivered through the real microphone. Keep the focused destination disposable if auto-paste is enabled.
- Verify Microphone permission, engine/model readiness, input device, and runtime state through the app. Do not interpret `doctor ok` as recording readiness.
- Know how to stop capture before starting. Missing speech input, permissions, or destination isolation blocks this journey.

1. Start through the real menu. System Events uses `"$CONTROL" menu click "Start Recording"`. CuaDriver uses fresh screenshot coordinates for that observed row.
2. Capture live menu evidence. Under System Events, run `"$CONTROL" menu dump > "$EVIDENCE/recording-live.txt"`. Require `Stop Recording` or `Cancel Starting Recording`. Under CuaDriver, save the actual menu/HUD screenshot and identify the visible state.
3. Deliver the known speech through the microphone. Do not replace this with a daemon socket request, internal setter, or fake engine.
4. Choose the currently displayed stop or pending-start cancellation row. System Events uses `menu click "Stop Recording"` or `menu click "Cancel Starting Recording"`. Under CuaDriver, recapture the menu before selecting the row.
5. Observe transcription and the final result. Save `$EVIDENCE/recording-result.png` and the available AX/menu state. A success journey must show the intended transcript on the clipboard or in History, not just a `Copied` or `Pasted` label.
6. Mark shortcut, Escape-cancellation, and clipboard assertion coverage BLOCKED until a driver supplies those exact input/readback operations. The current wrapper does not send configurable shortcuts or inspect the clipboard. Menu-stop proof does not cover Escape or push-to-talk release.
7. A deliberate silence case passes only its no-speech assertion. It does not satisfy the transcript-success journey. A visible permission or engine error proves that error path, not successful recording.

## Gotchas

- Auto-paste can write into the focused app. Do not run this journey against the normal desktop.
- Hotkeys are user-configurable. Read the configured shortcut before testing keyboard entry.
- The overlay may be disabled. Do not change its setting on an established profile to make a screenshot convenient.
- Do not start another take during transcription. Wait for the user-visible ready state.
- Existing demo replay tests prove recognition/routing at their tested boundary. They do not prove microphone capture, paste destination, or the real recording UI.
