#!/usr/bin/env python3
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


BASE_DIR = Path(__file__).resolve().parent
RESOURCE_DIR = BASE_DIR / "MeetingBotMenuBarApp" / "Resources"
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
    top = rgba("1D4ED8")
    bottom = rgba("2563EB")

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
        fill=(15, 23, 42, 72),
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

    mark_shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    mark_shadow_draw = ImageDraw.Draw(mark_shadow)
    mark_shadow_draw.rounded_rectangle(
        scaled_box((238, 300, 786, 668), scale),
        radius=128 * scale,
        fill=(15, 23, 42, 84),
    )
    mark_shadow_draw.polygon(
        [(382 * scale, 650 * scale), (330 * scale, 768 * scale), (514 * scale, 660 * scale)],
        fill=(15, 23, 42, 84),
    )
    canvas.alpha_composite(mark_shadow.filter(ImageFilter.GaussianBlur(14 * scale)))

    white = (255, 255, 255, 255)
    draw.rounded_rectangle(
        scaled_box((232, 286, 792, 656), scale),
        radius=126 * scale,
        fill=white,
    )
    draw.polygon(
        [(390 * scale, 638 * scale), (330 * scale, 766 * scale), (526 * scale, 648 * scale)],
        fill=white,
    )

    wave_colors = ["60A5FA", "2563EB", "1D4ED8", "2563EB", "60A5FA"]
    bars = [
        (390, 500, 58),
        (452, 474, 112),
        (514, 436, 188),
        (576, 474, 112),
        (638, 500, 58),
    ]
    for idx, (x, center_y, height) in enumerate(bars):
        color = rgba(wave_colors[idx])
        draw.rounded_rectangle(
            scaled_box((x - 16, center_y - height // 2, x + 16, center_y + height // 2), scale),
            radius=16 * scale,
            fill=color,
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
