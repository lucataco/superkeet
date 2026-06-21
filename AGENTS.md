# Agent Guide

This file provides guidance to AI coding agents working on the Superkeet codebase.

## Build & Test Commands

```bash
swift build                 # debug build
swift build -c release      # release build
swift test                  # run all tests (86 tests)
swiftlint lint --strict     # lint (must be zero violations)
```

All three must pass before committing changes.

## Project Structure

```
Sources/Superkeet/
├── main.swift              # Entry point (NSApplication)
├── SuperkeetApp.swift      # AppDelegate: lifecycle, daemon, signal handlers
├── Models/                 # Value types: settings, readiness, routing, records
├── Services/               # Singletons: ParakeetService, HotkeyManager, stores
└── Views/                  # SwiftUI views + AppKit menu bar / overlay windows
    └── SettingsWindow/     # Tabbed settings UI
Tests/SuperkeetTests/       # XCTest suite
Resources/                  # Info.plist, entitlements, app icon
scripts/                    # Release packaging + Homebrew cask update
.github/workflows/          # CI (build/test/lint) + Release (tag-triggered)
```

## Key Conventions

- **Logging:** Use `os.log` (`Logger(subsystem: "com.superkeet.app", category: "...")`).
  Never use `print()`.
- **No force-unwraps:** Use `guard let` / `??` instead of `!`.
- **No force-casts:** Use `as?` instead of `as!`.
- **Thread safety:** Services that touch UI must dispatch to main. Use
  `dispatchPrecondition(condition: .onQueue(.main))` at the top of main-only
  methods.
- **Error handling:** Prefer throwing with descriptive user-facing messages.
  Catch errors at the boundary and surface via `settings.runtimeIssue` or
  `parakeetService.lastUserFacingError`.
- **Testing:** New pure-logic code must have tests. Stores are initialized with
  an injectable `fileURL` for test isolation. `NDJSONLineBuffer` and
  `DownloadCollector` are `internal` for direct testing.

## CI

`.github/workflows/ci.yml` runs on every PR and push to `main`:
1. `swiftlint lint --strict`
2. `swift build`
3. `swift build -c release`
4. `swift test`

## Release Flow

`.github/workflows/release.yml` triggers on `v*` tags:
1. Verifies tag matches `CFBundleShortVersionString` in `Info.plist`
2. Builds `parakeet-cli` from a pinned ref, bundles it into the .app
3. Signs + notarizes with Apple Developer ID secrets
4. Uploads ZIP + SHA256 to GitHub Releases
5. Opens a PR against the Homebrew tap (`lucataco/homebrew-tap`)

To bump the version: update `CFBundleVersion` and `CFBundleShortVersionString`
in `Resources/Info.plist`, then tag `vX.Y.Z`.
