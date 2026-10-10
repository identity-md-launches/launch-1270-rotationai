#!/usr/bin/env python3
"""Resize generated PNGs without redrawing them; uses only Python's standard library.

Supports the non-interlaced 8-bit RGB/RGBA PNGs returned by image generation.
Area averaging preserves the original opaque background and antialiased artwork.
Usage: python3 scripts/prepare_logos.py INPUT.png OUTPUT.png [SIZE]
"""

import binascii
import math
from pathlib import Path
import struct
import sys
import zlib


def read_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Not a PNG")
    offset = 8
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        tag = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        if binascii.crc32(tag + body) & 0xFFFFFFFF != expected_crc:
            raise ValueError("PNG CRC mismatch")
        if tag == b"IHDR":
            width, height, depth, color, comp, filt, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or color not in (2, 6) or comp or filt or interlace:
                raise ValueError("Expected non-interlaced 8-bit RGB/RGBA PNG")
        elif tag == b"IDAT":
            compressed.extend(body)
        elif tag == b"IEND":
            break
        offset += length + 12
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    if len(raw) != height * (stride + 1):
        raise ValueError("PNG dimensions do not match data")
    previous = bytearray(stride)
    rows = []
    for y in range(height):
        offset = y * (stride + 1)
        filtering = raw[offset]
        row = bytearray(raw[offset + 1:offset + stride + 1])
        if filtering not in range(5):
            raise ValueError("Unknown PNG filter")
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            above = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if filtering == 1:
                predictor = left
            elif filtering == 2:
                predictor = above
            elif filtering == 3:
                predictor = (left + above) // 2
            elif filtering == 4:
                p = left + above - upper_left
                a, b, c = abs(p - left), abs(p - above), abs(p - upper_left)
                predictor = left if a <= b and a <= c else above if b <= c else upper_left
            else:
                predictor = 0
            row[i] = (row[i] + predictor) & 255
        rows.append(row)
        previous = row
    return width, height, channels, rows


def write_png(path, width, height, channels, rows):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", binascii.crc32(tag + body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2 if channels == 3 else 6, 0, 0, 0)
    data = b"".join(b"\x00" + bytes(row) for row in rows)
    result = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(data, 9)) + chunk(b"IEND", b"")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(result)


def weights(source, target):
    scale = source / target
    result = []
    for n in range(target):
        start, end = n * scale, (n + 1) * scale
        result.append([(i, (min(i + 1, end) - max(i, start)) / scale)
                       for i in range(math.floor(start), min(source, math.ceil(end)))])
    return result


def resize(width, height, channels, rows, size):
    if size < 1 or size > min(width, height):
        raise ValueError("Only downsampling is supported")
    if (width, height) == (size, size):
        return rows
    horizontal = weights(width, size)
    vertical = weights(height, size)
    temp = []
    for row in rows:
        output = bytearray(size * channels)
        for x, samples in enumerate(horizontal):
            for c in range(channels):
                output[x * channels + c] = min(255, round(sum(row[i * channels + c] * w for i, w in samples)))
        temp.append(output)
    result = []
    for samples in vertical:
        output = bytearray(size * channels)
        for i in range(size * channels):
            output[i] = min(255, round(sum(temp[y][i] * w for y, w in samples)))
        result.append(output)
    return result


def prepare(source, destination, size=1024):
    width, height, channels, rows = read_png(source)
    if width != height:
        raise ValueError("Logo must already be square; do not crop generated art")
    if channels == 4 and any(row[i] != 255 for row in rows for i in range(3, len(row), 4)):
        raise ValueError("Logo has transparency; regenerate an opaque version")
    final = resize(width, height, channels, rows, size)
    write_png(destination, size, size, channels, final)
    print(f"{destination}: {size}x{size}, opaque PNG; resized from {width}x{height}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    prepare(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else 1024)
