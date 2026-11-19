from math import cos, pi, sin
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent
SCALE = 4
BACKGROUND = "#17181D"
ARROW = "#F7F8FA"
OFFSET = 76
UNIT = 15
STROKE = 2.2


def point(x, y):
    return (round((OFFSET + x * UNIT) * SCALE), round((OFFSET + y * UNIT) * SCALE))


def svg_source():
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <title>RAS</title>
  <rect width="512" height="512" rx="126" fill="{BACKGROUND}"/>
  <g transform="translate({OFFSET} {OFFSET}) scale({UNIT})" fill="none" stroke="{ARROW}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round">
    <path d="M 3 12 A 9 9 0 0 1 18.364 5.636 L 21 8"/>
    <path d="M 21 3 V 8 H 16"/>
    <path d="M 21 12 A 9 9 0 0 1 5.636 18.364 L 3 16"/>
    <path d="M 8 16 H 3 V 21"/>
  </g>
</svg>
'''


def render(size, maskable=False):
    base = BACKGROUND if maskable else (0, 0, 0, 0)
    image = Image.new("RGBA", (512 * SCALE, 512 * SCALE), base)
    draw = ImageDraw.Draw(image)
    if not maskable:
        draw.rounded_rectangle((0, 0, 512 * SCALE - 1, 512 * SCALE - 1),
                               radius=126 * SCALE, fill=BACKGROUND)
    width = round(STROKE * UNIT * SCALE)

    def line(points):
        scaled = [point(x, y) for x, y in points]
        draw.line(scaled, fill=ARROW, width=width, joint="curve")
        radius = width / 2
        for x, y in (scaled[0], scaled[-1]):
            draw.ellipse((round(x - radius), round(y - radius),
                          round(x + radius), round(y + radius)), fill=ARROW)

    def arc(start_degrees, end_degrees, end):
        points = []
        for index in range(97):
            angle = (start_degrees + (end_degrees - start_degrees) * index / 96) * pi / 180
            points.append((12 + 9 * cos(angle), 12 + 9 * sin(angle)))
        line(points + [end])

    arc(180, 315, (21, 8))
    line([(21, 3), (21, 8), (16, 8)])
    arc(0, 135, (3, 16))
    line([(8, 16), (3, 16), (3, 21)])

    image = image.resize((size, size), Image.Resampling.LANCZOS)
    return image


def main():
    svg_path = ROOT / "assets" / "branding" / "remoteaisync_icon.svg"
    svg_path.parent.mkdir(parents=True, exist_ok=True)
    svg_path.write_text(svg_source(), encoding="utf-8")

    android_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in android_sizes.items():
        render(size).save(ROOT / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png", optimize=True)

    web_icons = {
        "Icon-192.png": 192,
        "Icon-512.png": 512,
        "Icon-maskable-192.png": 192,
        "Icon-maskable-512.png": 512,
    }
    for filename, size in web_icons.items():
        render(size, maskable="maskable" in filename).save(
            ROOT / "web" / "icons" / filename, optimize=True
        )
    render(32).save(ROOT / "web" / "favicon.png", optimize=True)

    render(256).save(
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
        format="ICO",
        sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)],
    )


if __name__ == "__main__":
    main()
