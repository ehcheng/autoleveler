# Autoleveler

A native Mac app for uneven dialogue. Drop in audio or video, bring quiet speech forward, and keep pauses quiet. Everything runs on your Mac.

**Requires Apple silicon and macOS 14 or later.** The packaged app includes FFmpeg and FFprobe; Homebrew and Python are not required to use it.

## Use the app

Open `dist/Autoleveler.app`, or unzip `dist/Autoleveler-macOS-arm64.zip`. You can move the app to Applications.

1. Drop one or more media files into the window, or choose **File → Open** (⌘O).
2. Choose **Match input**, **Audio only**, or **Video + audio**.
3. Keep AAC at 192 kb/s, or choose MP3 or 24-bit PCM. Choose a destination if needed.
4. Choose **Start Processing** (⌘Return).

Output defaults to the source folder, using `name-leveled.ext`. Existing files are never overwritten: subsequent outputs become `name-leveled-2.ext`, and so on. **Show** reveals the finished file in Finder. Failed or cancelled files can be retried or removed.

Cancel with the button or ⌘. Quitting also cancels the active job and waits for cleanup. Pending jobs remain unprocessed. Temporary audio and partial exports are deleted before cancellation completes. On the next launch, abandoned workspaces from an interrupted run are recovered without disturbing another running instance.

## Output formats

| Selection | Output |
| --- | --- |
| AAC audio | `.m4a`, default 192 kb/s |
| MP3 audio | `.mp3`, default 192 kb/s |
| PCM audio | `.wav`, 24-bit, RF64 when needed |
| Video + AAC | Original MP4/MOV where compatible; otherwise MKV |
| Video + PCM | MOV for compatible source codecs; otherwise MKV |
| Video + MP3 | MKV |

All processed audio uses 48 kHz. Video streams are copied without re-encoding. Video exports retain separate audio tracks and channel counts, available subtitles, chapters, and metadata; MKV also retains attachments. Data/timecode streams are not exported. Audio-only export uses the default audio track, or the first track when none is marked default. Embedded album art alone does not make an audio file a video input.

MP3 supports mono/stereo; multichannel MP3 requests are rejected rather than silently downmixed. File support depends on FFmpeg's native demuxers and decoders. Damaged, encrypted, DRM-protected, or unsupported media produces an error. The bundled tools have networking disabled.

## Command line

The CLI ships inside the app:

```sh
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --help
/Applications/Autoleveler.app/Contents/MacOS/autoleveler interview.mov
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --audio --format mp3 --bitrate 192 -o ./exports clip.mov
/Applications/Autoleveler.app/Contents/MacOS/autoleveler --format pcm take1.wav take2.wav
```

Use `--` before filenames beginning with a hyphen. `-o` / `--output-dir` selects a folder. Completed output paths go to stdout; progress and errors go to stderr. A batch continues after a file error. Exit codes: `0` success, `1` file failures, `2` invalid arguments/setup, `130` cancellation. Ctrl-C and SIGTERM terminate the active process, clean up, and stop the batch.

For development, `AUTOLEVELER_TOOLS=/path/to/tools` selects a directory containing both `ffmpeg` and `ffprobe`. The app otherwise prefers its bundled helpers. An unpackaged development build can use installed tools.

## How the audio works

Apple's built-in Sound Analysis classifier identifies likely speech locally, without transcription or a downloaded model (Apple, n.d.). The engine measures linked channel energy in 50 ms blocks, estimates the background level, and builds a smoothed gain curve around speech. It targets approximately −20 dBFS speech RMS, limits boosts to 24 dB, and returns toward unity through pauses. Channels share the gain curve to preserve their relative balance.

A gentle compressor controls peaks after leveling. An oversampled limiter leaves 2 dB of sample-peak headroom before encoding and compensates for its lookahead delay. This is a dialogue leveling tool, not an exact LUFS delivery specification or an emulation of Levelator's proprietary algorithm. FFmpeg handles decoding, compression/limiting, encoding, and video stream copying (FFmpeg, n.d.).

Speech detection can miss whispers or distant voices and mistake some sounds for speech. Audio buried in noise cannot be made clean by gain alone. If speech is not detected, Autoleveler reports it and applies no gain boost; the output still passes through the peak-control/export stage. No noise gate cuts words or removes the original ambience.

Processing uses temporary decoded audio on disk and streams samples through memory. Long multichannel recordings need substantial free space in the Mac's temporary volume; a partial export is staged in the output folder and published with an exclusive atomic rename.

## Build

Requires Xcode command-line tools, Swift 5.9 or later, an Apple silicon Mac, and internet access for the first media-tool build.

```sh
./scripts/build-app.sh
```

The build verifies pinned FFmpeg/LAME source checksums, compiles static arm64 helpers with a macOS 14 deployment target, builds both Swift executables, assembles the app, signs it ad hoc, and creates a ZIP in `dist/`. Third-party source archives, licenses, and the full media-tool build configuration are included inside the app. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The bundle is ad hoc signed for local use. Public distribution still needs Developer ID signing and Apple notarization. Compatibility is built for macOS 14; runtime testing in this workspace was on macOS 26, not a macOS 14 machine.

To regenerate the icon:

```sh
swift scripts/generate-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
```

## Verify

```sh
swift test
python3 scripts/integration-test.py --cli "$(swift build --show-bin-path)/autoleveler"
```

Integration tests use macOS `say` to create speech and an FFmpeg installation with `libx264` for the video fixture. A valid speech recording can be supplied with `--speech-fixture /path/to/speech.wav`. The tested path covers speech leveling, noise, silence, encoded peaks, AAC/MP3/PCM, output collisions, copied video, invalid inputs, and cancellation. To exercise a packaged app, pass its CLI path and set `AUTOLEVELER_TOOLS` to its `Contents/Helpers` directory.

## References

Apple. n.d. “SNClassifySoundRequest.” *Apple Developer Documentation*. Accessed October 16, 2026. https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest/

FFmpeg. n.d. “FFmpeg Documentation” and “FFmpeg Filters Documentation.” Accessed October 16, 2026. https://ffmpeg.org/ffmpeg.html and https://ffmpeg.org/ffmpeg-filters.html.
