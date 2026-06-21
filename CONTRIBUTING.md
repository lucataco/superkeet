# Contributing to Superkeet

Thanks for your interest in contributing! Superkeet is a macOS menu bar app for
local voice-to-text, powered by an embedded Parakeet engine.

## Development Setup

```bash
git clone <repo-url> superkeet
cd superkeet
swift build           # debug build
swift test            # run the test suite
swiftlint lint --strict  # lint (must be zero violations)
```

For `swift run`, full Xcode (not just Command Line Tools) is required:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

To build the .app bundle locally, you need a runnable `parakeet` binary. See
`install.sh` for the search paths, or set `PARAKEET_CLI_PATH` to point at one.

## Before Opening a Pull Request

1. **Build passes:** `swift build` and `swift build -c release`
2. **Tests pass:** `swift test`
3. **Lint passes:** `swiftlint lint --strict` (zero violations)
4. **No `print()` calls:** use `os.log` (`Logger`) with an appropriate
   subsystem (`com.superkeet.app`) and category
5. **No force-unwraps:** use `guard let` / `??` instead of `!`
6. **New logic is tested:** add tests for any new pure-logic code (parsers,
   state machines, routing decisions, etc.)

## Code Style

- Follow the existing Swift style in the repo
- 4-space indentation
- `final class` for single-inheritance classes
- `enum` for namespaces (not `struct`)
- `private` / `fileprivate` by default; promote only when needed
- Comments explain *why*, not *what*

## Architecture Overview

See the [README](README.md) for the high-level architecture. Key conventions:

- **Services** are singletons (`static let shared`) that own their lifecycle
- **Models** are value types (`struct` / `enum`) with no UI dependencies
- **Views** are SwiftUI structs that observe services via `@ObservedObject`
- **Tests** live in `Tests/SuperkeetTests/` and use XCTest

## Reporting Issues

Use the GitHub issue templates. Include:

- macOS version and Mac architecture (Apple Silicon / Intel)
- Superkeet version (from Settings → About)
- Steps to reproduce
- Relevant Console.app logs (filter by `com.superkeet.app`)
