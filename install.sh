#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Superkeet"
BUNDLE_NAME="${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
BUNDLE_DIR="${SCRIPT_DIR}/${BUNDLE_NAME}"
ENTITLEMENTS_PATH="${SCRIPT_DIR}/Resources/Superkeet.entitlements"
PARAKEET_BINARY_PATH="${PARAKEET_BINARY_PATH:-}"
PARAKEET_SOURCE_DIR="${PARAKEET_SOURCE_DIR:-}"
PARAKEET_OVERRIDE="${PARAKEET_CLI_PATH:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
PARAKEET_REPOSITORY_URL="https://github.com/lucataco/parakeet-cli.git"
PARAKEET_REF="${PARAKEET_REF:-v0.1.5}"
LOCAL_PARAKEET_SOURCE_DIR="${SCRIPT_DIR}/.build/parakeet-cli"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

resolve_parakeet_binary() {
    local candidates=()

    if [[ -n "$PARAKEET_BINARY_PATH" ]]; then
        candidates+=("$PARAKEET_BINARY_PATH")
    fi

    if [[ -n "$PARAKEET_OVERRIDE" ]]; then
        candidates+=("$PARAKEET_OVERRIDE")
    fi

    if [[ -n "$PARAKEET_SOURCE_DIR" ]]; then
        candidates+=(
            "${PARAKEET_SOURCE_DIR}/target/release/parakeet"
            "${PARAKEET_SOURCE_DIR}/target/debug/parakeet"
        )
    fi

    candidates+=(
        "${LOCAL_PARAKEET_SOURCE_DIR}/target/release/parakeet"
        "${LOCAL_PARAKEET_SOURCE_DIR}/target/debug/parakeet"
        "${SCRIPT_DIR}/../parakeet-cli/target/release/parakeet"
        "${SCRIPT_DIR}/../parakeet-cli/target/debug/parakeet"
        "$HOME/Code/CLIs/parakeet-cli/target/release/parakeet"
        "$HOME/Code/CLIs/parakeet-cli/target/debug/parakeet"
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

build_parakeet_source_dir() {
    local source_dir="$1"
    require_command cargo
    printf '==> Building parakeet from %s...\n' "$source_dir"
    cargo build --release --bin parakeet --manifest-path "${source_dir}/Cargo.toml"
}

bootstrap_local_parakeet_cli() {
    require_command git
    require_command cargo

    printf '==> Preparing parakeet-cli %s in %s...\n' "$PARAKEET_REF" "$LOCAL_PARAKEET_SOURCE_DIR"
    if [[ -d "${LOCAL_PARAKEET_SOURCE_DIR}/.git" ]]; then
        git -C "$LOCAL_PARAKEET_SOURCE_DIR" fetch --depth 1 origin "$PARAKEET_REF"
        git -C "$LOCAL_PARAKEET_SOURCE_DIR" checkout --force FETCH_HEAD
    else
        rm -rf "$LOCAL_PARAKEET_SOURCE_DIR"
        mkdir -p "$(dirname "$LOCAL_PARAKEET_SOURCE_DIR")"
        git clone --depth 1 --branch "$PARAKEET_REF" "$PARAKEET_REPOSITORY_URL" "$LOCAL_PARAKEET_SOURCE_DIR"
    fi

    build_parakeet_source_dir "$LOCAL_PARAKEET_SOURCE_DIR"
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

if [[ -n "$PARAKEET_SOURCE_DIR" && ! -x "${PARAKEET_SOURCE_DIR}/target/release/parakeet" ]]; then
    build_parakeet_source_dir "$PARAKEET_SOURCE_DIR"
fi

PARAKEET_BINARY="$(resolve_parakeet_binary || true)"
if [[ -z "$PARAKEET_BINARY" ]]; then
    bootstrap_local_parakeet_cli
    PARAKEET_BINARY="$(resolve_parakeet_binary || true)"
fi

if [[ -z "$PARAKEET_BINARY" ]]; then
    printf 'Unable to find or build a runnable `parakeet` binary to bundle.\n\n' >&2
    printf 'Install git and Rust/Cargo, set `PARAKEET_CLI_PATH=/absolute/path/to/parakeet`, or set `PARAKEET_SOURCE_DIR=/absolute/path/to/parakeet-cli`.\n' >&2
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
