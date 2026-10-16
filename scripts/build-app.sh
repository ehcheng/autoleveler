#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${APP_DIST_DIR:-$ROOT_DIR/dist}"
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command swift
require_command python3
require_command codesign
require_command otool
require_command file
[[ "$(uname -s)" == "Darwin" ]] || die "this script builds macOS bundles and must run on Darwin"
[[ "$(uname -m)" == "arm64" ]] || die "build must run on an arm64 host/toolchain"
[[ -f "$ROOT_DIR/Resources/Info.plist" ]] || die "missing parent-owned Resources/Info.plist"

mkdir -p "$DIST_DIR" "$GUI_SCRATCH_DIR" "$CLI_SCRATCH_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"
rm -rf "$APP_DIR"

export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_MODULE_CACHE"
swift build \
  -c "$CONFIGURATION" \
  --product AutolevelerApp \
  --arch arm64 \
  --disable-sandbox \
  --scratch-path "$GUI_SCRATCH_DIR"

GUI_BIN_PATH="$(swift build -c "$CONFIGURATION" --product AutolevelerApp --arch arm64 --disable-sandbox --scratch-path "$GUI_SCRATCH_DIR" --show-bin-path)"
[[ -x "$GUI_BIN_PATH/AutolevelerApp" ]] || die "SwiftPM did not produce AutolevelerApp"

swift build \
  -c "$CONFIGURATION" \
  --product autoleveler \
  --arch arm64 \
  --disable-sandbox \
  --scratch-path "$CLI_SCRATCH_DIR"

CLI_BIN_PATH="$(swift build -c "$CONFIGURATION" --product autoleveler --arch arm64 --disable-sandbox --scratch-path "$CLI_SCRATCH_DIR" --show-bin-path)"
[[ -x "$CLI_BIN_PATH/autoleveler" ]] || die "SwiftPM did not produce autoleveler"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$GUI_BIN_PATH/AutolevelerApp" "$APP_DIR/Contents/MacOS/AutolevelerApp"
cp "$CLI_BIN_PATH/autoleveler" "$APP_DIR/Contents/MacOS/autoleveler"
chmod 755 "$APP_DIR/Contents/MacOS/AutolevelerApp" "$APP_DIR/Contents/MacOS/autoleveler"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

"$ROOT_DIR/scripts/build-media-tools.sh"
python3 "$ROOT_DIR/scripts/bundle-tools.py" "$APP_DIR"

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

# Sign helpers before the containing app so the final signature covers the
# exact nested code that Gatekeeper will verify.
for helper in "$APP_DIR/Contents/Helpers/ffmpeg" "$APP_DIR/Contents/Helpers/ffprobe"; do
  codesign --force --timestamp=none --sign - "$helper"
done
codesign --force --timestamp=none --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

ZIP_PATH="$DIST_DIR/Autoleveler-macOS-arm64.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

printf 'Built %s (%s)\n' "$APP_DIR" "$(du -sh "$APP_DIR" | awk '{print $1}')"
printf 'Archive: %s (%s)\n' "$ZIP_PATH" "$(du -sh "$ZIP_PATH" | awk '{print $1}')"
