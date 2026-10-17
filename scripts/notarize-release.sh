#!/bin/bash
set -euo pipefail

# Usage: scripts/notarize-release.sh APP_BUNDLE ZIP_ARCHIVE KEYCHAIN_PROFILE
# The profile is configured with `xcrun notarytool store-credentials` and is
# read from the user's keychain; this script never accepts or stores secrets.

usage() {
  printf 'Usage: %s APP_BUNDLE ZIP_ARCHIVE KEYCHAIN_PROFILE\n' "$(basename "$0")" >&2
  exit 2
}

die() {
  printf 'notarize-release: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage

APP_PATH="$1"
ZIP_PATH="$2"
KEYCHAIN_PROFILE="$3"

case "$APP_PATH" in
  /*) ;;
  *) APP_PATH="$PWD/$APP_PATH" ;;
esac
case "$ZIP_PATH" in
  /*) ;;
  *) ZIP_PATH="$PWD/$ZIP_PATH" ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command xcrun
require_command codesign
require_command spctl
require_command ditto
require_command shasum
require_command python3

[[ -d "$APP_PATH" && "$APP_PATH" == *.app ]] || die "app bundle not found: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || die "app bundle is missing Contents/Info.plist"
[[ -d "$(dirname "$ZIP_PATH")" ]] || die "archive directory does not exist: $(dirname "$ZIP_PATH")"
[[ -n "$KEYCHAIN_PROFILE" ]] || die "keychain profile is empty"

# Always submit a fresh archive matching the app being stapled. This avoids a
# successful notarization of an older ZIP at the same output path.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

NOTARY_SUBMIT_JSON="${ZIP_PATH%.zip}.notarytool-submit.json"
NOTARY_LOG_JSON="${ZIP_PATH%.zip}.notarytool-log.json"

printf 'Submitting %s for notarization with profile %s\n' "$ZIP_PATH" "$KEYCHAIN_PROFILE"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_SUBMIT_JSON"

STATUS="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["status"])' "$NOTARY_SUBMIT_JSON")"
SUBMISSION_ID="$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d.get("id") or d.get("submissionId") or "")' "$NOTARY_SUBMIT_JSON")"
[[ -n "$SUBMISSION_ID" ]] || die "notarytool response did not include a submission id"

xcrun notarytool log "$SUBMISSION_ID" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --output-format json > "$NOTARY_LOG_JSON"

if [[ "$STATUS" != "Accepted" ]]; then
  printf 'Notarization status: %s\n' "$STATUS" >&2
  printf 'Notarization log: %s\n' "$NOTARY_LOG_JSON" >&2
  exit 1
fi

xcrun stapler staple "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
(
  cd "$(dirname "$ZIP_PATH")"
  shasum -a 256 "$(basename "$ZIP_PATH")"
) | tee "${ZIP_PATH%.zip}.sha256"
printf 'Notarized and stapled %s\n' "$APP_PATH"
printf 'Archive: %s\n' "$ZIP_PATH"

