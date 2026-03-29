#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFO_PLIST="${REPO_DIR}/Resources/Info.plist"
ENTITLEMENTS_PATH="${REPO_DIR}/Resources/Superkeet.entitlements"
BUILD_DIR="${REPO_DIR}/.build/release"
DIST_DIR="${DIST_DIR:-${REPO_DIR}/dist}"
APP_NAME="Superkeet"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_DIR="${DIST_DIR}/${BUNDLE_NAME}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
PARAKEET_BINARY_PATH="${PARAKEET_BINARY_PATH:-}"
PARAKEET_SOURCE_DIR="${PARAKEET_SOURCE_DIR:-}"
PARAKEET_OVERRIDE="${PARAKEET_CLI_PATH:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
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
        candidates+=("${PARAKEET_SOURCE_DIR}/target/release/parakeet")
    fi

    candidates+=(
        "${REPO_DIR}/../parakeet-cli/target/release/parakeet"
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

build_parakeet_if_needed() {
    if [[ -n "$PARAKEET_SOURCE_DIR" && ! -x "${PARAKEET_SOURCE_DIR}/target/release/parakeet" ]]; then
        printf '==> Building bundled parakeet from %s...\n' "$PARAKEET_SOURCE_DIR"
        cargo build --release --bin parakeet --manifest-path "${PARAKEET_SOURCE_DIR}/Cargo.toml"
    fi
}

zip_app() {
    local zip_path="$1"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$zip_path"
}

notarize_and_staple() {
    local zip_path="$1"
    local notarization_enabled=false

    if [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" && "$CODESIGN_IDENTITY" != "-" ]]; then
        notarization_enabled=true
    fi

    if [[ "$notarization_enabled" != true ]]; then
        return 0
    fi

    printf '==> Submitting artifact for notarization...\n'
    xcrun notarytool submit "$zip_path" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait

    printf '==> Stapling notarization ticket...\n'
    xcrun stapler staple "$BUNDLE_DIR"
    codesign --verify --deep --strict "$BUNDLE_DIR"
}

require_command swift
require_command cargo
require_command codesign
require_command ditto
require_command shasum
require_command /usr/libexec/PlistBuddy

VERSION="$(plist_value CFBundleShortVersionString)"
ARCHIVE_BASENAME="Superkeet-${VERSION}"
ZIP_PATH="${DIST_DIR}/${ARCHIVE_BASENAME}.zip"
SHA_PATH="${ZIP_PATH}.sha256"
ZIP_FILENAME="$(basename "$ZIP_PATH")"

mkdir -p "$DIST_DIR"

build_parakeet_if_needed
PARAKEET_BINARY="$(resolve_parakeet_binary || true)"
if [[ -z "$PARAKEET_BINARY" ]]; then
    cat >&2 <<'EOF'
Unable to find a runnable `parakeet` binary to bundle.

Set one of:
  PARAKEET_SOURCE_DIR=/absolute/path/to/parakeet-cli
  PARAKEET_BINARY_PATH=/absolute/path/to/parakeet
  PARAKEET_CLI_PATH=/absolute/path/to/parakeet
EOF
    exit 1
fi

printf '==> Building %s (release)...\n' "$APP_NAME"
swift build -c release --package-path "$REPO_DIR"

printf '==> Assembling %s...\n' "$BUNDLE_NAME"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources/bin"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
cp "$INFO_PLIST" "$BUNDLE_DIR/Contents/"
cp "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/Resources/"
cp "$REPO_DIR/Resources/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/"
cp "$PARAKEET_BINARY" "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
chmod 755 "$BUNDLE_DIR/Contents/Resources/bin/parakeet"

printf '==> Signing %s...\n' "$BUNDLE_NAME"
SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY" --options runtime)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR"

printf '==> Verifying code signature...\n'
codesign --verify --deep --strict "$BUNDLE_DIR"

printf '==> Creating release archive...\n'
zip_app "$ZIP_PATH"
notarize_and_staple "$ZIP_PATH"

if [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" && "$CODESIGN_IDENTITY" != "-" ]]; then
    printf '==> Repacking notarized app...\n'
    zip_app "$ZIP_PATH"
fi

(cd "$DIST_DIR" && shasum -a 256 "$ZIP_FILENAME" > "$(basename "$SHA_PATH")")

printf '\nCreated release artifacts:\n'
printf '  %s\n' "$ZIP_PATH"
printf '  %s\n' "$SHA_PATH"
printf 'Bundled speech engine: %s\n' "$PARAKEET_BINARY"
printf 'Signing identity: %s\n' "$CODESIGN_IDENTITY"
