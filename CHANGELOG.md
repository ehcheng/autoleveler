# Changelog

## 1.0.1 — 2026-10-16

- Detect speech on every channel; preserve channel balance and limit boosts when another channel is already loud.
- Convert MP4 text subtitles for MKV exports and check subtitle compatibility before processing audio.
- Include files added while a batch is processing.
- Read only the tail of processing error logs to bound memory use.
- Require bundled processing tools in packaged apps.
- Respect custom media-tool output paths and rebuild cached helpers when build inputs change.
- Add regression tests for subtitle exports, multichannel speech, queue updates, helper discovery, error logs, and build caching.

## 1.0.0 — 2026-10-16

First stable release, build 2.

- Promoted the beta to version 1.0.0.
- Added MIT licensing for Autoleveler source.
- Rewrote the README around installation, dialogue leveling, and practical limits.
- Added Developer ID signing and notarization support to release packaging.

## 1.0.0 beta — 2026-10-16

Initial beta for Apple silicon Macs running macOS 14 or later.

- Local speech-aware dialogue leveling with compression and peak limiting.
- Native drag-and-drop batch queue and command-line interface.
- AAC, MP3, and 24-bit PCM exports; video streams copied without re-encoding.
- Cancellation, temporary-file cleanup, and interrupted-job recovery.
- Pending and retried files display “Queued.”
- New “Drag and level!” slogan and clickable echeng.com credit.
