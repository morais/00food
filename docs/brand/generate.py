#!/usr/bin/env python3
"""Derive the 00Food identity from Pedro Morais's 00Widget master artwork.

Only the chart-shaped mouth is replaced. Keep the source masters in this
directory so the resulting app icon and wordmarks can be regenerated exactly.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "docs" / "brand"
SOURCES = BRAND / "sources"
ICON_SOURCE = SOURCES / "00widget-app-icon-master.png"
TRANSPARENT_SOURCE = SOURCES / "00widget-mark-transparent-master.png"
APP_ICON = ROOT / "ios" / "Resources" / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "Icon-1024.png"
ASSETS = ROOT / "ios" / "Resources" / "App" / "Assets.xcassets"

NAVY = (6, 21, 42)
BLUE = (31, 139, 255)
BLUE_DARK = (9, 104, 232)
TEAL = (31, 184, 154)
WHITE = (248, 251, 255)
# 00Widget owns the deep-navy icon field. 00Food uses a brighter violet field
# so the sibling apps are distinguishable on an iPhone home screen.
ICON_VIOLET_TOP = (245, 146, 88)
ICON_VIOLET_BOTTOM = (151, 58, 89)
FONT = "/System/Library/Fonts/Avenir Next.ttc"
SCALE = 4


def teal_mouth_mask(image: Image.Image) -> Image.Image:
    """Find only the teal bars; the hat, eyes, card and blue edge stay exact."""
    mask = Image.new("L", image.size, 0)
    source = image.convert("RGBA").load()
    target = mask.load()
    for y in range(738, 950):
        for x in range(405, 845):
            red, green, blue, alpha = source[x, y]
            if alpha > 50 and green > red + 55 and blue > red + 35 and green > blue - 15:
                target[x, y] = 255
    return mask.filter(ImageFilter.MaxFilter(13))


def erase_mouth(image: Image.Image, mask: Image.Image) -> Image.Image:
    """Reconstruct the pale card surface from clean pixels on each side."""
    result = image.convert("RGBA").copy()
    pixels = result.load()
    covered = mask.load()
    for y in range(738, 950):
        x = 405
        while x < 845:
            if not covered[x, y]:
                x += 1
                continue
            start = x
            while x < 845 and covered[x, y]:
                x += 1
            end = x
            left = pixels[start - 1, y]
            right = pixels[end, y]
            width = end - start + 1
            for offset, px in enumerate(range(start, end), 1):
                fraction = offset / width
                pixels[px, y] = tuple(round(a * (1 - fraction) + b * fraction) for a, b in zip(left, right))
    return result


def food_plate(image: Image.Image) -> Image.Image:
    high = image.resize((image.width * SCALE, image.height * SCALE), Image.Resampling.LANCZOS)
    drawing = ImageDraw.Draw(high, "RGBA")

    def point(x: float, y: float) -> tuple[int, int]:
        return round(x * SCALE), round((y - (x - 450) * 0.115) * SCALE)

    def line(points, fill, width):
        drawing.line([point(x, y) for x, y in points], fill=fill, width=width * SCALE, joint="curve")

    # A small plate and cutlery replace the 00Widget chart mouth.
    cx, cy = point(625, 858)
    outer = 84 * SCALE
    inner = 57 * SCALE
    drawing.ellipse((cx-outer, cy-outer, cx+outer, cy+outer), outline=(*TEAL, 255), width=18*SCALE)
    drawing.ellipse((cx-inner, cy-inner, cx+inner, cy+inner), outline=(*NAVY, 215), width=9*SCALE)
    line([(455, 787), (455, 924)], (*TEAL, 255), 17)
    for x in (432, 455, 478):
        line([(x, 780), (x, 817)], (*TEAL, 255), 11)
    line([(786, 785), (786, 926)], (*TEAL, 255), 17)
    return high.resize(image.size, Image.Resampling.LANCZOS)


def save_png(image: Image.Image, path: Path, *, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB" if opaque else "RGBA").save(path, optimize=True)


def icon_background(size: tuple[int, int]) -> Image.Image:
    background = Image.new("RGBA", size)
    pixels = background.load()
    width, height = size
    for y in range(height):
        for x in range(width):
            mix = min(1.0, max(0.0, 0.58 * x / width + 0.42 * y / height))
            glow = max(0.0, 1.0 - ((x - width * 0.2) ** 2 + (y - height * 0.15) ** 2) ** 0.5 / (width * 0.9))
            color = tuple(round(top * (1 - mix) + bottom * mix + 13 * glow)
                          for top, bottom in zip(ICON_VIOLET_TOP, ICON_VIOLET_BOTTOM))
            pixels[x, y] = (*color, 255)
    return background


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
    icon_source = Image.open(ICON_SOURCE).convert("RGBA")
    transparent_source = Image.open(TRANSPARENT_SOURCE).convert("RGBA")
    if icon_source.size != (1254, 1254) or transparent_source.size != icon_source.size:
        raise ValueError("The 00Widget masters must be 1254×1254 and aligned")
    mask = teal_mouth_mask(transparent_source)
    transparent = food_plate(erase_mouth(transparent_source, mask))
    icon = icon_background(icon_source.size)
    icon.alpha_composite(transparent)

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
