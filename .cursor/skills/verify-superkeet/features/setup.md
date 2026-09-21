# Setup

Setup walks a user through welcome, permissions, output mode, optional Actions Mode, and a ready checklist. First launch opens it automatically; later launches keep it behind `Run Setup Again...`.

## Sub-features

- `setup-first-run` opens `Superkeet Setup` when onboarding has not been completed.
- `setup-rerun` opens the same window from the menu after onboarding.
- `setup-welcome` shows `Welcome to Superkeet` and `Continue`.
- `setup-permissions` shows `Two Permissions` with Microphone and Accessibility.
- `setup-finish` offers `Start Using Superkeet` or `Continue to Superkeet` on the last step.

## How to get to it (user POV)

- Launch Superkeet for the first time (onboarding incomplete).
- Choose `Run Setup Again...` in the Superkeet menu.

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` is clean.
- Prefer `Run Setup Again...`. Do not reset `hasCompletedOnboarding`.
- Do not click `Start Using Superkeet` or `Continue to Superkeet` unless the recipe is specifically proving first-run completion and you intend to finish setup.

- **Re-run entry.** Choose `Run Setup Again...`. Run `control-superkeet menu click "Run Setup Again..."`. `control-superkeet windows` lists `Superkeet Setup`.
- **Welcome.** Run `control-superkeet exists --name "Welcome to Superkeet"`. Exit 0. A `Continue` button exists. A `Back` button does not.
- **Permissions.** Run `control-superkeet click --name "Continue"`. The heading `Two Permissions` appears with `Microphone` and `Accessibility`. `Continue` and `Back` both exist.
- **Do not grant.** Do not click `Grant Microphone Access` or `Open System Settings` unless the operator asked to change TCC.
- **Back to welcome.** Run `control-superkeet click --name "Back"`. `Welcome to Superkeet` returns.
- **Proof.** Run `control-superkeet snapshot --path artifacts/setup/welcome.ax.txt` and `control-superkeet screenshot --path artifacts/setup/welcome.png --window "Superkeet Setup"`. Both show `Welcome to Superkeet`.
- **Close.** Run `control-superkeet close-window --title "Superkeet Setup"`. The window is gone. Onboarding remains completed.

## Gotchas

- First-run completion writes `hasCompletedOnboarding` and starts the daemon. Re-run is the safe path on a machine that already uses Superkeet.
- The last-step button is `Start Using Superkeet` when checks pass, otherwise `Continue to Superkeet`.
- The Actions step appears only when the OS supports Actions Mode. Do not fail the recipe if `Continue` from output skips straight to ready.
- Closing Setup with the window close button is enough. Do not quit Superkeet to dismiss it.
