#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Superkeet"
BUNDLE_NAME="${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
BUILD_DIR="${SCRIPT_DIR}/.build/release"
BUNDLE_DIR="${SCRIPT_DIR}/${BUNDLE_NAME}"

echo "==> Building ${APP_NAME} (release)..."
swift build -c release

echo "==> Assembling ${BUNDLE_NAME}..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"
mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"

cp "${BUILD_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"
cp "${SCRIPT_DIR}/Resources/Info.plist" "${BUNDLE_DIR}/Contents/"
cp "${SCRIPT_DIR}/Resources/Superkeet.entitlements" "${BUNDLE_DIR}/Contents/Resources/"

# Embed Sparkle.framework into the bundle
cp -a "${BUILD_DIR}/Sparkle.framework" "${BUNDLE_DIR}/Contents/Frameworks/"

# Add rpath so the binary can find frameworks in Contents/Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

echo "==> Signing ${BUNDLE_NAME}..."
# Sign inside-out: nested components first, then executable, then outer bundle

# Sign Sparkle XPC services
codesign --force --sign - \
    --options runtime \
    "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - \
    --options runtime \
    "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"

# Sign Sparkle helper executables
codesign --force --sign - \
    --options runtime \
    "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - \
    --options runtime \
    "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"

# Sign the Sparkle framework itself
codesign --force --sign - \
    --options runtime \
    "${BUNDLE_DIR}/Contents/Frameworks/Sparkle.framework"

# Sign the main executable
codesign --force --sign - \
    --options runtime \
    --entitlements "${SCRIPT_DIR}/Resources/Superkeet.entitlements" \
    "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

# Sign the outer app bundle
codesign --force --sign - \
    --options runtime \
    --entitlements "${SCRIPT_DIR}/Resources/Superkeet.entitlements" \
    "${BUNDLE_DIR}"

echo "==> Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/${BUNDLE_NAME}"
mv "${BUNDLE_DIR}" "${INSTALL_DIR}/"

echo ""
echo "Done! ${APP_NAME} installed to ${INSTALL_DIR}/${BUNDLE_NAME}"
echo "Open it from Finder, Spotlight, or run:"
echo "  open \"${INSTALL_DIR}/${BUNDLE_NAME}\""
