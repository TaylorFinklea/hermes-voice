"""Composite the winged-H logo into a proper iOS/watchOS app icon.

Source `hermesvoice.png` is a transparent winged-H with lots of baked-in
padding. Naively scaling the whole frame leaves the artwork tiny on the
home screen. So: crop to the actual content bounding box, scale to fill a
target fraction of the icon WIDTH (the logo is wide + short, so width is the
binding dimension), center on the brand background, and write 1024x1024 to
both AppIcon sets.

Run: python3 backend/scripts/make_icon.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent.parent
SRC = REPO / "hermesvoice.png"
BG = (0x14, 0x14, 0x14)
CANVAS = 1024
WIDTH_FRAC = 0.82  # logo width as a fraction of the icon — fills it properly

TARGETS = [
    REPO / "ios/HermesVoice/HermesVoice/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    REPO / "ios/HermesVoice/HermesVoiceWatch/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
]


def main() -> int:
    src = Image.open(SRC).convert("RGBA")
    bbox = src.getbbox()
    if bbox is None:
        raise SystemExit("source image is fully transparent")
    art = src.crop(bbox)

    target_w = int(CANVAS * WIDTH_FRAC)
    scale = target_w / art.width
    target_h = int(art.height * scale)
    art = art.resize((target_w, target_h), Image.LANCZOS)

    canvas = Image.new("RGB", (CANVAS, CANVAS), BG)
    ox = (CANVAS - target_w) // 2
    oy = (CANVAS - target_h) // 2
    canvas.paste(art, (ox, oy), art)

    for dest in TARGETS:
        canvas.save(dest, "PNG", optimize=True)
        print(f"wrote {dest.relative_to(REPO)} (art {target_w}x{target_h})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
