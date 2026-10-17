#!/bin/bash
set -euo pipefail

# Exercise cache and custom-distribution behavior without compiling FFmpeg.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/autoleveler-media-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FIXTURES="$TEMP_ROOT/fixtures"
FAKE_BIN="$TEMP_ROOT/bin"
mkdir -p "$FIXTURES" "$FAKE_BIN"

mkdir -p "$TEMP_ROOT/lame-3.100" "$TEMP_ROOT/ffmpeg-9.0.2"
for source in lame-3.100 ffmpeg-9.0.2; do
  cat > "$TEMP_ROOT/$source/configure" <<'EOF'
#!/bin/bash
set -euo pipefail
prefix=
for arg in "$@"; do
  case "$arg" in
    --prefix=*) prefix="${arg#--prefix=}" ;;
  esac
done
printf '%s\n' "$prefix" > .autoleveler-test-prefix
EOF
  chmod +x "$TEMP_ROOT/$source/configure"
done
printf 'license\n' > "$TEMP_ROOT/lame-3.100/LICENSE"
printf 'copying\n' > "$TEMP_ROOT/lame-3.100/COPYING"
for file in LICENSE.md COPYING.LGPLv2.1 COPYING.GPLv2 COPYING.GPLv3; do
  printf 'license\n' > "$TEMP_ROOT/ffmpeg-9.0.2/$file"
done
tar -czf "$FIXTURES/lame-3.100.tar.gz" -C "$TEMP_ROOT" lame-3.100
tar -cJf "$FIXTURES/ffmpeg-9.0.2.tar.xz" -C "$TEMP_ROOT" ffmpeg-9.0.2

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
output=
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --output ]]; then
    i=$((i + 1)); output="${!i}"
  fi
done
cp "$TEST_FIXTURES/$(basename "$output")" "$output"
EOF
cat > "$FAKE_BIN/clang" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' "fake-clang ${TEST_CLANG_VERSION:-one}"
fi
EOF
cat > "$FAKE_BIN/sysctl" <<'EOF'
#!/bin/bash
printf '2\n'
EOF
cat > "$FAKE_BIN/file" <<'EOF'
#!/bin/bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
EOF
cat > "$FAKE_BIN/otool" <<'EOF'
#!/bin/bash
if [[ "$1" == -l ]]; then
  printf 'LC_BUILD_VERSION\n minos 14.0\n'
else
  printf '%s:\n' "$2"
  printf '\t/usr/lib/libSystem.B.dylib\n'
fi
EOF
cat > "$FAKE_BIN/make" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "$*" == *"distclean"* || "$*" != *"install"* ]]; then
  exit 0
fi
prefix="$(<.autoleveler-test-prefix)"
if [[ "$(basename "$PWD")" == lame-3.100 ]]; then
  mkdir -p "$prefix/lib"
  : > "$prefix/lib/libmp3lame.a"
else
  mkdir -p "$prefix/bin"
  for tool in ffmpeg ffprobe; do
    printf '#!/bin/sh\necho fake buildconf\n' > "$prefix/bin/$tool"
    chmod +x "$prefix/bin/$tool"
  done
fi
printf '%s\n' configure >> "$TEST_BUILD_LOG"
EOF
chmod +x "$FAKE_BIN"/*

SCRIPT="$TEMP_ROOT/build-media-tools.sh"
cp "$ROOT_DIR/scripts/build-media-tools.sh" "$SCRIPT"
ffmpeg_sha="$(shasum -a 256 "$FIXTURES/ffmpeg-9.0.2.tar.xz" | awk '{print $1}')"
lame_sha="$(shasum -a 256 "$FIXTURES/lame-3.100.tar.gz" | awk '{print $1}')"
sed -i '' "s/FFMPEG_SHA256=\"[^\"]*\"/FFMPEG_SHA256=\"$ffmpeg_sha\"/; s/LAME_SHA256=\"[^\"]*\"/LAME_SHA256=\"$lame_sha\"/" "$SCRIPT"

export PATH="$FAKE_BIN:$PATH"
export TEST_FIXTURES="$FIXTURES"
export TEST_BUILD_LOG="$TEMP_ROOT/build.log"
export MEDIA_TOOLS_BUILD_ROOT="$TEMP_ROOT/build"
export MEDIA_TOOLS_DIST_DIR="$TEMP_ROOT/custom-dist"
export TEST_CLANG_VERSION=one
"$SCRIPT"
[[ -x "$MEDIA_TOOLS_DIST_DIR/ffmpeg" && -x "$MEDIA_TOOLS_DIST_DIR/ffprobe" ]]
first_count="$(wc -l < "$TEST_BUILD_LOG")"
"$SCRIPT"
[[ "$(wc -l < "$TEST_BUILD_LOG")" == "$first_count" ]]
export TEST_CLANG_VERSION=two
"$SCRIPT"
[[ "$(wc -l < "$TEST_BUILD_LOG")" == $((first_count + 2)) ]]
# A configure edit must invalidate the same component without a separately edited stamp.
sed -i '' 's/--disable-debug/--enable-debug/' "$SCRIPT"
"$SCRIPT"
[[ "$(wc -l < "$TEST_BUILD_LOG")" == $((first_count + 3)) ]]
# LAME configuration changes must rebuild LAME and its dependent FFmpeg.
sed -i '' 's/--disable-frontend/--enable-frontend/' "$SCRIPT"
"$SCRIPT"
[[ "$(wc -l < "$TEST_BUILD_LOG")" == $((first_count + 5)) ]]
printf 'build-media-tools regression checks passed\n' 
