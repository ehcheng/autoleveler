#!/bin/bash
set -euo pipefail

# Build the media helpers from source so the app never inherits a developer's
# Homebrew or SDK-dependent FFmpeg build.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MEDIA_TOOLS_BUILD_ROOT:-$ROOT_DIR/.build/media-tools}"
DIST_DIR="${MEDIA_TOOLS_DIST_DIR:-$ROOT_DIR/dist/media-tools}"
TARGET="arm64-apple-macos14"
MACOS_MIN="14.0"
JOBS="${MEDIA_TOOLS_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || printf '2')}"

FFMPEG_VERSION="9.0.2"
FFMPEG_ARCHIVE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_ARCHIVE}"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

LAME_VERSION="3.100"
LAME_ARCHIVE="lame-${LAME_VERSION}.tar.gz"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/${LAME_ARCHIVE}"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

DOWNLOAD_DIR="$BUILD_ROOT/downloads"
SOURCE_DIR="$BUILD_ROOT/sources"
PREFIX="$BUILD_ROOT/prefix"
FFMPEG_PREFIX="$BUILD_ROOT/ffmpeg-prefix-${FFMPEG_VERSION}"
THIRD_PARTY_DIR="$DIST_DIR/third-party-sources"

die() {
  printf 'build-media-tools: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

download_and_verify() {
  local url="$1" archive="$2" expected="$3"
  local path="$DOWNLOAD_DIR/$archive"
  if [[ ! -f "$path" ]]; then
    curl --fail --location --retry 3 --retry-delay 1 --proto '=https' --output "$path" "$url"
  fi
  printf '%s  %s\n' "$expected" "$path" | shasum -a 256 -c - >/dev/null \
    || die "SHA-256 verification failed for $archive"
}

extract_once() {
  local archive="$1" directory="$2" expected_directory="$3"
  if [[ ! -d "$directory/$expected_directory" ]]; then
    tar -xf "$DOWNLOAD_DIR/$archive" -C "$directory"
  fi
}

verify_binary() {
  local binary="$1"
  [[ -x "$binary" ]] || die "missing executable: $binary"
  file "$binary" | grep -q 'arm64' || die "wrong architecture in $binary"
  otool -l "$binary" | awk '
    /LC_BUILD_VERSION/ { in_build=1; next }
    in_build && /minos/ {
      found=1
      if ($2 ~ /^14\./) valid=1
      in_build=0
    }
    END { exit (found && valid ? 0 : 1) }
  ' || die "expected macOS 14 minimum load command in $binary"

  # Static FFmpeg/LAME must not pull Homebrew, MacPorts, or another bundled
  # library into the app. macOS system libraries are part of the platform.
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*|/System/Volumes/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      '') ;;
      *) die "non-system dynamic dependency in $binary: $dependency" ;;
    esac
  done < <(otool -L "$binary" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*$/\1/p')
}

require_command curl
require_command shasum
require_command tar
require_command make
require_command clang
require_command otool
require_command file

mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$PREFIX" "$FFMPEG_PREFIX" "$DIST_DIR" "$THIRD_PARTY_DIR"
download_and_verify "$FFMPEG_URL" "$FFMPEG_ARCHIVE" "$FFMPEG_SHA256"
download_and_verify "$LAME_URL" "$LAME_ARCHIVE" "$LAME_SHA256"
extract_once "$LAME_ARCHIVE" "$SOURCE_DIR" "lame-${LAME_VERSION}"
extract_once "$FFMPEG_ARCHIVE" "$SOURCE_DIR" "ffmpeg-${FFMPEG_VERSION}"

COMMON_CFLAGS="-arch arm64 -mmacosx-version-min=${MACOS_MIN} -O2"
COMMON_LDFLAGS="-arch arm64 -mmacosx-version-min=${MACOS_MIN}"

if [[ ! -f "$PREFIX/lib/libmp3lame.a" ]]; then
  (
    cd "$SOURCE_DIR/lame-${LAME_VERSION}"
    make distclean >/dev/null 2>&1 || true
    CFLAGS="$COMMON_CFLAGS" \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="$COMMON_LDFLAGS" \
      ./configure \
        --prefix="$PREFIX" \
        --host=arm-apple-darwin \
        --disable-shared \
        --enable-static \
        --disable-frontend
    make -j"$JOBS"
    make install
  )
fi

if [[ ! -x "$FFMPEG_PREFIX/bin/ffmpeg" || ! -x "$FFMPEG_PREFIX/bin/ffprobe" ]]; then
  (
    cd "$SOURCE_DIR/ffmpeg-${FFMPEG_VERSION}"
    make distclean >/dev/null 2>&1 || true
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    CFLAGS="$COMMON_CFLAGS -I$PREFIX/include" \
    LDFLAGS="$COMMON_LDFLAGS -L$PREFIX/lib" \
      ./configure \
        --prefix="$FFMPEG_PREFIX" \
        --arch=arm64 \
        --target-os=darwin \
        --cc=clang \
        --disable-autodetect \
        --disable-debug \
        --disable-doc \
        --disable-htmlpages \
        --disable-manpages \
        --disable-podpages \
        --disable-txtpages \
        --disable-network \
        --disable-ffplay \
        --disable-avdevice \
        --disable-shared \
        --enable-static \
        --enable-libmp3lame \
        --enable-encoder=aac \
        --enable-decoder=aac \
        --extra-cflags="-I$PREFIX/include $COMMON_CFLAGS" \
        --extra-ldflags="-L$PREFIX/lib $COMMON_LDFLAGS"
    make -j"$JOBS"
    make install
  )
fi

rm -f "$DIST_DIR/ffmpeg" "$DIST_DIR/ffprobe"
rm -rf "$THIRD_PARTY_DIR"
mkdir -p "$THIRD_PARTY_DIR"
cp "$FFMPEG_PREFIX/bin/ffmpeg" "$DIST_DIR/ffmpeg"
cp "$FFMPEG_PREFIX/bin/ffprobe" "$DIST_DIR/ffprobe"
chmod 755 "$DIST_DIR/ffmpeg" "$DIST_DIR/ffprobe"
verify_binary "$DIST_DIR/ffmpeg"
verify_binary "$DIST_DIR/ffprobe"

# Preserve the exact source inputs and licensing material beside the binaries.
cp "$DOWNLOAD_DIR/$FFMPEG_ARCHIVE" "$THIRD_PARTY_DIR/$FFMPEG_ARCHIVE"
cp "$DOWNLOAD_DIR/$LAME_ARCHIVE" "$THIRD_PARTY_DIR/$LAME_ARCHIVE"
mkdir -p "$DIST_DIR/licenses"
cp "$SOURCE_DIR/ffmpeg-${FFMPEG_VERSION}/LICENSE.md" "$DIST_DIR/licenses/FFmpeg-LICENSE.md"
cp "$SOURCE_DIR/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" "$DIST_DIR/licenses/FFmpeg-COPYING.LGPLv2.1"
cp "$SOURCE_DIR/ffmpeg-${FFMPEG_VERSION}/COPYING.GPLv2" "$DIST_DIR/licenses/FFmpeg-COPYING.GPLv2"
cp "$SOURCE_DIR/ffmpeg-${FFMPEG_VERSION}/COPYING.GPLv3" "$DIST_DIR/licenses/FFmpeg-COPYING.GPLv3"
cp "$SOURCE_DIR/lame-${LAME_VERSION}/LICENSE" "$DIST_DIR/licenses/LAME-LICENSE"
cp "$SOURCE_DIR/lame-${LAME_VERSION}/COPYING" "$DIST_DIR/licenses/LAME-COPYING"

{
cat <<EOF
Autoleveler media helper build
Target: ${TARGET}
Minimum macOS: ${MACOS_MIN}
FFmpeg: ${FFMPEG_VERSION}
FFmpeg source: ${FFMPEG_URL}
FFmpeg SHA-256: ${FFMPEG_SHA256}
LAME: ${LAME_VERSION}
LAME source: ${LAME_URL}
LAME SHA-256: ${LAME_SHA256}
Helpers: ffmpeg, ffprobe
Compiler: $(clang --version | sed -n '1p')
FFmpeg build configuration:
EOF
"$DIST_DIR/ffmpeg" -buildconf
} > "$DIST_DIR/BUILD-MANIFEST.txt"

printf 'Built %s and %s\n' "$DIST_DIR/ffmpeg" "$DIST_DIR/ffprobe"
