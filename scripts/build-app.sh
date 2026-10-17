#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${APP_DIST_DIR:-$ROOT_DIR/dist}"
MEDIA_TOOLS_DIST_DIR="${MEDIA_TOOLS_DIST_DIR:-$DIST_DIR/media-tools}"
APP_NAME="Autoleveler.app"
APP_DIR="$DIST_DIR/$APP_NAME"
SCRATCH_ROOT="${SWIFT_SCRATCH_PATH:-$ROOT_DIR/.build}"
GUI_SCRATCH_DIR="${SWIFT_GUI_SCRATCH_PATH:-$SCRATCH_ROOT/gui}"
CLI_SCRATCH_DIR="${SWIFT_CLI_SCRATCH_PATH:-$SCRATCH_ROOT/cli}"
CONFIGURATION="release"
SWIFT_MODULE_CACHE="${SWIFT_MODULE_CACHE:-/private/tmp/autoleveler-swift-cache}"

die() {
  printf 'build-app: %s\n' "$*" >&2
  exit 1
}

swift_build() {
  local product="$1"
  local scratch_path="$2"
  local show_bin_path="${3:-false}"
  local args=(-c "$CONFIGURATION" --product "$product" --arch arm64)
  if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
    args+=(--build-system "$SWIFT_BUILD_SYSTEM")
  fi
  args+=(--disable-sandbox --scratch-path "$scratch_path")
  if [[ "$show_bin_path" == true ]]; then
    args+=(--show-bin-path)
  fi
  swift build "${args[@]}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command swift
require_command python3
require_command codesign
require_command otool
require_command file
require_command plutil
[[ "$(uname -s)" == "Darwin" ]] || die "this script builds macOS bundles and must run on Darwin"
[[ "$(uname -m)" == "arm64" ]] || die "build must run on an arm64 host/toolchain"
[[ -f "$ROOT_DIR/Resources/Info.plist" ]] || die "missing parent-owned Resources/Info.plist"

mkdir -p "$DIST_DIR" "$GUI_SCRATCH_DIR" "$CLI_SCRATCH_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"
rm -rf "$APP_DIR"

export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_MODULE_CACHE"
swift_build AutolevelerApp "$GUI_SCRATCH_DIR"

GUI_BIN_PATH="$(swift_build AutolevelerApp "$GUI_SCRATCH_DIR" true)"
[[ -x "$GUI_BIN_PATH/AutolevelerApp" ]] || die "SwiftPM did not produce AutolevelerApp"

swift_build autoleveler "$CLI_SCRATCH_DIR"

CLI_BIN_PATH="$(swift_build autoleveler "$CLI_SCRATCH_DIR" true)"
[[ -x "$CLI_BIN_PATH/autoleveler" ]] || die "SwiftPM did not produce autoleveler"

VERSION_DISPLAY="$("$CLI_BIN_PATH/autoleveler" --version)"
VERSION_DISPLAY="${VERSION_DISPLAY#Autoleveler }"
VERSION_NUMBER="${VERSION_DISPLAY%% *}"
VERSION_SLUG="${VERSION_DISPLAY// /-}"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION_NUMBER" "$APP_DIR/Contents/Info.plist"
plutil -insert AutolevelerDisplayVersion -string "$VERSION_DISPLAY" "$APP_DIR/Contents/Info.plist"
cp "$GUI_BIN_PATH/AutolevelerApp" "$APP_DIR/Contents/MacOS/AutolevelerApp"
cp "$CLI_BIN_PATH/autoleveler" "$APP_DIR/Contents/MacOS/autoleveler"
chmod 755 "$APP_DIR/Contents/MacOS/AutolevelerApp" "$APP_DIR/Contents/MacOS/autoleveler"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
for license in LICENSE LICENSE.md; do
  if [[ -f "$ROOT_DIR/$license" ]]; then
    cp "$ROOT_DIR/$license" "$APP_DIR/Contents/Resources/$license"
  fi
done

MEDIA_TOOLS_DIST_DIR="$MEDIA_TOOLS_DIST_DIR" "$ROOT_DIR/scripts/build-media-tools.sh"
python3 "$ROOT_DIR/scripts/bundle-tools.py" "$APP_DIR" --source "$MEDIA_TOOLS_DIST_DIR"

for binary in "$APP_DIR/Contents/MacOS/AutolevelerApp" "$APP_DIR/Contents/MacOS/autoleveler" \
  "$APP_DIR/Contents/Helpers/ffmpeg" "$APP_DIR/Contents/Helpers/ffprobe"; do
  file "$binary" | grep -q 'arm64' || die "wrong architecture in $binary"
  otool -l "$binary" | awk '
    /LC_BUILD_VERSION/ { in_load_command = 1; next }
    in_load_command && /minos/ { print $2; found = 1; in_load_command = 0 }
    in_load_command && /^Load command/ { in_load_command = 0 }
    END { if (!found) exit 1 }
  ' | grep -q '^14\.' || die "deployment target is not macOS 14 in $binary"
  otool -L "$binary" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*$/\1/p' | while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*|/System/Volumes/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      '') ;;
      *) die "non-system dynamic dependency in $binary: $dependency" ;;
    esac
  done
done

# Sign every executable before the containing app so the final signature
# covers the exact nested code that Gatekeeper will verify. Set
# CODE_SIGN_IDENTITY to a Developer ID Application identity for distribution;
# the default remains an ad-hoc signature for local builds.
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGNING_ARGS=(--force --options runtime)
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_ARGS+=(--timestamp=none --sign -)
else
  SIGNING_ARGS+=(--timestamp --sign "$SIGNING_IDENTITY")
fi
for helper in "$APP_DIR/Contents/Helpers/ffmpeg" "$APP_DIR/Contents/Helpers/ffprobe"; do
  codesign "${SIGNING_ARGS[@]}" "$helper"
done
for executable in "$APP_DIR/Contents/MacOS/autoleveler" "$APP_DIR/Contents/MacOS/AutolevelerApp"; do
  codesign "${SIGNING_ARGS[@]}" "$executable"
done
codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

ZIP_PATH="$DIST_DIR/Autoleveler-${VERSION_SLUG}-macOS-arm64.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

printf 'Built %s (%s)\n' "$APP_DIR" "$(du -sh "$APP_DIR" | awk '{print $1}')"
printf 'Archive: %s (%s)\n' "$ZIP_PATH" "$(du -sh "$ZIP_PATH" | awk '{print $1}')"
