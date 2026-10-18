#!/usr/bin/env python3
"""Genera el icono de FanLite (docs/icon.png) y el .icns de la app.

Requiere Pillow:  python3 scripts/make_icon.py

La forma es un cuadrado redondeado azul con un ventilador de tres aspas. Se dibuja a 4x y se
reduce con LANCZOS para que los bordes queden limpios en todos los tamaños del .icns.
"""

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
ICNS = ROOT / "scripts" / "AppIcon.icns"

MASTER = 1024
SS = 4
S = MASTER * SS

TOP = (8, 15, 30)
BOTTOM = (12, 88, 116)
CYAN = (34, 211, 238)
WHITE = (255, 255, 255)
FAN_TIP = (186, 245, 255)


def rounded_mask(size: int, margin: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (margin, margin, size - margin, size - margin), radius=radius, fill=255
    )
    return mask


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    column = Image.new("RGB", (1, size))
    pixels = column.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        pixels[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return column.resize((size, size))


def radial_glow(size: int, center, radius: int, color, peak: int) -> Image.Image:
    # Se dibuja chico y se agranda: un gradiente radial de 4096x4096 no aporta nada extra.
    small = 512
    glow = Image.new("RGBA", (small, small), (0, 0, 0, 0))
    pixels = glow.load()
    cx, cy = center[0] * small / size, center[1] * small / size
    r = radius * small / size
    for y in range(small):
        for x in range(small):
            d = math.hypot(x - cx, y - cy) / r
            if d >= 1:
                continue
            a = round(peak * (1 - d) ** 2.2)
            pixels[x, y] = (*color, a)
    return glow.resize((size, size), Image.LANCZOS).filter(ImageFilter.GaussianBlur(size / 220))


def blade_polygon(cx, cy, base, r0, r1, half0, half1, twist, steps=180):
    left = []
    right = []
    for i in range(steps + 1):
        t = i / steps
        radius = r0 + (r1 - r0) * t
        angle = base + twist * (t ** 1.6)
        half = half0 + (half1 - half0) * (t ** 0.7)
        spread = half / max(radius, 1)
        left.append((cx + radius * math.cos(angle - spread), cy + radius * math.sin(angle - spread)))
        right.append((cx + radius * math.cos(angle + spread), cy + radius * math.sin(angle + spread)))
    return left + right[::-1]


def main():
    DOCS.mkdir(parents=True, exist_ok=True)

    margin = 100 * SS
    radius = 186 * SS
    shape = rounded_mask(S, margin, radius)

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(vertical_gradient(S, TOP, BOTTOM), (0, 0), shape)

    cx, cy = S // 2, int(S * 0.5)
    glow = radial_glow(S, (cx, cy), int(S * 0.40), CYAN, 70)
    icon.alpha_composite(Image.composite(glow, Image.new("RGBA", (S, S), (0, 0, 0, 0)), shape))

    # Aro interior muy sutil.
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(
        (margin + 3 * SS, margin + 3 * SS, S - margin - 3 * SS, S - margin - 3 * SS),
        radius=radius, outline=(255, 255, 255, 26), width=2 * SS,
    )
    icon.alpha_composite(ring)

    # Aspas: tres, con la punta redondeada y un leve giro.
    blades = Image.new("L", (S, S), 0)
    bd = ImageDraw.Draw(blades)
    r0, r1 = 72 * SS, 236 * SS
    half0, half1 = 17 * SS, 80 * SS
    for base in (math.radians(90), math.radians(210), math.radians(330)):
        bd.polygon(blade_polygon(cx, cy, base, r0, r1, half0, half1, math.radians(30)), fill=255)
        tipx = cx + r1 * math.cos(base + math.radians(30))
        tipy = cy + r1 * math.sin(base + math.radians(30))
        bd.ellipse((tipx - half1, tipy - half1, tipx + half1, tipy + half1), fill=255)

    fan_gradient = vertical_gradient(S, WHITE, FAN_TIP)
    fan = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fan.paste(fan_gradient, (0, 0), blades)
    icon.alpha_composite(fan)

    # Cubo central: blanco con un centro oscuro y un punto cian.
    hub = ImageDraw.Draw(icon)
    hub.ellipse((cx - 70 * SS, cy - 70 * SS, cx + 70 * SS, cy + 70 * SS), fill=(255, 255, 255, 255))
    hub.ellipse((cx - 30 * SS, cy - 30 * SS, cx + 30 * SS, cy + 30 * SS), fill=(*TOP, 255))
    hub.ellipse((cx - 11 * SS, cy - 11 * SS, cx + 11 * SS, cy + 11 * SS), fill=(*CYAN, 255))

    master = icon.resize((MASTER, MASTER), Image.LANCZOS)
    master.save(DOCS / "icon.png")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for size, name in sizes:
            master.resize((size, size), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)

    print(f"listo: {DOCS / 'icon.png'}")
    print(f"listo: {ICNS}")


if __name__ == "__main__":
    main()
