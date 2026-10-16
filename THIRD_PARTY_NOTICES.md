# Third-party media helpers

Autoleveler bundles `ffmpeg` and `ffprobe`, built from the pinned source archives below for arm64 macOS 14 or later. The build keeps FFmpeg's native codec and demuxer support, enables its native AAC encoder, and links the static LAME library for MP3 encoding. The exact source archives, extracted license files, and generated configuration manifest are copied into the app's `Contents/Resources/ThirdParty` directory.

| Component | Version | Source | SHA-256 | License |
| --- | --- | --- | --- | --- |
| FFmpeg | 9.0.2 | <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` | LGPL 2.1+ |
| LAME | 3.100 | <https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz> | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` | LGPL 2.1+ |

FFmpeg is configured with `--disable-autodetect`, `--disable-network`, `--disable-shared`, `--enable-static`, and `--enable-libmp3lame`. This avoids depending on Homebrew or other non-system dynamic libraries in the distributed app. The source archive's LGPL and GPL license texts are retained with the distribution; this build does not enable GPL-only components.

See the copies of `FFmpeg-LICENSE.md`, `LAME-LICENSE`, and `LAME-COPYING` shipped with each app bundle for the applicable license texts.
