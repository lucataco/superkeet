# Setup

Setup introduces Superkeet, checks permissions and the speech engine, configures output, and offers Actions Mode on supported systems.

## Sub-features

- `setup-first-run` opens Setup on a fresh macOS profile.
- `setup-rerun` opens Setup from the menu after onboarding is complete.
- `setup-welcome` shows the welcome page.
- `setup-permissions` shows Microphone and Accessibility requirements.
- `setup-finish` completes onboarding and checks readiness for the selected behavior.

## How to get to it (user POV)

- Launch Superkeet for the first time.
- Choose `Run Setup Again...` in the status-item menu after completing onboarding.

## Driving it with control-superkeet

Preconditions:

- Complete Launch and Doctor. Read the reported `hasCompletedOnboarding` value before choosing a branch below.
- Use a disposable macOS account for first-run completion or permission changes. Do not reset an established profile's onboarding flag.
- Opening Setup can download a missing speech model. This is not a network-free journey.

### Inspect Setup after completed onboarding

Use this branch only when `hasCompletedOnboarding` is already 1 and the initial first-run Setup window is not open.

1. Open the real menu and choose `Run Setup Again...`. System Events uses `"$CONTROL" menu click "Run Setup Again..."`. CuaDriver uses the fresh-screenshot entry procedure in the skill.
2. Wait until `"$CONTROL" windows` lists `Superkeet Setup`. Check `Welcome to Superkeet` with `exists --name`. Add `--surface setup` only for CuaDriver.
3. Choose `Continue` with `click --name "Continue"`, again adding `--surface setup` only for CuaDriver. Assert `Two Permissions`, `Microphone`, and `Accessibility` in a fresh snapshot. Do not click permission-grant controls during inspection.
4. Choose `Back` and assert the welcome page returns. Save `$EVIDENCE/setup-welcome.ax.txt` and `$EVIDENCE/setup-welcome.png`. Use CuaDriver surface selectors or the System Events commands with Setup as the sole app window.
5. Close the rerun window. System Events uses `"$CONTROL" close-window --title "Superkeet Setup"`. CuaDriver uses `"$CONTROL" close-window --window "Superkeet Setup"`. Confirm the window disappears. This branch does not prove first-run completion.

### Complete first-run Setup in a disposable account

Do not execute the rerun branch or its close step. Keep the initial Setup window open until intentionally finishing this journey.

1. Confirm the automatically opened `Superkeet Setup` and the incomplete onboarding state. Save its welcome snapshot and screenshot.
2. Continue through permissions, output, optional Actions, and Ready using the displayed `Continue` controls. The operator must grant TCC permissions. Do not substitute a cached model or existing onboarding flag for fresh provisioning proof.
3. At Ready, distinguish `You're all set`, `Almost ready`, and `Setup needs attention`. Wait for the checks required by the selected feature. A missing grant or model remains a blocked prerequisite.
4. Choose `Start Using Superkeet` or the displayed `Continue to Superkeet` only when intentionally completing onboarding. Capture the resulting setup checks and menu. A completion button alone does not prove recording readiness.

## Gotchas

- Closing the initial first-run window skips setup, writes `hasCompletedOnboarding`, and starts services. It is not a read-only cancellation.
- Choosing Run Setup Again while the first-run window is already visible does not replace its close callback. Do not use that path to turn first-run Setup into an inspection-only window.
- An existing profile may contain model files, permission grants, and onboarding state. List those preconditions when reporting a rerun proof.
- The Actions step can be absent when the OS/framework does not support it.
- A first-run journey blocked by missing grants remains BLOCKED. Rerunning Setup is not a substitute.
- With System Events, named clicks search all app windows and row clicks target the first. Keep Setup as the sole target window.
