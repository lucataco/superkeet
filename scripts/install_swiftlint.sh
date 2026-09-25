#!/usr/bin/env bash
# Installs the pinned SwiftLint release so CI and releases lint with the same rules as developers.
set -euo pipefail

VERSION="0.65.1"

if command -v swiftlint >/dev/null 2>&1 && [ "$(swiftlint version)" = "$VERSION" ]; then
  echo "SwiftLint $VERSION already installed"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "https://github.com/realm/SwiftLint/releases/download/${VERSION}/portable_swiftlint.zip" -o "$WORK/swiftlint.zip"
unzip -q "$WORK/swiftlint.zip" -d "$WORK/bin"
install -d "$HOME/.local/bin"
install -m 0755 "$WORK/bin/swiftlint" "$HOME/.local/bin/swiftlint"
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$HOME/.local/bin" >> "$GITHUB_PATH"
fi
"$HOME/.local/bin/swiftlint" version
