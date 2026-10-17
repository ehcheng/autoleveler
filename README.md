# Autoleveler

Drag and level! *Automatic dialogue leveling for audio and video.*

A recording can be too quiet throughout, or change volume every time someone moves away from the microphone. Autoleveler brings up quiet speech and compresses louder passages, while keeping pauses close to their original level. Drop in a batch of audio or video files and process them on your Mac.

I wanted the convenience of Levelator for video with uneven dialogue. Autoleveler uses speech detection to decide where amplification makes sense. Video passes through without re-encoding, so there's no generation loss in the picture.

Requires an Apple silicon Mac running macOS 14 or later. FFmpeg and FFprobe are included; you don't need Homebrew or Python to use the app. Processing stays on your Mac, with no uploads or account required.

## Install and use

Download the ZIP from [GitHub Releases](https://github.com/ehcheng/autoleveler/releases), unzip it, and move Autoleveler to Applications.

1. Drop files into the window, or choose File → Open (⌘O).
2. Choose Match input to keep video when present, Audio only to extract audio, or Video + audio to require video output.
3. Keep the default AAC at 192 kb/s, or choose MP3 or 24-bit PCM. You can also choose an output folder.
4. Click Start Processing (⌘Return).

By default, output goes beside the original file with a `-leveled` suffix. The original is untouched. If `interview-leveled.mov` already exists, the next output is `interview-leveled-2.mov`. Click Show to reveal a finished file in Finder.

Cancel with the button or ⌘. Autoleveler stops its processing tools and deletes temporary audio and partial exports before cancellation completes. Quitting does the same for the active job. You can retry failed or cancelled files, or remove them from the queue. After an interrupted run, Autoleveler cleans up abandoned workspaces on the next launch.

## What to expect

The best use case is dialogue recorded at inconsistent levels: a quiet interview, clips recorded with different microphones, or someone moving around while speaking. Speech detection helps avoid amplifying an empty room just because it's quiet.

There are limits. A distant voice buried in noise will still have noise when it's louder. The detector can miss whispers or mistake other sounds for speech. When it finds no confident speech, Autoleveler reports that and applies no gain boost (compression and peak limiting still apply). There is no noise gate to cut off words or remove room ambience.

Autoleveler uses its own processing algorithm. It doesn't reproduce Levelator's proprietary algorithm, and it doesn't target a specified integrated LUFS value for broadcast delivery.

## Output formats

| Selection | Output |
| --- | --- |
| AAC audio | `.m4a`, default 192 kb/s |
| MP3 audio | `.mp3`, default 192 kb/s |
| PCM audio | `.wav`, 24-bit, RF64 when needed |
| Video + AAC | Original MP4/MOV where compatible; otherwise MKV |
| Video + PCM | MOV for compatible source codecs; otherwise MKV |
| Video + MP3 | MKV |

Processed audio is 48 kHz. In video exports, Autoleveler processes separate audio tracks and preserves their channel counts and timing. It also retains available subtitles, chapters, and metadata; MKV exports retain attachments. Data and timecode streams are omitted. Audio-only exports use the default audio track, or the first track if none is marked default. Embedded album art doesn't count as video.

MP3 supports mono or stereo. Autoleveler rejects multichannel MP3 requests rather than downmixing them. Input support depends on FFmpeg's demuxers and decoders. Damaged, encrypted, DRM-protected, or unsupported files produce an error. Networking is disabled in the bundled FFmpeg tools.

## Command line

The CLI is inside the app. These examples assume you've installed it in Applications:

```sh
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --help
/Applications/Autoleveler.app/Contents/MacOS/autoleveler interview.mov
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --audio --format mp3 --bitrate 192 -o ./exports clip.mov
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --format pcm take1.wav take2.wav
```

Use `--` before filenames that begin with a hyphen. `-o` or `--output-dir` selects an output folder. Output paths go to stdout; progress and errors go to stderr. A batch continues after a file error. Ctrl-C or SIGTERM cancels the active job, cleans up, and stops the batch.

Exit codes are `0` for success, `1` for file failures, `2` for invalid arguments or setup errors, and `130` for cancellation.

## How leveling works

Apple's Sound Analysis classifier identifies likely speech locally, without transcription or a downloaded model (Apple, n.d.). Autoleveler measures channel energy in 50 ms blocks and estimates the background level. It then calculates a smooth gain curve around speech, targeting approximately −20 dBFS RMS with a maximum boost of 24 dB. Gain returns toward unity during pauses. Channels share a gain curve to preserve their relative balance.

After leveling, FFmpeg applies gentle compression and an oversampled limiter with 2 dB of sample-peak headroom before encoding (FFmpeg, n.d.). Autoleveler compensates for the limiter's lookahead delay to preserve audio timing.

Decoded audio is stored temporarily on disk. Long multichannel recordings need substantial free space on the Mac's temporary volume. The partial export is staged in the output folder and renamed only when processing finishes.

## Build and verify

Building requires Xcode command-line tools, Swift 5.9 or later, an Apple silicon Mac, and internet access for the first media-tool build.

```sh
./scripts/build-app.sh
```

The script verifies pinned FFmpeg and LAME source checksums, builds static arm64 helpers for macOS 14, and packages the app and CLI into `dist/`. Local builds are signed ad hoc. Set `CODE_SIGN_IDENTITY` to your Developer ID Application identity to sign a distribution build with Hardened Runtime and a secure timestamp. Third-party source archives, licenses, and build configuration are included in the app; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

To notarize a signed build, store your Apple credentials with `xcrun notarytool store-credentials` first, then run:

```sh
./scripts/notarize-release.sh \
  dist/Autoleveler.app \
  dist/Autoleveler-1.0.0-macOS-arm64.zip \
  YOUR_KEYCHAIN_PROFILE
```

The script submits the app to Apple, saves the notarization log, staples the ticket, checks Gatekeeper acceptance, and creates the final ZIP and SHA-256 checksum. It stops if notarization fails.

For development, `AUTOLEVELER_TOOLS=/path/to/tools` selects a folder containing both `ffmpeg` and `ffprobe`. An unpackaged build can also use installed tools.

```sh
swift test
python3 scripts/integration-test.py --cli "$(swift build --show-bin-path)/autoleveler"
```

The integration tests use macOS `say` for a speech fixture and an FFmpeg installation with `libx264` for video. You can supply a recording with `--speech-fixture /path/to/speech.wav`. Tests cover speech leveling, noise and silence, encoded peaks, export formats, copied video, track timing, output collisions, invalid inputs, and cancellation. To test a packaged app, pass its CLI path and set `AUTOLEVELER_TOOLS` to its `Contents/Helpers` folder.

Runtime testing during development was on macOS 26. The deployment target is macOS 14; runtime behavior on macOS 14 hasn't been verified.

Release notes are in [CHANGELOG.md](CHANGELOG.md). `Sources/AutolevelerCore/AppVersion.swift` defines the release version; `CFBundleVersion` in `Resources/Info.plist` identifies each distributed build.

## License and credits

Autoleveler's source is available under the [MIT license](LICENSE), copyright 2026 Eric Cheng. Bundled FFmpeg and LAME retain their own licenses, documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[Eric Cheng · echeng.com](https://echeng.com)

## References

Apple. n.d. “SNClassifySoundRequest.” *Apple Developer Documentation*. Accessed October 16, 2026. https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest/

FFmpeg. n.d. “FFmpeg Documentation” and “FFmpeg Filters Documentation.” Accessed October 16, 2026. https://ffmpeg.org/ffmpeg.html and https://ffmpeg.org/ffmpeg-filters.html.
