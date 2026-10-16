#!/usr/bin/env python3
"""Small end-to-end smoke test for the built autoleveler CLI.

Uses only macOS say, ffmpeg, ffprobe, and the standard library.
"""
import argparse
import hashlib
import json
import os
import re
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path


def run(args, *, check=True, **kwargs):
    kwargs.setdefault("timeout", 60)
    return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def probe(ffprobe, path):
    result = run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)])
    return json.loads(result.stdout)


def rms(ffmpeg, source, start, duration):
    result = run([ffmpeg, "-v", "info", "-ss", str(start), "-t", str(duration), "-i", str(source),
                  "-af", "volumedetect", "-f", "null", "-"])
    match = re.search(r"mean_volume:\s*(-?[0-9.]+) dB", result.stderr)
    if "mean_volume: -inf dB" in result.stderr:
        return float("-inf")
    if not match:
        raise AssertionError(f"volumedetect did not report a mean volume for {source}: {result.stderr[-500:]}")
    return float(match.group(1))


def true_peak(ffmpeg, source):
    result = run([ffmpeg, "-v", "info", "-i", str(source),
                  "-af", "ebur128=framelog=verbose:peak=true", "-f", "null", "-"])
    matches = re.findall(r"Peak:\s*(-?[0-9.]+) dBFS", result.stderr)
    if not matches:
        raise AssertionError(f"ebur128 did not report true peak for {source}: {result.stderr[-500:]}")
    return max(float(value) for value in matches)


def make_fixture(ffmpeg, ffprobe, root, speech_fixture=None):
    voice = root / "voice.aiff"
    if speech_fixture:
        shutil.copy2(speech_fixture, voice)
    else:
        run(["say", "-o", str(voice), "This is a speech leveling fixture with deliberately uneven volume."])
    if not voice.stat().st_size:
        raise AssertionError("speech fixture is empty; pass --speech-fixture with a valid AIFF/WAV file")
    voice_probe = probe(ffprobe, voice)
    if float(voice_probe["format"].get("duration") or 0) < 3:
        raise AssertionError("speech fixture is shorter than 3 seconds")
    fixture = root / "fixture.wav"
    filter_graph = (
        "[0:a]atrim=0:3,asetpts=PTS-STARTPTS,volume=0.18[quiet];"
        "[0:a]atrim=0:3,asetpts=PTS-STARTPTS[ loud ];"
        "[1:a]atrim=0:2,asetpts=PTS-STARTPTS[noise];"
        "[2:a]atrim=0:2,asetpts=PTS-STARTPTS[silence];"
        "[quiet][noise][silence][ loud ]concat=n=4:v=0:a=1[out]"
    ).replace("[ loud ]", "[loud]")
    run([ffmpeg, "-v", "error", "-stream_loop", "-1", "-i", str(voice), "-f", "lavfi", "-i",
         "anoisesrc=color=white:amplitude=0.01:sample_rate=48000:duration=2",
         "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-filter_complex", filter_graph,
         "-map", "[out]", "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(fixture)])
    return fixture


def decoded_video_hash(ffmpeg, path):
    result = subprocess.run([ffmpeg, "-v", "error", "-i", str(path), "-map", "0:v:0",
                             "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return hashlib.sha256(result.stdout).hexdigest()


def assert_pcm_silence(path, start=6, duration=2):
    with wave.open(str(path), "rb") as source:
        rate, width, channels = source.getframerate(), source.getsampwidth(), source.getnchannels()
        source.setpos(int(start * rate))
        data = source.readframes(int(duration * rate))
    if width != 3:
        # The CLI's PCM output is expected to be 24-bit, but retain a useful check if that changes.
        values = struct.iter_unpack("<h", data)
        maximum = max((abs(v[0]) for v in values), default=0)
    else:
        maximum = max((abs(int.from_bytes(data[i:i + 3], "little", signed=True))
                       for i in range(0, len(data) - 2, 3)), default=0)
    if maximum != 0:
        raise AssertionError(f"digital silence was changed (maximum PCM sample {maximum})")


def check_output(ffmpeg, ffprobe, output, *, video=False, input_probe=None):
    info = probe(ffprobe, output)
    audio = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    if len(audio) != 1:
        raise AssertionError(f"expected one audio stream in {output}, got {audio}")
    if video:
        videos = [s for s in info["streams"] if s.get("codec_type") == "video"]
        if len(videos) != 1:
            raise AssertionError("video output did not retain exactly one video stream")
        in_duration = float(input_probe["format"]["duration"])
        out_duration = float(info["format"]["duration"])
        if abs(in_duration - out_duration) > 1 / 24:
            raise AssertionError(f"A/V duration changed by more than one frame: {in_duration} vs {out_duration}")


def check_multitrack_output(ffprobe, output, expected_video_hash, ffmpeg, input_probe):
    info = probe(ffprobe, output)
    audio = [s for s in info["streams"] if s.get("codec_type") == "audio"]
    if len(audio) != 2:
        raise AssertionError(f"expected two audio streams in {output}, got {audio}")
    languages = [stream.get("tags", {}).get("language") for stream in audio]
    if languages != ["eng", "spa"]:
        raise AssertionError(f"audio language order changed: {languages}")
    defaults = [int(stream.get("disposition", {}).get("default", 0)) for stream in audio]
    if defaults != [0, 1]:
        raise AssertionError(f"audio default dispositions changed: {defaults}")
    offsets = [float(stream.get("start_time") or 0) for stream in audio]
    if abs(offsets[0] - 2) > 0.05 or abs(offsets[1]) > 0.05:
        raise AssertionError(f"audio offsets changed: {offsets}")
    in_duration = float(input_probe["format"]["duration"])
    out_duration = float(info["format"]["duration"])
    if abs(in_duration - out_duration) > 1 / 24:
        raise AssertionError(f"multitrack A/V duration changed: {in_duration} vs {out_duration}")
    if decoded_video_hash(ffmpeg, output) != expected_video_hash:
        raise AssertionError("video stream changed in multitrack output")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="skip the cancellation stress case")
    parser.add_argument("--cli", default=os.environ.get("AUTOLEVELER_CLI"))
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE", "ffprobe"))
    parser.add_argument("--speech-fixture", default=os.environ.get("AUTOLEVELER_SPEECH_FIXTURE"))
    args = parser.parse_args()
    cli, ffmpeg, ffprobe = args.cli, args.ffmpeg, args.ffprobe
    if not cli:
        candidates = [Path(".build/debug/autoleveler"), Path(".build/out/Products/Debug/autoleveler")]
        cli_path = next((candidate for candidate in candidates if candidate.is_file()), None)
        if cli_path is None:
            raise SystemExit("CLI not found; build the debug CLI first")
        cli = str(cli_path)
    if not Path(cli).is_file():
        raise SystemExit(f"CLI not found: {cli}; build the debug CLI first")
    version = run([cli, "--version"])
    if version.stdout.strip() != "Autoleveler 1.0.0 beta":
        raise AssertionError(f"unexpected CLI version: {version.stdout.strip()!r}")
    with tempfile.TemporaryDirectory(prefix="autoleveler-integration-") as temporary:
        root = Path(temporary)
        fixture = make_fixture(ffmpeg, ffprobe, root, args.speech_fixture)
        source_probe = probe(ffprobe, fixture)
        outputs = {}
        original_quiet = rms(ffmpeg, fixture, 0.4, 2)
        original_loud = rms(ffmpeg, fixture, 7.4, 2)
        original_gap = original_loud - original_quiet
        if original_gap < 10:
            raise AssertionError(f"fixture speech gap is only {original_gap:.1f} dB; need at least 10 dB")
        for codec in ("aac", "mp3", "pcm"):
            result = run([cli, "--format", codec, "--audio", "-o", str(root), str(fixture)])
            output = Path(result.stdout.strip().splitlines()[-1])
            check_output(ffmpeg, ffprobe, output)
            peak = true_peak(ffmpeg, output)
            if peak > -0.5:
                raise AssertionError(f"{codec} true peak exceeds -0.5 dBTP: {peak:.2f}")
            outputs[codec] = output
        quiet = rms(ffmpeg, outputs["pcm"], 0.4, 2)
        loud = rms(ffmpeg, outputs["pcm"], 7.4, 2)
        processed_gap = loud - quiet
        if processed_gap >= original_gap - 3:
            raise AssertionError(f"speech gap did not materially shrink: {original_gap:.1f} -> {processed_gap:.1f} dB")
        if quiet - original_quiet < 5:
            raise AssertionError(f"quiet speech was boosted by less than 5 dB: {original_quiet:.1f} -> {quiet:.1f} dB")
        noise = rms(ffmpeg, outputs["pcm"], 3.5, 1)
        original_noise = rms(ffmpeg, fixture, 3.5, 1)
        if noise - original_noise > 2:
            raise AssertionError(f"pause noise rose by more than 2 dB: {original_noise} -> {noise}")
        assert_pcm_silence(outputs["pcm"], start=5.5, duration=1)

        second = run([cli, "--format", "aac", "--audio", "-o", str(root), str(fixture)])
        second_output = Path(second.stdout.strip().splitlines()[-1])
        if second_output == outputs["aac"] or not second_output.exists():
            raise AssertionError("reprocessing did not publish a distinct output")
        print(f"speech gap {original_gap:.1f} -> {processed_gap:.1f} dB; "
              f"quiet speech {original_quiet:.1f} -> {quiet:.1f} dB; "
              f"pause noise delta {noise - original_noise:.1f} dB")

        result = run([cli, "--format", "aac", "--video", "-o", str(root), str(fixture)], check=False)
        if result.returncode == 0:
            # The fixture is audio-only, so --video must be rejected.
            raise AssertionError("--video unexpectedly succeeded for an audio-only input")

        video_input = root / "fixture.mp4"
        run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=320x240:r=24:d=12",
             "-i", str(fixture), "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p",
             "-c:a", "aac", str(video_input)])
        video_probe = probe(ffprobe, video_input)
        before_hash = decoded_video_hash(ffmpeg, video_input)
        result = run([cli, "--format", "aac", "--video", "-o", str(root), str(video_input)])
        video_output = Path(result.stdout.strip().splitlines()[-1])
        check_output(ffmpeg, ffprobe, video_output, video=True, input_probe=video_probe)
        if decoded_video_hash(ffmpeg, video_output) != before_hash:
            raise AssertionError("video stream changed while processing audio")

        short_audio = root / "short.wav"
        run([ffmpeg, "-v", "error", "-i", str(fixture), "-t", "4", "-c:a", "pcm_s16le", str(short_audio)])
        multitrack_input = root / "multitrack.mkv"
        run([ffmpeg, "-v", "error", "-i", str(video_input), "-itsoffset", "2", "-i", str(short_audio),
             "-i", str(short_audio), "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-t", "6",
             "-c:v", "copy", "-c:a", "flac", "-metadata:s:a:0", "language=eng",
             "-metadata:s:a:1", "language=spa", "-disposition:a:0", "0",
             "-disposition:a:1", "default", str(multitrack_input)])
        multitrack_probe = probe(ffprobe, multitrack_input)
        multitrack_hash = decoded_video_hash(ffmpeg, multitrack_input)
        result = run([cli, "--format", "pcm", "--video", "-o", str(root), str(multitrack_input)])
        multitrack_output = Path(result.stdout.strip().splitlines()[-1])
        check_multitrack_output(ffprobe, multitrack_output, multitrack_hash, ffmpeg, multitrack_probe)

        preferred_input = root / "preferred-first.mkv"
        run([ffmpeg, "-v", "error", "-i", str(multitrack_input), "-map", "0", "-c", "copy",
             "-disposition:a:0", "default", "-disposition:a:1", "0", str(preferred_input)])
        result = run([cli, "--format", "pcm", "--audio", "-o", str(root), str(preferred_input)])
        preferred_output = Path(result.stdout.strip().splitlines()[-1])
        preferred_info = probe(ffprobe, preferred_output)
        preferred_duration = float(preferred_info["format"]["duration"])
        if abs(preferred_duration - 6) > 0.1:
            raise AssertionError(f"audio-only output lost the delayed stream duration: {preferred_duration}")
        assert_pcm_silence(preferred_output, start=0.2, duration=1)
        if rms(ffmpeg, preferred_output, 2.2, 1) < -75:
            raise AssertionError("audio-only output has no signal after the delayed start")

        if not args.quick:
            long_input = root / "long.wav"
            run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                 "-t", "120", "-c:a", "pcm_s16le", str(long_input)])
            process = subprocess.Popen([cli, "--format", "pcm", "--audio", "-o", str(root), str(long_input)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(0.1)
            process.send_signal(signal.SIGINT)
            process.communicate(timeout=15)
            if process.returncode != 130:
                raise AssertionError(f"SIGINT returned {process.returncode}, expected 130")
            if list(root.glob("long-leveled*.wav")):
                raise AssertionError("cancelled processing left a published output")

        missing = run([cli, "--audio", str(root / "missing.wav")], check=False)
        if missing.returncode == 0:
            raise AssertionError("invalid input unexpectedly succeeded")
    print("integration tests passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"integration test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
