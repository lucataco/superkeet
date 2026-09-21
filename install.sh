#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Superkeet"
BUNDLE_NAME="${APP_NAME}.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
BUNDLE_DIR="${SCRIPT_DIR}/${BUNDLE_NAME}"
ENTITLEMENTS_PATH="${SCRIPT_DIR}/Resources/Superkeet.entitlements"
PARAKEET_BINARY_PATH="${PARAKEET_BINARY_PATH:-}"
PARAKEET_SOURCE_DIR="${PARAKEET_SOURCE_DIR:-}"
PARAKEET_OVERRIDE="${PARAKEET_CLI_PATH:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
AUTO_IDENTITY=0
PARAKEET_REPOSITORY_URL="https://github.com/lucataco/parakeet-cli.git"
PARAKEET_REF="${PARAKEET_REF:-v0.1.7}"
LOCAL_PARAKEET_SOURCE_DIR="${SCRIPT_DIR}/.build/parakeet-cli-${PARAKEET_REF}"

if [[ -z "$PARAKEET_SOURCE_DIR" && -f "${SCRIPT_DIR}/../../Formulae/parakeet-cli/Cargo.toml" ]]; then
    PARAKEET_SOURCE_DIR="${SCRIPT_DIR}/../../Formulae/parakeet-cli"
fi

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

resolve_parakeet_binary() {
    local candidates=()

    if [[ -n "$PARAKEET_BINARY_PATH" ]]; then
        if [[ ! -x "$PARAKEET_BINARY_PATH" ]]; then
            printf 'PARAKEET_BINARY_PATH is not executable: %s\n' "$PARAKEET_BINARY_PATH" >&2
            return 1
        fi
        printf '%s\n' "$PARAKEET_BINARY_PATH"
        return 0
    fi

    if [[ -n "$PARAKEET_OVERRIDE" ]]; then
        if [[ ! -x "$PARAKEET_OVERRIDE" ]]; then
            printf 'PARAKEET_CLI_PATH is not executable: %s\n' "$PARAKEET_OVERRIDE" >&2
            return 1
        fi
        printf '%s\n' "$PARAKEET_OVERRIDE"
        return 0
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
    cargo build --release --locked --bin parakeet --manifest-path "${source_dir}/Cargo.toml"
}

bootstrap_local_parakeet_cli() {
    require_command git
    require_command cargo

    printf '==> Preparing parakeet-cli %s in %s...\n' "$PARAKEET_REF" "$LOCAL_PARAKEET_SOURCE_DIR"
    if [[ ! -f "${LOCAL_PARAKEET_SOURCE_DIR}/Cargo.toml" ]]; then
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
    if [[ " $binary_archs " != *" $host_arch "* ]]; then
        printf 'Parakeet binary (%s) does not match host architecture (%s).\n' "$binary_archs" "$host_arch" >&2
        printf 'Rebuild parakeet for %s before installing.\n' "$host_arch" >&2
        exit 1
    fi
}

require_command swift
require_command codesign

# An ad-hoc signature changes with every build, so macOS drops the Accessibility grant and
# asks again after each reinstall. A real identity from the keychain keeps the grant. Pass
# CODESIGN_IDENTITY explicitly to override, or CODESIGN_IDENTITY=- to force ad-hoc.
if [[ -z "$CODESIGN_IDENTITY" ]]; then
    for pattern in "Apple Development:" "Developer ID Application:" "Superkeet Dev"; do
        candidate="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${pattern}" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
        if [[ -n "$candidate" ]]; then
            CODESIGN_IDENTITY="$candidate"
            AUTO_IDENTITY=1
            break
        fi
    done
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
fi

if [[ -n "$PARAKEET_SOURCE_DIR" && -z "$PARAKEET_BINARY_PATH" && -z "$PARAKEET_OVERRIDE" ]]; then
    build_parakeet_source_dir "$PARAKEET_SOURCE_DIR"
fi

PARAKEET_BINARY="$(resolve_parakeet_binary || true)"
if [[ -z "$PARAKEET_BINARY" && ( -n "$PARAKEET_BINARY_PATH" || -n "$PARAKEET_OVERRIDE" ) ]]; then
    exit 1
fi
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
case "$("$PARAKEET_BINARY" protocol-version)" in
    1|2) ;;
    *)
    printf 'Superkeet requires parakeet-cli v0.1.6 or later (transcript protocol 1 or 2; v0.1.7 adds interim text). Rebuild the engine or set PARAKEET_SOURCE_DIR.\n' >&2
    exit 1
    ;;
esac

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
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    :
elif [[ "$AUTO_IDENTITY" == 1 ]]; then
    # A local development install needs no trusted timestamp (and no network round-trip for one).
    SIGN_ARGS+=(--timestamp=none)
else
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
