#!/usr/bin/env python3
"""Copy the reproducible media helper output into an app bundle."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, help="path to the .app bundle")
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="media-tools directory (default: repository dist/media-tools)",
    )
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    source = (args.source or repo / "dist/media-tools").resolve()
    app = args.app.resolve()
    helpers = app / "Contents/Helpers"
    resources = app / "Contents/Resources/ThirdParty"

    if not app.is_dir():
        raise SystemExit(f"bundle-tools: app bundle does not exist: {app}")
    if not (source / "ffmpeg").is_file() or not (source / "ffprobe").is_file():
        raise SystemExit(f"bundle-tools: build media tools first: {source}")

    helpers.mkdir(parents=True, exist_ok=True)
    for name in ("ffmpeg", "ffprobe"):
        destination = helpers / name
        shutil.copy2(source / name, destination)
        destination.chmod(0o755)

    # The source archives, checksums, and license files travel with the app so
    # redistribution remains auditable for the GPL/LGPL components.
    resources.mkdir(parents=True, exist_ok=True)
    for name in ("BUILD-MANIFEST.txt", "licenses", "third-party-sources"):
        item = source / name
        if not item.exists():
            raise SystemExit(f"bundle-tools: missing distribution support file: {item}")
        destination = resources / name
        if item.is_dir():
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(item, destination)
        else:
            shutil.copy2(item, destination)

    notice = repo / "THIRD_PARTY_NOTICES.md"
    if notice.is_file():
        shutil.copy2(notice, resources / notice.name)

    for name in ("ffmpeg", "ffprobe"):
        assert (helpers / name).stat().st_mode & 0o111
    assert (resources / "BUILD-MANIFEST.txt").is_file()
    print(f"Bundled media helpers into {helpers}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
