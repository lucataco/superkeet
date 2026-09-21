# Recording

Recording lets a user capture a take from the menu, watch the extra and overlay move through recording and transcribing, then see a visible outcome.

## Sub-features

- `record-start` starts a take from `Start Recording`.
- `record-status` shows `Recording...` in the menu while the take is live.
- `record-stop` stops from `Stop Recording` and leaves the overlay up through `Transcribing…` if speech was captured.
- `record-cancel` cancels a start or a live take without producing a kept result.
- `record-outcome` flashes `Copied`, `Pasted`, `Partial transcript copied`, `No speech detected`, or `Transcription failed`.

## How to get to it (user POV)

- Choose `Start Recording` in the Superkeet menu, then `Stop Recording`.
- Press the configured Toggle Recording shortcut (defaults vary; do not guess).
- Hold the configured Push to Talk shortcut.

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` is clean.
- General setup shows microphone, engine, model, input device, and runtime directory as healthy, or you are prepared for a visible failure outcome.
- Overlay style is not hidden if you need overlay proof. Do not change the style unless you restore it.
- This uses the real microphone. Do not start a take you cannot stop immediately.

- **Start.** Choose `Start Recording`. Run `control-superkeet menu click "Start Recording"`.
- **Live menu.** Run `control-superkeet menu dump`. Output includes `Stop Recording` and a `Recording...` status, or `Cancel Starting Recording` if the daemon is still coming up.
- **Stop.** Run `control-superkeet menu click "Stop Recording"` (or `Cancel Starting Recording` if that is what appeared).
- **Outcome.** After stop, the extra returns to the idle waveform, or shows an orange transcribing state, then an overlay label from `Copied`, `Pasted`, `Partial transcript copied`, `No speech detected`, `Transcription failed`, or the overlay hides when there is nothing to show.
- **Proof.** Capture `artifacts/recording/menu-live.txt` from the live dump and `artifacts/recording/after.ax.txt` plus `artifacts/recording/after.png` after stop. The live dump must contain `Stop Recording` or `Cancel Starting Recording`. Do not claim a specific transcript string unless you spoke it and it appears in History or on the clipboard.

## Gotchas

- Shortcuts are user-configurable. The menu item is the only stable entry point.
- Auto-paste can type into whatever app is focused. Keep focus on a disposable field, or leave auto-paste off.
- A silent room yields `No speech detected`. That is a valid outcome, not a failed recipe, if start and stop were proven.
- Escape cancels recording for a real user. `control-superkeet` does not send Escape; use the menu cancel/stop items.
- Do not overlap a second take while `Transcribing…` is showing. The menu disables `Start Recording` until that finishes.
