#!/usr/bin/env bash
# In GitHub Actions SwiftLint goes into a private directory, exported as $SWIFTLINT, instead of
# onto PATH, where it would sit ahead of codesign, xcrun and ditto for every later step.
set -euo pipefail

VERSION="0.65.1"
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

if [ -n "${GITHUB_ENV:-}" ]; then
  DEST="${RUNNER_TEMP:?}/swiftlint-$VERSION"
else
  if command -v swiftlint >/dev/null 2>&1 && [ "$(swiftlint version)" = "$VERSION" ]; then
    echo "SwiftLint $VERSION already installed"
    exit 0
  fi
  DEST="$HOME/.local/bin"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "https://github.com/realm/SwiftLint/releases/download/${VERSION}/portable_swiftlint.zip" -o "$WORK/swiftlint.zip"
if ! echo "$SHA256  $WORK/swiftlint.zip" | shasum -a 256 -c - >/dev/null; then
  echo "The SwiftLint $VERSION download does not match its pinned checksum" >&2
  exit 1
fi
unzip -q "$WORK/swiftlint.zip" -d "$WORK/bin"
install -d "$DEST"
install -m 0755 "$WORK/bin/swiftlint" "$DEST/swiftlint"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SWIFTLINT=$DEST/swiftlint" >> "$GITHUB_ENV"
fi
"$DEST/swiftlint" version
