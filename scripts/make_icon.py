#!/usr/bin/env python3
"""Genera docs/icon.png, docs/icon.svg y scripts/AppIcon.icns. Requiere Pillow."""
import math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SS = 3
BACKGROUND = "#172124"
FOREGROUND = "#C0F4E6"
START = (484, 445)
CURVES = [
    ((455, 415), (451, 364), (474, 320)),
    ((502, 267), (558, 250), (609, 259)),
    ((648, 267), (674, 290), (669, 320)),
    ((665, 345), (637, 356), (608, 367)),
    ((566, 384), (550, 414), (548, 445)),
    ((531, 434), (502, 434), (484, 445)),
]


def main():
    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    path = "M484 445 " + " ".join(
        "C" + " ".join(f"{x} {y}" for x, y in curve) for curve in CURVES
    ) + " Z"
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>FanLite — ventilador de tres aspas</title>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="{BACKGROUND}"/>
  <g fill="{FOREGROUND}">
    <path id="blade" d="{path}"/>
    <use href="#blade" transform="rotate(120 512 512)"/>
    <use href="#blade" transform="rotate(240 512 512)"/>
    <circle cx="512" cy="512" r="53"/>
  </g>
</svg>'''
    (docs / "icon.svg").write_text(svg, encoding="utf-8")
    image = Image.new("RGBA", (1024 * SS, 1024 * SS))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((100*SS, 100*SS, 924*SS, 924*SS), radius=185*SS, fill=BACKGROUND)
    points = [START]
    p = START
    for c1, c2, end in CURVES:
        for step in range(1, 81):
            t = step / 80
            u = 1 - t
            points.append(tuple(u**3*p[k] + 3*u*u*t*c1[k] + 3*u*t*t*c2[k] + t**3*end[k] for k in (0, 1)))
        p = end
    for angle in (0, 120, 240):
        a = math.radians(angle)
        polygon = [((512+(x-512)*math.cos(a)-(y-512)*math.sin(a))*SS,
                    (512+(x-512)*math.sin(a)+(y-512)*math.cos(a))*SS) for x, y in points]
        draw.polygon(polygon, fill=FOREGROUND)
    draw.ellipse((459*SS, 459*SS, 565*SS, 565*SS), fill=FOREGROUND)
    master = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    master.save(docs / "icon.png")
    master.save(ROOT / "scripts" / "AppIcon.icns", format="ICNS")
    print("listo: docs/icon.png, docs/icon.svg, scripts/AppIcon.icns")


if __name__ == "__main__":
    main()
