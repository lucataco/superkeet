# Superkeet

Superkeet is a macOS menu bar app for local voice-to-text, powered by [parakeet-cli](https://github.com/lucataco/parakeet-cli). It keeps the app-side experience simple: live in the menu bar, start recording with a shortcut, transcribe locally, and copy or paste the result.

All transcription runs on-device through NVIDIA's Parakeet TDT 0.6B model via ONNX Runtime. No cloud APIs are involved.

## Current focus

This repo is still in active development. The app now favors a simpler setup-first flow over a dashboard-style UI:

- Setup checks for engine, microphone, runtime directory, and input devices
- Two shortcuts are supported: toggle recording and push-to-talk
- Clipboard-first output is the default
- Auto-paste is still available, but treated as an advanced option
- Startup diagnostics are surfaced in the app when the Parakeet daemon fails

## Features

- Menu bar app with no Dock icon
- Global shortcuts for toggle recording and push-to-talk
- Floating recording overlay with mini/classic/hidden modes
- Searchable local history
- Output controls for clipboard, auto-paste, and local history retention
- Setup diagnostics for microphone access, engine presence, runtime directory, and daemon state
- 100% local transcription via `parakeet-cli`

## Requirements

- macOS 14.0+
- Apple Silicon Mac
- Full Xcode recommended for `swift run`
- Rust / Cargo for building `parakeet-cli` if the binary is missing
- `parakeet-cli` source cloned locally, default path:
  - `/Users/lucataco/Code/CLIs/parakeet-cli`

### Permissions

| Permission | Why |
|---|---|
| Microphone | Required to record audio |
| Accessibility | Required for global shortcut listening and auto-paste |

## Getting started

```bash
git clone <repo-url> superkeet
cd superkeet
swift run
```

If you use `swift run`, make sure the active developer directory points to full Xcode:

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

On startup, Superkeet attempts to start the Parakeet daemon in the background. If the binary at the configured `parakeet-cli` path is missing, the app will try to build it with:

```bash
cargo build --release
```

The app now waits for the daemon to finish model loading instead of failing immediately after a fixed half-second delay. If startup still fails, the Setup tab shows the latest diagnostics and daemon stderr excerpt.

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
  - VAD sensitivity
  - silence timeout
  - model directory override
- About
  - version and credits

### Output behavior

Current defaults:

- Copy to Clipboard: on
- Paste Automatically: off
- Save History: on

This keeps the default flow safer and simpler. Auto-paste is available, but it depends on Accessibility access and can paste into the wrong place if focus changes.

## Runtime paths

| What | Where |
|---|---|
| App settings | `UserDefaults` |
| History | `~/Library/Application Support/Superkeet/history.json` |
| Runtime directory | `~/Library/Application Support/Superkeet/Runtime/` |
| Daemon socket | `~/Library/Application Support/Superkeet/Runtime/parakeet.sock` |
| Daemon PID file | `~/Library/Application Support/Superkeet/Runtime/parakeet.pid` |
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
            └── parakeet-cli serve
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

- `parakeet-cli` binary missing
- model files missing
- microphone permission denied
- no available audio input device
- slow model load on first startup

### `parakeet-cli devices` shows no inputs

Check:

- System Settings > Privacy & Security > Microphone
- System Settings > Sound > Input
- any external audio device routing

## License

MIT
