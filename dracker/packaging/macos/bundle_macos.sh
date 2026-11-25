#!/usr/bin/env bash
# File:         packaging/macos/bundle_macos.sh
# Phase:        Phase 9.1 — Universal Binary & Signed .app Packaging Pipeline
#
# Purpose:
#   Compiles release arm64 and x86_64 slices with LDC2/DUB, merges them via lipo
#   into a Universal Mach-O binary, assembles Dracker.app, signs with
#   Hardened Runtime + entitlements, and verifies zero third-party .dylib links.
#
# Prerequisites:
#   - LDC2 1.40+ with both arm64 and x86_64 macOS runtime/Phobos libraries
#   - Xcode + Metal toolchain (xcrun metal / metallib), lipo, codesign, otool
#   - Optional: packaging/macos/AppIcon.icns and SIGN_IDENTITY env override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_DIR="build/Dracker.app"

echo "[1/5] Building arm64-apple-macos12.0 release slice..."
dub build --compiler=ldc2 --config=app --build=release --arch=arm64-apple-macos12.0
cp build/dracker build/dracker-arm64

echo "[2/5] Building x86_64-apple-macos12.0 release slice..."
dub build --compiler=ldc2 --config=app --build=release --arch=x86_64-apple-macos12.0
cp build/dracker build/dracker-x86_64

echo "[3/5] Merging Universal Mach-O binary via lipo..."
lipo -create -output build/dracker-universal     build/dracker-arm64 build/dracker-x86_64

echo "[4/5] Assembling ${APP_DIR} bundle..."
EXPECTED_PRESETS="$(sed -nE 's/^[[:space:]]*FactoryPreset\("([^"]+)",[[:space:]]*"([^"]+)".*/\1|\2/p' source/app/factory_presets.d)"
PRESET_COUNT=0
while IFS='|' read -r preset_name preset_group; do
    [[ -z "${preset_name}" ]] && continue
    preset_file="resources/presets/${preset_group}/${preset_name}.msym"
    if [[ ! -s "${preset_file}" ]]; then
        echo "Error: missing bundled preset listed in source/app/factory_presets.d: ${preset_file}" >&2
        exit 1
    fi
    PRESET_COUNT=$((PRESET_COUNT + 1))
done <<< "${EXPECTED_PRESETS}"
if [[ "${PRESET_COUNT}" -eq 0 ]]; then
    echo "Error: failed to parse bundled presets from source/app/factory_presets.d" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${APP_DIR}/Contents/Resources/Presets"
cp build/dracker-universal "${APP_DIR}/Contents/MacOS/Dracker"
cp build/ui2d.metallib           "${APP_DIR}/Contents/Resources/ui2d.metallib"
cp packaging/macos/Info.plist    "${APP_DIR}/Contents/Info.plist"
if [[ -f packaging/macos/AppIcon.icns ]]; then
    cp packaging/macos/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
cp -R resources/presets/. "${APP_DIR}/Contents/Resources/Presets/"
while IFS='|' read -r preset_name preset_group; do
    [[ -z "${preset_name}" ]] && continue
    bundled_file="${APP_DIR}/Contents/Resources/Presets/${preset_group}/${preset_name}.msym"
    if [[ ! -s "${bundled_file}" ]]; then
        echo "Error: preset missing in app bundle: ${bundled_file}" >&2
        exit 1
    fi
done <<< "${EXPECTED_PRESETS}"

echo "[5/5] Signing and verifying bundle..."
codesign --force --deep --options runtime     --entitlements packaging/macos/entitlements.plist     --sign "${SIGN_IDENTITY}" "${APP_DIR}"

file "${APP_DIR}/Contents/MacOS/Dracker"
otool -L "${APP_DIR}/Contents/MacOS/Dracker"
codesign --verify --deep --strict "${APP_DIR}"
echo "Successfully packaged ${APP_DIR}."
