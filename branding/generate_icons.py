"""Regenerates every platform's app icon from branding/logo.png.

Usage: python3 branding/generate_icons.py   (needs Pillow)

Icons use just the logo's X mark, not the full logo -- the "EXPERT /
LEARNING CENTER" lettering is unreadable at launcher sizes (48px and below).
The Android adaptive-icon XML and its background color live in res/ by hand;
only the PNGs/ICO are generated.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
LOGO = ROOT / "branding" / "logo.png"
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
LINUX_ICONS = ROOT / "linux" / "packaging" / "icons"
WINDOWS_ICO = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
# The bare X mark for inside the app (the desktop sidebar header).
IN_APP_MARK = ROOT / "assets" / "branding" / "logo_mark.png"
IN_APP_MARK_HEIGHT = 96  # Shown at ~28 logical px -- crisp up to 3x screens.

BRAND_YELLOW = (254, 202, 38)
BACKGROUND = (0, 0, 0, 255)
MASTER = 1024  # Everything is drawn once at this size, then downscaled.

ANDROID_DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
LINUX_SIZES = (48, 64, 128, 256, 512)
WINDOWS_SIZES = (16, 24, 32, 48, 64, 128, 256)


def x_mark() -> Image.Image:
    """The logo's X mark as flat yellow on transparent, cropped tight.

    The logo is a single flat yellow on pure black, so a pixel's red channel
    is exactly how much of it the mark covers -- using that as alpha keeps
    the antialiased edges clean over any background (Android's adaptive-icon
    foreground has to be transparent). The "black" isn't perfectly 0 --
    stray 1s across it would otherwise count as faint ink and stretch the
    crop to the image's full width."""
    red = Image.open(LOGO).convert("RGB").getchannel("R")
    alpha = red.point(lambda v: 0 if v < 6 else min(255, round(v * 255 / BRAND_YELLOW[0])))

    # The mark is the topmost block of yellow rows; the lettering starts
    # after a clear gap below it.
    width, height = alpha.size
    pixels = alpha.load()
    inked = [any(pixels[x, y] > 64 for x in range(0, width, 2)) for y in range(height)]
    top = inked.index(True)
    bottom = top
    gap = 0
    for y in range(top, height):
        if inked[y]:
            bottom, gap = y, 0
        else:
            gap += 1
            if gap >= 20:
                break

    band = alpha.crop((0, top, width, bottom + 1))
    band = band.crop(band.getbbox())
    mark = Image.new("RGBA", band.size, BRAND_YELLOW + (0,))
    mark.putalpha(band)
    return mark


def _place(canvas: Image.Image, mark: Image.Image, mark_width: int) -> None:
    scale = mark_width / mark.width
    resized = mark.resize((mark_width, round(mark.height * scale)), Image.Resampling.LANCZOS)
    offset = ((canvas.width - resized.width) // 2, (canvas.height - resized.height) // 2)
    canvas.alpha_composite(resized, offset)


def tile(mark: Image.Image, *, margin: float, radius: float, mark_width: float) -> Image.Image:
    """Black rounded square with the mark centered -- the standalone icon
    for Linux, Windows and pre-Android-8 launchers. All args are fractions of
    the icon's size."""
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    inset = round(MASTER * margin)
    ImageDraw.Draw(canvas).rounded_rectangle(
        (inset, inset, MASTER - 1 - inset, MASTER - 1 - inset),
        radius=round(MASTER * radius),
        fill=BACKGROUND,
    )
    _place(canvas, mark, round(MASTER * mark_width))
    return canvas


def adaptive_foreground(mark: Image.Image) -> Image.Image:
    """Android 8+ adaptive-icon foreground: 108dp, of which launchers only
    guarantee a 66dp-diameter circle stays visible under any mask shape. A
    50dp-wide mark keeps its corners (about 59dp across diagonally) inside
    that circle."""
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    _place(canvas, mark, round(MASTER * 50 / 108))
    return canvas


def _scaled(master: Image.Image, size: int) -> Image.Image:
    return master.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    mark = x_mark()
    standalone = tile(mark, margin=0.06, radius=0.2, mark_width=0.62)
    legacy_android = tile(mark, margin=0.0, radius=0.2, mark_width=0.66)
    foreground = adaptive_foreground(mark)

    for density, factor in ANDROID_DENSITIES.items():
        folder = ANDROID_RES / f"mipmap-{density}"
        _scaled(legacy_android, round(48 * factor)).save(folder / "ic_launcher.png")
        _scaled(foreground, round(108 * factor)).save(folder / "ic_launcher_foreground.png")

    LINUX_ICONS.mkdir(parents=True, exist_ok=True)
    for size in LINUX_SIZES:
        _scaled(standalone, size).save(LINUX_ICONS / f"{size}.png")

    # Hand Pillow a crisp render for every size rather than letting it
    # resample the 256px one itself.
    renders = [_scaled(standalone, size) for size in WINDOWS_SIZES]
    renders[-1].save(
        WINDOWS_ICO,
        sizes=[(size, size) for size in WINDOWS_SIZES],
        append_images=renders[:-1],
    )

    IN_APP_MARK.parent.mkdir(parents=True, exist_ok=True)
    mark_width = round(mark.width * IN_APP_MARK_HEIGHT / mark.height)
    mark.resize((mark_width, IN_APP_MARK_HEIGHT), Image.Resampling.LANCZOS).save(IN_APP_MARK)

    print(f"X mark cropped to {mark.width}x{mark.height}; icons written.")


if __name__ == "__main__":
    main()
