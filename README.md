# Superkeet

Superkeet is a macOS menu bar app for local voice-to-text, powered by an embedded [parakeet-cli](https://github.com/lucataco/parakeet-cli) engine binary named `parakeet`. It keeps the app-side experience simple: live in the menu bar, start recording with a shortcut, transcribe locally, and copy or paste the result.

All transcription runs on-device through NVIDIA's Parakeet TDT 0.6B model via ONNX Runtime. No cloud APIs are involved.

## Current focus

This repo is still in active development. The app now favors a simpler setup-first flow over a dashboard-style UI:

- Setup checks for engine, microphone, runtime directory, and input devices
- Two shortcuts are supported: toggle recording and push-to-talk
- Clipboard-first output is the default
- Auto-paste is still available, but treated as an advanced option
- Saved history is opt-in for privacy
- Startup diagnostics are surfaced in the app when the Parakeet daemon fails

## Features

- Menu bar app with no Dock icon
- Global shortcuts for toggle recording and push-to-talk
- Floating recording overlay with mini/classic/hidden modes
- Searchable local history
- Output controls for clipboard, auto-paste, and local history retention
- Setup diagnostics for microphone access, engine presence, runtime directory, and daemon state
- 100% local transcription via `parakeet`

## Requirements

- macOS 14.0+
- Apple Silicon Mac
- Full Xcode recommended for `swift run`
- A runnable `parakeet` binary available at install time so `./install.sh` can embed it in the app bundle

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

`install.sh` builds the app, bundles `parakeet` into `Superkeet.app`, signs the bundle locally, and installs it into `~/Applications`.

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

If you use `swift run` during development, make sure the active developer directory points to full Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
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

On startup, Superkeet attempts to start the bundled Parakeet daemon in the background. The app waits for the daemon to finish model loading instead of failing immediately after a fixed half-second delay. If startup still fails, the Setup tab shows the latest diagnostics and daemon stderr excerpt.

## Usage

### Menu bar

Click the menu bar icon to:

- Start or stop recording
- Open History
- Open Settings
- Quit the app

The icon turns red while recording.

### Shortcuts

Superkeet supports two configurable shortcuts:

- Toggle Recording: press once to start, press again to stop
- Push to Talk: hold to record, release to stop

Shortcut configuration lives in `Settings > Setup`.

### Settings

The settings window currently has four tabs:

- Setup
  - readiness checks
  - shortcut configuration
  - daemon diagnostics
- Output & Privacy
  - overlay style
  - clipboard and auto-paste behavior
  - local history retention
- Advanced
  - audio device selection
  - model directory override
  - idle daemon timeout
- About
  - version and credits

### Output behavior

Current defaults:

- Copy to Clipboard: on
- Paste Automatically: off
- Save History: off

This keeps the default flow safer and simpler. Auto-paste is available, but it depends on Accessibility access and can paste into the wrong place if focus changes. History is opt-in and remains local to the Mac.

## Runtime paths

| What | Where |
|---|---|
| App settings | `UserDefaults` |
| History | `~/Library/Application Support/Superkeet/history.json` |
| Bundled engine | `Superkeet.app/Contents/Resources/bin/parakeet` |
| Runtime directory | `~/Library/Caches/com.superkeet.app/Runtime/` |
| Daemon socket | `~/Library/Caches/com.superkeet.app/Runtime/parakeet.sock` |
| Daemon PID file | `~/Library/Caches/com.superkeet.app/Runtime/parakeet.pid` |
| Model files | `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v2/` |

## Architecture

```text
SuperkeetApp (SwiftUI + AppKit)
    ├── MenuBarManager
    ├── HotkeyManager
    ├── AudioLevelMonitor
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

Open `Settings > Setup` and check:

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
