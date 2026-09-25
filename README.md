# Superkeet

Superkeet is a macOS menu bar app for local voice-to-text, powered by an embedded [parakeet-cli](https://github.com/lucataco/parakeet-cli) engine binary named `parakeet`. It keeps the app-side experience simple: live in the menu bar, start recording with a shortcut, transcribe locally, and copy or paste the result.

All transcription runs on-device through NVIDIA's Parakeet TDT 0.6B model via ONNX Runtime. No cloud APIs are involved.

## Current focus

This repo is still in active development. The app now favors a simpler setup-first flow over a dashboard-style UI:

- Onboarding: welcome, permissions, output mode, Actions Mode (macOS 26), ready
- Setup checks for engine, microphone, runtime directory, and input devices
- Two shortcuts are supported: toggle recording and push-to-talk
- Clipboard output is always on
- Auto-paste is still available, but treated as an advanced option
- Saved history is opt-in for privacy
- Aggregate usage stats store counts and durations only, never transcribed text
- Startup diagnostics are surfaced in the app when the Parakeet daemon fails

## Features

- Menu bar app with no Dock icon
- Global shortcuts for toggle recording and push-to-talk
- Floating recording overlay with mini/classic/hidden modes
- Searchable local history
- Output controls for clipboard, auto-paste, and local history retention
- Visible transcription completion, partial-result warnings, and last/original transcript recovery
- App-scoped phrase replacements and opt-in spoken correction commands with undo
- Setup diagnostics for microphone access, engine presence, runtime directory, and daemon state
- Optional **Actions Mode** that turns a spoken command into tool calls on local MCP servers, planned on-device and approved by you, or auto-approved if you choose
- **Instant app launch** in Actions Mode: “let's open Chrome and…” opens Chrome while you are still speaking, spotting the app name in the engine's own interim text (parakeet-cli 0.1.7) or, on older engines, Apple's on-device recogniser
- **Native web search**: “search for Morgan Freeman” opens a search in the browser you named or just opened, with no model call
- 100% local transcription via `parakeet`

## Requirements

- macOS 14.0+
- Apple Silicon Mac
- ~1.3 GB free disk space and a network connection for the one-time speech-model download on first run
- Full Xcode recommended for `swift run`
- For building from source: a runnable `parakeet` binary available at build time so `./install.sh` can embed it in the app bundle (end users installing a release do **not** need this — the engine is bundled and the model is downloaded automatically)
- Actions Mode additionally requires macOS 26 with Apple Intelligence enabled

### Permissions

| Permission | Why |
|---|---|
| Microphone | Required to record audio |
| Accessibility | Required for global shortcut listening and auto-paste |

## Getting started

```bash
git clone <repo-url> superkeet
cd superkeet
./install.sh
open ~/Applications/Superkeet.app
```

`install.sh` builds the app, bundles `parakeet` into `Superkeet.app`, signs the bundle locally, and installs it into `~/Applications` (set `INSTALL_DIR=/Applications` to install system-wide). It requires a protocol-1 or protocol-2 engine (v0.1.6 or later; v0.1.7 adds the interim text used by instant app launch, v0.1.8 keeps the last word of a short take, v0.1.9 streams interim text every 0.5 s). If no local engine is found, it clones the pinned tag into `.build/parakeet-cli-v0.1.9` and builds it with Cargo. Source installs therefore require `git` and Rust/Cargo. To use an existing engine checkout, set `PARAKEET_SOURCE_DIR=/path/to/parakeet-cli`.

By default, local installs are ad-hoc signed. To keep the same macOS privacy identity across local installs, pass a Developer ID identity:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./install.sh
```

## Public Releases

For public builds, Superkeet uses a dedicated packaging script that creates a release ZIP and SHA256 file:

```bash
./scripts/package_release.sh
```

This writes:

- `dist/Superkeet-<version>.zip`
- `dist/Superkeet-<version>.zip.sha256`

The GitHub Actions release workflow pins `parakeet-cli` to a specific tag, bundles the resulting `parakeet` binary, and uploads the ZIP to GitHub Releases. If Apple signing and notarization secrets are configured, the same workflow notarizes and staples the app before upload.

### Homebrew

After uploading `Superkeet-<version>.zip` to a GitHub Release, update the Homebrew tap with the matching SHA256 and install with:

```bash
brew install --cask lucataco/tap/superkeet
```

To verify `HOMEBREW_TAP_TOKEN` after creating or rotating it, run **Actions → Verify
Homebrew Token → Run workflow**, or:

```bash
gh workflow run verify-homebrew-token.yml --repo lucataco/superkeet
```

This manual workflow checks tap access and authorization at the Contents and Pull
requests write endpoints. Its write probes use a null Git object ID and identical
PR head/base branches, so GitHub rejects them without creating repository content.
It requires specific validation errors; authentication failures, missing permissions,
rate limits and unexpected responses fail the job. Results appear in the job summary.
It does not rebuild the app or replace release ZIPs/checksums. Actual release updates
still obey the tap's branch protection and repository rules.

If you use `swift run` during development, make sure the active developer directory points to full Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`swift run` also needs a `parakeet` engine (protocol 1 or 2) because the release app bundle is not assembled. It builds `PARAKEET_SOURCE_DIR`, an adjacent Formulae/sibling checkout, or the version-specific `.build/parakeet-cli-v0.1.9` checkout using Cargo with `--locked`. Explicit binary overrides skip the build. Existing source checkouts are not reset.

If you already have a local engine, you can still point Superkeet at it directly:

```bash
PARAKEET_CLI_PATH=/absolute/path/to/parakeet swift run
```

Useful verification commands:

```bash
xcodebuild -version
swift --version
swift build
```

To build a release binary:

```bash
swift build -c release
.build/release/Superkeet
```

### First launch behavior

On first launch, Superkeet downloads the on-device speech model (~670 MB, INT8) once via the bundled engine's `parakeet download --progress json`. The download starts on the first onboarding screen and shows its progress in a footer bar while you grant permissions and pick an output mode, and the daemon start path provisions the model automatically if it is still missing (for example, if onboarding was skipped). The model is stored at `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3/` and verified by SHA-256, so subsequent launches reuse it and require no network.

After the model is present, Superkeet starts the bundled Parakeet daemon in the background and waits for it to finish loading instead of failing after a fixed delay. If startup fails, the General tab shows the latest diagnostics and daemon stderr excerpt, and the Speech Model check offers a retry/re-download.

## Usage

### Menu bar

Click the menu bar icon to:

- Start or stop recording
- Run an Action or toggle **Auto-Approve Actions** when Actions Mode is enabled
- Copy the last transcript, copy the original, or undo text changes and copy
- Open History
- Open Settings
- Quit the app

For dictation, the icon turns red while recording and orange while transcribing.
The recording overlay stays up through “Transcribing…” and then flashes the
result — Copied, Pasted, Partial transcript, No speech, or Failed — before
hiding. A new recording waits for that completion. Escape cancels without
restarting the engine. Recovery and text-processing settings live in
Output & Privacy. See [transcription preservation](docs/transcription-preservation.md)
for command grammar, audio regression results and release dependencies.

In Actions Mode, a blue waveform and “Listening…” status indicate live command
recognition; a purple wand indicates an action is running. The HUD shows the
words as you speak. You can record another command while an action runs, with
up to three commands waiting in order.

### Shortcuts

Superkeet supports four configurable shortcuts:

- Toggle Recording (⌥Space): press once to start, press again to stop
- Push to Talk (fn): hold to record, release to stop
- Run an Action (⌥⇧Space): press once to start listening, press again to
  stop (visible when Actions Mode is enabled)
- Hold to Run an Action (⌃⇧Space): hold while speaking a task, release to run
  it (visible when Actions Mode is enabled)

Shortcut configuration lives in `Settings > General`. Escape cancels a recording
or an in-flight action and clears queued commands. Shortcuts are handled on a
dedicated thread so a busy settings window never delays typing in other apps.

### Settings

The settings window has five tabs (Actions is hidden on macOS versions that
cannot run it):

- General
  - usage stats, appearance, launch at login
  - setup checklist and status
  - shortcut configuration
  - recording feedback: overlay style and sound cues
  - engine diagnostics
- Output & Privacy
  - filler-word removal and spoken corrections
  - auto-paste (every transcript is always copied to the clipboard)
  - local history and usage-stat retention
- Actions
  - Actions Mode enablement and on-device model availability
  - MCP server management (add, edit, test, reconnect)
  - approval policy (including **Just Do It (YOLO)**) and the local action log
- Advanced
  - audio device selection (the engine restarts automatically on change)
  - app-scoped phrase replacements
  - model directory override
  - idle engine shutdown
  - Actions Mode step budget, tool timeout, and command deadline
- About
  - version and credits

See [Actions Mode](docs/actions-mode.md) for the MCP setup, safety model, and
known limitations.

### Output behavior

Current defaults:

- Copy to Clipboard: always
- Paste Automatically: off
- Save History: off

Every transcript is copied to the clipboard, so no combination of settings can
strand text inside the app. Auto-paste is available, but it depends on
Accessibility access and can paste into the wrong place if focus changes; when
it is on you can choose whether the transcript stays on the clipboard afterwards
or your previous clipboard is restored. History is opt-in and remains local to
the Mac.

## Runtime paths

| What | Where |
|---|---|
| App settings | `UserDefaults` |
| History | `~/Library/Application Support/Superkeet/history.json` |
| Usage stats | `~/Library/Application Support/Superkeet/usage-stats.json` |
| MCP servers | `~/Library/Application Support/Superkeet/mcp-servers.json` |
| Action audit log | `~/Library/Application Support/Superkeet/action-audit.log` |
| Bundled engine | `Superkeet.app/Contents/Resources/bin/parakeet` |
| Runtime directory | `~/Library/Caches/com.superkeet.app/Runtime/` |
| Daemon socket | `~/Library/Caches/com.superkeet.app/Runtime/parakeet.sock` |
| Daemon PID file | `~/Library/Caches/com.superkeet.app/Runtime/parakeet.pid` |
| Model files | `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3/` |

## Architecture

```text
SuperkeetApp (SwiftUI + AppKit)
    ├── MenuBarManager
    ├── HotkeyManager
    ├── MicrophoneTapHub (one shared input tap)
    │       ├── AudioLevelMonitor
    │       └── SpeechAnalyzerPartialSource (macOS 26, live command text)
    ├── RecordingOverlayWindowController
    ├── PasteService
    ├── HistoryStore
    └── ParakeetService
            └── bundled parakeet serve
                    ├── loads Parakeet model
                    ├── loads Silero VAD
                    ├── binds Unix socket
                    └── accepts start/stop/status/shutdown commands
```

Superkeet communicates with the daemon over a Unix socket using JSON commands such as `start`, `stop`, `status`, and `shutdown`.

## Project structure

```text
superkeet/
├── Package.swift
├── Resources/
│   ├── Info.plist
│   └── Superkeet.entitlements
├── Sources/Superkeet/
│   ├── SuperkeetApp.swift
│   ├── Models/
│   ├── Services/
│   └── Views/
└── Tests/
    └── SuperkeetTests/
```

## Security Notes

- The public app bundle only launches the embedded `parakeet` binary.
- Transcript history is off by default and must be enabled explicitly.
- History is stored locally with restricted file permissions.
- Actions Mode is off by default and plans on-device. Tool calls are approved
  by you, or auto-approved if you choose; destructive tools still require
  approval. MCP servers are local processes you configure; the action log is
  local and redacts sensitive-looking fields.
- There is no in-app auto-update channel.

## Troubleshooting

### `swift run` fails before the app launches

Check that you are using full Xcode instead of Command Line Tools:

```bash
xcode-select -p
xcodebuild -version
```

If needed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### App says `Failed to start Parakeet`

Open `Settings > General` and check the Setup Checklist and Diagnostics:

- Speech engine path
- Runtime directory status
- Input device availability
- Latest daemon diagnostics

Common causes:

- bundled `parakeet` binary missing from the app bundle
- model files missing
- microphone permission denied
- no available audio input device
- slow model load on first startup

### `parakeet devices` shows no inputs

Check:

- System Settings > Privacy & Security > Microphone
- System Settings > Sound > Input
- any external audio device routing

## License

MIT
