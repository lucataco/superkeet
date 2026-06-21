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
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

validate_release_prerequisites() {
    if [[ "$REQUIRE_SIGNING" != "1" ]]; then
        return 0
    fi

    if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
        printf 'Production releases require CODESIGN_IDENTITY. Refusing to publish an ad-hoc signed artifact.\n' >&2
        exit 1
    fi

    if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_TEAM_ID" || -z "$NOTARY_PASSWORD" ]]; then
        printf 'Production releases require NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD.\n' >&2
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
        require_command cargo
        printf '==> Building bundled parakeet from %s...\n' "$PARAKEET_SOURCE_DIR"
        cargo build --release --bin parakeet --manifest-path "${PARAKEET_SOURCE_DIR}/Cargo.toml"
    fi
}

zip_app() {
    local zip_path="$1"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$zip_path"
}

notarization_enabled() {
    [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" && "$CODESIGN_IDENTITY" != "-" ]]
}

notarize_and_staple() {
    local zip_path="$1"
    if ! notarization_enabled; then
        return 0
    fi

    require_command xcrun
    require_command spctl

    printf '==> Submitting artifact for notarization...\n'
    xcrun notarytool submit "$zip_path" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait

    printf '==> Stapling notarization ticket...\n'
    xcrun stapler staple "$BUNDLE_DIR"
    xcrun stapler validate "$BUNDLE_DIR"
    codesign --verify --deep --strict "$BUNDLE_DIR"
    spctl -a -t exec -vv "$BUNDLE_DIR"
}

verify_audio_entitlement() {
    local target="$1"
    if ! codesign -d --entitlements :- "$target" 2>/dev/null | grep -q 'com.apple.security.device.audio-input'; then
        printf 'Missing audio-input entitlement on %s\n' "$target" >&2
        exit 1
    fi
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
        printf 'Rebuild parakeet for %s before packaging.\n' "$host_arch" >&2
        exit 1
    fi
}

require_command swift
require_command codesign
require_command ditto
require_command grep
require_command shasum
require_command /usr/libexec/PlistBuddy

validate_release_prerequisites

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

verify_parakeet_architecture "$PARAKEET_BINARY"

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

codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS_PATH" "$BUNDLE_DIR"

printf '==> Verifying code signature...\n'
codesign --verify --deep --strict "$BUNDLE_DIR"
verify_audio_entitlement "$BUNDLE_DIR/Contents/Resources/bin/parakeet"
verify_audio_entitlement "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

printf '==> Creating release archive...\n'
zip_app "$ZIP_PATH"
notarize_and_staple "$ZIP_PATH"

if notarization_enabled; then
    printf '==> Repacking notarized app...\n'
    zip_app "$ZIP_PATH"
fi

(cd "$DIST_DIR" && shasum -a 256 "$ZIP_FILENAME" > "$(basename "$SHA_PATH")")

printf '\nCreated release artifacts:\n'
printf '  %s\n' "$ZIP_PATH"
printf '  %s\n' "$SHA_PATH"
printf 'Bundled speech engine: %s\n' "$PARAKEET_BINARY"
printf 'Signing identity: %s\n' "$CODESIGN_IDENTITY"
