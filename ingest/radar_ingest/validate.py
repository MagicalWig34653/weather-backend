"""Validation of DWD responses and conversion to lossless WebP."""

from __future__ import annotations

import io

from PIL import Image, UnidentifiedImageError

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MIN_BYTES = 1_000
MAX_BYTES = 3_000_000


class InvalidImage(Exception):
    """The response is not a plausible radar PNG (XML error such as InvalidDimensionValue, truncated, wrong size)."""


def validate_png(data: bytes, width: int, height: int) -> Image.Image:
    if data.lstrip()[:1] == b"<":
        raise InvalidImage("XML/text response instead of an image")
    if not data.startswith(PNG_SIGNATURE):
        raise InvalidImage("not a PNG")
    if not MIN_BYTES <= len(data) <= MAX_BYTES:
        raise InvalidImage(f"implausible size {len(data)} bytes")
    try:
        probe = Image.open(io.BytesIO(data))
        probe.verify()
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError, SyntaxError) as error:
        raise InvalidImage(f"PNG not decodable: {error}") from error
    if image.size != (width, height):
        raise InvalidImage(f"unexpected dimensions {image.size}")
    return image.convert("RGBA")


def to_webp(image: Image.Image) -> bytes:
    """Lossless and exact: the DWD palette stays unchanged (259-260 distinct RGBA values, PNG8 would be lossy)."""
    out = io.BytesIO()
    image.save(out, "WEBP", lossless=True, quality=100, method=6, exact=True)
    return out.getvalue()
