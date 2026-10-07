#!/usr/bin/env python3
"""Generate application assets from the approved 00Food master artwork.

The stacked cutlery smile is baked into the source masters so regeneration
preserves the approved icon and its transparent companion exactly.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "docs" / "brand"
SOURCES = BRAND / "sources"
ICON_SOURCE = SOURCES / "00food-app-icon-master.png"
TRANSPARENT_SOURCE = SOURCES / "00food-mark-transparent-master.png"
APP_ICON = ROOT / "ios" / "Resources" / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "Icon-1024.png"
ASSETS = ROOT / "ios" / "Resources" / "App" / "Assets.xcassets"

NAVY = (6, 21, 42)
BLUE = (31, 139, 255)
BLUE_DARK = (9, 104, 232)
WHITE = (248, 251, 255)
FONT = "/System/Library/Fonts/Avenir Next.ttc"


def save_png(image: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB" if opaque else "RGBA").save(path, optimize=True)


def wordmark(*, dark_surface: bool, transparent_background: bool = False) -> Image.Image:
    size = (2400, 700)
    image = Image.new("RGBA", size, (0, 0, 0, 0) if transparent_background else (*WHITE, 255))
    title = ImageFont.truetype(FONT, 425, index=9)
    draw = ImageDraw.Draw(image)
    zero_width = draw.textlength("00", font=title)
    food_width = draw.textlength("Food", font=title)
    start_x = round((size[0] - zero_width - food_width - 44) / 2)
    y = 75
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).text((start_x, y), "00", font=title, fill=255)
    gradient = Image.new("RGBA", size)
    gradient_pixels = gradient.load()
    for py in range(size[1]):
        mix = py / (size[1] - 1)
        color = tuple(round(top * (1 - mix) + bottom * mix) for top, bottom in zip(BLUE, BLUE_DARK))
        for px in range(size[0]):
            gradient_pixels[px, py] = (*color, 255)
    image.paste(gradient, (0, 0), mask)
    draw = ImageDraw.Draw(image)
    draw.text((round(start_x + zero_width + 44), y), "Food", font=title,
              fill=(*WHITE, 255) if dark_surface else (*NAVY, 255))
    return image


def main() -> None:
    icon = Image.open(ICON_SOURCE).convert("RGBA")
    transparent = Image.open(TRANSPARENT_SOURCE).convert("RGBA")
    if icon.size != (1254, 1254) or transparent.size != icon.size:
        raise ValueError("The 00Food masters must be 1254×1254 and aligned")
    if transparent.getchannel("A").getextrema() != (0, 255):
        raise ValueError("The transparent master must contain a transparent background")

    save_png(icon, BRAND / "app-icon-master.png", opaque=True)
    save_png(transparent, BRAND / "mark-transparent-master.png")
    save_png(icon.resize((1024, 1024), Image.Resampling.LANCZOS), BRAND / "mark-1024.png", opaque=True)
    save_png(transparent.resize((1024, 1024), Image.Resampling.LANCZOS), BRAND / "mark-transparent-1024.png")
    save_png(icon.resize((1024, 1024), Image.Resampling.LANCZOS), APP_ICON, opaque=True)
    save_png(icon.resize((512, 512), Image.Resampling.LANCZOS), ASSETS / "BrandMark.imageset" / "Mark.png", opaque=True)
    light_wordmark = wordmark(dark_surface=False)
    save_png(light_wordmark, BRAND / "wordmark-horizontal.png", opaque=True)
    light_transparent_wordmark = wordmark(dark_surface=False, transparent_background=True)
    dark_transparent_wordmark = wordmark(dark_surface=True, transparent_background=True)
    save_png(light_transparent_wordmark, BRAND / "wordmark-horizontal-transparent-light.png")
    save_png(dark_transparent_wordmark, BRAND / "wordmark-horizontal-transparent.png")
    save_png(light_transparent_wordmark, ASSETS / "BrandWordmark.imageset" / "Wordmark-Light.png")
    save_png(dark_transparent_wordmark, ASSETS / "BrandWordmark.imageset" / "Wordmark-Dark.png")

    preview = Image.new("RGBA", (1600, 960), (*WHITE, 255))
    preview.alpha_composite(icon.resize((760, 760), Image.Resampling.LANCZOS), (100, 100))
    fitted_wordmark = ImageOps.contain(light_wordmark, (660, 500), Image.Resampling.LANCZOS)
    preview.alpha_composite(fitted_wordmark, (880, 240))
    save_png(preview, BRAND / "brand-preview.png", opaque=True)


if __name__ == "__main__":
    main()
