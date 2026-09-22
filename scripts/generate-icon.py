#!/usr/bin/env python3
"""Build a macOS .icns file from a square PNG."""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


# The legacy 1x small-icon elements require packed bitmap data, not PNG bytes.
# Supplying PNG data under those element codes makes non-Retina Finder decode
# the compressed bytes as pixels. Omit those elements so Icon Services scales
# a valid representation, while retaining native Retina small-icon elements.
ICON_TYPES = (
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
)


def chunk(kind: str, payload: bytes) -> bytes:
    return kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-icon.py SOURCE.png OUTPUT.icns")

    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    if not source.is_file():
        raise SystemExit(f"source image not found: {source}")

    pngs: dict[int, bytes] = {}
    with tempfile.TemporaryDirectory(prefix="easyview-icon-") as temporary_dir:
        temporary_path = Path(temporary_dir)
        for size in sorted({size for _, size in ICON_TYPES}):
            resized = temporary_path / f"icon-{size}.png"
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(source), "--out", str(resized)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            pngs[size] = resized.read_bytes()

    body = b"".join(chunk(kind, pngs[size]) for kind, size in ICON_TYPES)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
