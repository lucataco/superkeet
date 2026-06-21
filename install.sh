#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Superkeet"
BUNDLE_NAME="${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
BUNDLE_DIR="${SCRIPT_DIR}/${BUNDLE_NAME}"
ENTITLEMENTS_PATH="${SCRIPT_DIR}/Resources/Superkeet.entitlements"
PARAKEET_OVERRIDE="${PARAKEET_CLI_PATH:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

resolve_parakeet_binary() {
    local candidates=()

    if [[ -n "$PARAKEET_OVERRIDE" ]]; then
        candidates+=("$PARAKEET_OVERRIDE")
    fi

    candidates+=(
        "${SCRIPT_DIR}/../parakeet-cli/target/release/parakeet"
        "$HOME/Code/CLIs/parakeet-cli/target/release/parakeet"
        "$HOME/.cargo/bin/parakeet"
        "/opt/homebrew/bin/parakeet"
        "/usr/local/bin/parakeet"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

verify_parakeet_architecture() {
    local binary="$1"
    local host_arch
    host_arch="$(uname -m)"
    local binary_archs
    binary_archs="$(lipo -archs "$binary" 2>/dev/null || true)"
    if [[ -z "$binary_archs" ]]; then
        printf 'Could not inspect architectures of `%s` (is lipo available?).\n' "$binary" >&2
        exit 1
    fi
    # binary_archs is space-separated (e.g. "x86_64 arm64" for a universal binary)
    if [[ " $binary_archs " != *" $host_arch "* ]]; then
        printf 'Parakeet binary (%s) does not match host architecture (%s).\n' "$binary_archs" "$host_arch" >&2
        printf 'Rebuild parakeet for %s before installing.\n' "$host_arch" >&2
        exit 1
    fi
}

require_command swift
require_command codesign

PARAKEET_BINARY="$(resolve_parakeet_binary || true)"
if [[ -z "$PARAKEET_BINARY" ]]; then
    cat >&2 <<'EOF'
Unable to find a runnable `parakeet` binary to bundle.

Set `PARAKEET_CLI_PATH=/absolute/path/to/parakeet` or install/build it in one of:
  ~/Code/CLIs/parakeet-cli/target/release/parakeet
  ~/.cargo/bin/parakeet
  /opt/homebrew/bin/parakeet
  /usr/local/bin/parakeet
EOF
    exit 1
fi

verify_parakeet_architecture "$PARAKEET_BINARY"

printf '==> Building %s (release)...\n' "$APP_NAME"
swift build -c release

printf '==> Assembling %s...\n' "$BUNDLE_NAME"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources/bin"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp "$SCRIPT_DIR/Resources/Info.plist" "$BUNDLE_DIR/Contents/"
cp "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/Resources/"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/"
cp "$PARAKEET_BINARY" "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
chmod 755 "$BUNDLE_DIR/Contents/Resources/bin/parakeet"

printf '==> Signing %s...\n' "$BUNDLE_NAME"
SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY" --options runtime)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR"

printf '==> Verifying code signature...\n'
codesign --verify --deep --strict "$BUNDLE_DIR"

printf '==> Installing to %s...\n' "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$BUNDLE_NAME"
mv "$BUNDLE_DIR" "$INSTALL_DIR/"

printf '\nDone! %s installed to %s/%s\n' "$APP_NAME" "$INSTALL_DIR" "$BUNDLE_NAME"
printf 'Bundled speech engine: %s\n' "$PARAKEET_BINARY"
printf 'Signing identity: %s\n' "$CODESIGN_IDENTITY"
printf 'Open it from Finder, Spotlight, or run:\n'
printf '  open "%s/%s"\n' "$INSTALL_DIR" "$BUNDLE_NAME"
