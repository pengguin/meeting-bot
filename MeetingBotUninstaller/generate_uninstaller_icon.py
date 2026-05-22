#!/usr/bin/env python3
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


BASE_DIR = Path(__file__).resolve().parent
RESOURCE_DIR = BASE_DIR / "Resources"
ICONSET_DIR = RESOURCE_DIR / "AppIcon.iconset"
ICNS_PATH = RESOURCE_DIR / "AppIcon.icns"
PREVIEW_PATH = RESOURCE_DIR / "AppIconPreview.png"
TIFF_PATH = RESOURCE_DIR / ".AppIcon.tiff"


def rgba(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    hex_color = hex_color.lstrip("#")
    return (
        int(hex_color[0:2], 16),
        int(hex_color[2:4], 16),
        int(hex_color[4:6], 16),
        alpha,
    )


def scaled_box(box: tuple[int, int, int, int], scale: int) -> tuple[int, int, int, int]:
    return tuple(value * scale for value in box)


def make_gradient(size: int, scale: int, radius: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    top = rgba("B91C1C")
    bottom = rgba("DC2626")

    for y in range(size):
        t = y / (size - 1)
        for x in range(size):
            r = round(top[0] * (1 - t) + bottom[0] * t)
            g = round(top[1] * (1 - t) + bottom[1] * t)
            b = round(top[2] * (1 - t) + bottom[2] * t)
            pixels[x, y] = (r, g, b, 255)

    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        scaled_box((72, 72, 952, 952), scale),
        radius=radius * scale,
        fill=255,
    )

    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.alpha_composite(image)
    result.putalpha(mask)
    return result


def draw_icon() -> Image.Image:
    scale = 4
    canvas_size = 1024 * scale
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        scaled_box((96, 108, 928, 944), scale),
        radius=188 * scale,
        fill=(69, 10, 10, 82),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(20 * scale))
    canvas.alpha_composite(shadow)

    canvas.alpha_composite(make_gradient(canvas_size, scale, 188))

    highlight = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.rounded_rectangle(
        scaled_box((104, 104, 920, 920), scale),
        radius=172 * scale,
        outline=(255, 255, 255, 42),
        width=3 * scale,
    )
    canvas.alpha_composite(highlight.filter(ImageFilter.GaussianBlur(1 * scale)))

    white = (255, 255, 255, 255)
    trash_shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    trash_shadow_draw = ImageDraw.Draw(trash_shadow)
    trash_shadow_draw.rounded_rectangle(
        scaled_box((300, 338, 724, 782), scale),
        radius=58 * scale,
        fill=(69, 10, 10, 92),
    )
    trash_shadow_draw.rounded_rectangle(
        scaled_box((268, 266, 756, 338), scale),
        radius=36 * scale,
        fill=(69, 10, 10, 92),
    )
    canvas.alpha_composite(trash_shadow.filter(ImageFilter.GaussianBlur(16 * scale)))

    draw.rounded_rectangle(
        scaled_box((300, 338, 724, 782), scale),
        radius=58 * scale,
        fill=white,
    )
    draw.rounded_rectangle(
        scaled_box((268, 266, 756, 338), scale),
        radius=36 * scale,
        fill=white,
    )
    draw.rounded_rectangle(
        scaled_box((424, 202, 600, 276), scale),
        radius=30 * scale,
        fill=white,
    )

    red_cutout = rgba("DC2626")
    draw.rounded_rectangle(
        scaled_box((372, 420, 420, 700), scale),
        radius=24 * scale,
        fill=red_cutout,
    )
    draw.rounded_rectangle(
        scaled_box((488, 420, 536, 700), scale),
        radius=24 * scale,
        fill=red_cutout,
    )
    draw.rounded_rectangle(
        scaled_box((604, 420, 652, 700), scale),
        radius=24 * scale,
        fill=red_cutout,
    )

    return canvas.resize((1024, 1024), Image.Resampling.LANCZOS)


def save_iconset(base_icon: Image.Image) -> None:
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    for filename, size in sizes.items():
        resized = base_icon.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(ICONSET_DIR / filename)

    base_icon.save(PREVIEW_PATH)


def build_icns() -> None:
    try:
        subprocess.run(
            ["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_PATH)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    frames = []
    for size in [16, 32, 48, 128, 256, 512, 1024]:
        frames.append(
            Image.open(PREVIEW_PATH)
            .convert("RGBA")
            .resize((size, size), Image.Resampling.LANCZOS)
        )

    frames[0].save(TIFF_PATH, save_all=True, append_images=frames[1:])
    try:
        subprocess.run(
            ["tiff2icns", str(TIFF_PATH), str(ICNS_PATH)],
            check=True,
        )
    finally:
        TIFF_PATH.unlink(missing_ok=True)


def main() -> None:
    icon = draw_icon()
    save_iconset(icon)
    build_icns()
    print(ICNS_PATH)


if __name__ == "__main__":
    main()
