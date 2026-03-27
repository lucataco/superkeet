# Superkeet

A macOS menu bar app for voice-to-text, powered by [Parakeet](https://github.com/lucataco/parakeet-cli) — a fully local, offline speech recognition engine using NVIDIA's Parakeet TDT 0.6B model.

Think [Superwhisper](https://superwhisper.com), but open-source and completely private. All audio is processed on-device using ONNX Runtime with CoreML acceleration. Nothing ever leaves your Mac.

## Features

- **Menu bar app** — lives in your macOS menu bar, no dock icon
- **Global hotkey** — press `fn` (or `Option+Space`) to toggle recording from anywhere
- **Live recording overlay** — floating pill-shaped window with animated equalizer bars and elapsed timer
- **Auto-paste** — transcribed text is automatically pasted into whatever app you were using
- **Rich history** — searchable list of past transcriptions with app context, duration, and word count
- **Settings dashboard** — stats (avg WPM, words this week, apps used, time saved), hotkey config, recording tuning, output preferences
- **100% offline** — powered by Parakeet TDT 0.6B v2 (ONNX) + Silero VAD v5, runs entirely on your Mac

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Rust / Cargo** — for building the Parakeet CLI engine ([install Rust](https://rustup.rs))
- **Xcode Command Line Tools** — `xcode-select --install`
- **parakeet-cli source** — cloned at `/Users/lucataco/Code/CLIs/parakeet-cli` (configurable in Settings)

### Permissions

On first launch, macOS will prompt for:

| Permission | Why |
|---|---|
| **Microphone** | Audio capture for transcription and equalizer visualization |
| **Accessibility** | Global hotkey listener and auto-paste (simulated Cmd+V) |

## Getting started

```bash
# Clone the repo
git clone <repo-url> superkeet
cd superkeet

# Build and run (debug)
swift run

# Or build a release binary
swift build -c release
.build/release/Superkeet
```

On first launch, Superkeet will automatically build the Parakeet CLI from source (`cargo build --release`) and download the required model weights (~2.3 GB) from HuggingFace. This only happens once.

## Usage

### Menu bar

Click the waveform icon in the menu bar to access:

| Item | Description |
|---|---|
| **Start / Stop Recording** | Toggle voice recording |
| **History** | View past transcriptions |
| **Settings...** | Open the settings window |
| **Quit Superkeet** | Shut down the daemon and exit |

The icon turns red while recording.

### Hotkey

Press `fn` to toggle recording on/off from any app. The hotkey is configurable in Settings > Home.

When recording starts:
1. A floating overlay appears at the bottom of the screen with an animated equalizer
2. Speak naturally — Parakeet uses voice activity detection (VAD) to handle pauses
3. Press `fn` again (or click Stop) to end
4. The transcribed text is automatically pasted into whatever app was focused before recording

### Settings

The settings window has four tabs with a vertical sidebar:

**Home** — Dashboard with weekly stats (average WPM, words transcribed, apps used, time saved) and hotkey configuration.

**Recording** — Audio input device selector, VAD sensitivity slider, silence timeout slider, and model directory path.

**Output** — Toggle auto-paste (simulated Cmd+V) and clipboard copy independently.

**About** — Version info, credits, and privacy details.

## Architecture

```
SuperkeetApp (SwiftUI)
    │
    ├── MenuBarManager        NSStatusItem menu
    ├── HotkeyManager         CGEvent tap for global hotkeys
    ├── AudioLevelMonitor     AVAudioEngine mic tap → equalizer UI
    ├── RecordingOverlay      Floating NSPanel with equalizer + timer
    ├── PasteService          Clipboard + simulated Cmd+V
    ├── HistoryStore          JSON file persistence + stats
    │
    └── ParakeetService       Manages subprocess lifecycle
            │
            └── parakeet serve    (Unix socket at /tmp/parakeet.sock)
                    │
                    ├── Microphone capture (cpal)
                    ├── Silero VAD v5
                    ├── FastConformer Encoder (ONNX, CoreML)
                    └── TDT Greedy Decoder (ONNX)
```

Superkeet communicates with the Parakeet daemon over a Unix socket using JSON commands (`start`, `stop`, `toggle`, `status`, `shutdown`). The daemon handles all audio capture and transcription. The app handles UI, hotkeys, and output.

## Project structure

```
superkeet/
├── Package.swift
├── Resources/
│   ├── Info.plist
│   └── Superkeet.entitlements
└── Sources/Superkeet/
    ├── SuperkeetApp.swift                  # Entry point + AppDelegate
    ├── Models/
    │   ├── AppSettings.swift               # UserDefaults-backed settings
    │   └── TranscriptionRecord.swift       # History data model
    ├── Services/
    │   ├── ParakeetService.swift           # Daemon lifecycle + socket IPC
    │   ├── HotkeyManager.swift            # Global hotkey (CGEvent tap)
    │   ├── AudioLevelMonitor.swift        # Mic levels for equalizer
    │   ├── PasteService.swift             # Clipboard + auto-paste
    │   └── HistoryStore.swift             # JSON persistence + weekly stats
    └── Views/
        ├── MenuBarView.swift               # NSStatusItem + NSMenu
        ├── RecordingOverlayView.swift      # Floating pill UI
        ├── RecordingOverlayWindow.swift    # NSPanel controller
        ├── EqualizerView.swift            # Animated audio bars
        ├── HistoryView.swift              # Searchable history list
        └── SettingsWindow/
            ├── SettingsView.swift          # Sidebar navigation
            ├── HomeTabView.swift           # Stats + hotkey config
            ├── RecordingTabView.swift      # Device, VAD, silence
            ├── OutputTabView.swift         # Auto-paste, clipboard
            └── AboutTabView.swift          # Version + credits
```

## Data storage

| What | Where |
|---|---|
| Settings | `UserDefaults` (standard macOS preferences) |
| History | `~/Library/Application Support/Superkeet/history.json` |
| Models | `~/Library/Application Support/parakeet/models/` |
| Daemon socket | `/tmp/parakeet.sock` |
| Daemon PID | `/tmp/parakeet.pid` |

## Tech stack

| Component | Technology |
|---|---|
| App framework | SwiftUI + AppKit |
| Speech engine | Parakeet TDT 0.6B v2 (Rust + ONNX Runtime) |
| Voice detection | Silero VAD v5 |
| Inference | ONNX Runtime with CoreML EP (Apple Silicon) |
| Audio capture | cpal (Rust) + AVAudioEngine (Swift, for UI) |
| IPC | Unix domain socket |
| Build system | Swift Package Manager |

## License

MIT
