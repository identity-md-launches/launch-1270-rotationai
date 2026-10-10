#!/usr/bin/env python3
"""Validate delivered PNGs and make disposable small-size review previews.

The previews only resize and circle-crop the existing generated artwork.
No part of a delivered logo is drawn here. Run from the repository root.
"""

import hashlib
from pathlib import Path

from prepare_logos import read_png, resize, write_png


def main():
    root = Path(__file__).resolve().parent.parent
    scratch = root / "test/scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    assets = [root / f"logos/logo-{i}.png" for i in range(1, 6)]
    selected = root / "artifacts/logo.png"
    hashes = []
    images = []
    for path in [*assets, selected]:
        width, height, channels, rows = read_png(path)
        assert width == height and width >= 1024, f"Wrong dimensions: {path}"
        if path != selected:
            assert (width, height) == (1024, 1024), f"Wrong option dimensions: {path}"
        assert channels in (3, 4)
        assert channels == 3 or all(row[i] == 255 for row in rows for i in range(3, len(row), 4)), f"Transparency: {path}"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        hashes.append(digest)
        images.append((width, height, channels, rows))
        print(f"PASS {path.relative_to(root)}: {width}x{height}, opaque, sha256 {digest}")
    assert len(set(hashes[:5])) == 5, "Options must be different files"
    width, height, channels, rows = images[5]
    assert channels == images[1][2], "Selected wallet logo channels differ"
    assert resize(width, height, channels, rows, 1024) == images[1][3], "Selected wallet logo must be the original of option 2"
    write_png(scratch / "selected-32.png", 32, 32, channels, resize(width, height, channels, rows, 32))

    # Five columns, logo-1 through logo-5. Four rows: 64px light, 64px dark,
    # 32px light, 32px dark. Each cell shows a square and a circular crop.
    canvas_width, canvas_height = 800, 384
    canvas = []
    for y in range(canvas_height):
        background = (243, 245, 244) if y // 96 % 2 == 0 else (19, 23, 29)
        canvas.append(bytearray(background * canvas_width))
    for index, (width, height, channels, rows) in enumerate(images[:5]):
        for size in (64, 32):
            small = resize(width, height, channels, rows, size)
            for dark in (0, 1):
                row_index = (0 if size == 64 else 2) + dark
                y_origin = row_index * 96 + (96 - size) // 2
                for circular in (False, True):
                    x_origin = index * 160 + (80 - size) // 2 + int(circular) * 80
                    for y in range(size):
                        for x in range(size):
                            if circular and (x + 0.5 - size / 2) ** 2 + (y + 0.5 - size / 2) ** 2 > (size / 2) ** 2:
                                continue
                            offset = (x_origin + x) * 3
                            canvas[y_origin + y][offset:offset + 3] = small[y][x * channels:x * channels + 3]
    write_png(scratch / "logo-review.png", canvas_width, canvas_height, 3, canvas)
    print("Review preview: test/scratch/logo-review.png (columns 1–5; rows 64px light/dark, 32px light/dark)")


if __name__ == "__main__":
    main()
